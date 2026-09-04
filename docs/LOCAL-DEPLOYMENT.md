# LOCAL-DEPLOYMENT — WSL2 단일 노드 k3s (B안)

> 브랜치 `local` · 작성 기준일 2026-09-01
>
> [DEPLOYMENT.md §4](./DEPLOYMENT.md#4-로컬-배포-hyper-v)는 **Hyper-V 3-VM**을 전제한다.
> 이 문서는 **WSL2 단일 노드 + zram 압축 스왑**으로 같은 목표를 달성하는 경로를 기술한다.

---

## 1. 왜 WSL2인가

`ADR-051`은 로컬 타깃으로 Hyper-V를 채택하며 **kind / minikube / k3d / WSL2 단일 노드**를 대안으로 기각했다. 그러나 이 호스트에서 실측한 결과 WSL2 커널이 필요 조건을 전부 충족한다.

| 요건 | 실측값 (커널 `6.18.33.2-microsoft-standard-WSL2`) |
|---|---|
| `/sys/kernel/btf/vmlinux` | ✅ 6.7 MB — **Falco `modern_ebpf`·Tetragon·Cilium CO-RE 가능** |
| `CONFIG_DEBUG_INFO_BTF_MODULES` | ✅ `=y` (모듈 BTF까지) |
| cgroup | ✅ `cgroup2fs` 단독 |
| PID 1 | ✅ `systemd` |
| `xt_TPROXY` · `xt_socket` | ✅ **Istio ambient ztunnel 인터셉트 가능** |
| `nf_conntrack`·`nf_tables`·`iptable_nat`·`ip_vs`·`vxlan`·`overlay`·`br_netfilter` | ✅ 전부 |
| `CONFIG_BPF_LSM`·`CGROUP_BPF`·`BPF_JIT`·`XDP_SOCKETS` | ✅ |
| `CONFIG_ZRAM=m` (lzo-rle) | ✅ **압축 스왑 가능** |
| `CONFIG_LRU_GEN`(MGLRU)·`ZSWAP`·`ZRAM_BACKEND_ZSTD` | 미설정 — 커스텀 빌드 사안 (§7) |

**H5(Hyper-V 합성 NIC에서 Cilium eBPF 동작 범위 `[UNVERIFIED]`)가 WSL2에서는 오히려 리스크가 낮다.** Ubuntu 24.04 게스트(6.8)보다 신형 커널이고 BTF가 기본 노출된다.

### 단일 노드로 검증 가능/불가

| 검증 가능 | 검증 불가 |
|---|---|
| **M1 — Cilium `socketLB.hostNamespaceOnly` + Istio ambient 공존.** socketLB는 `connect()` 시점 BPF cgroup 훅이라 **노드 로컬 현상**이다 | 노드 간 CNI 데이터패스·성능 (`hv_netvsc` XDP 오프로드 불가) |
| Kustomize 빌드·오버레이·sync wave 순서 | HA 페일오버 (레플리카 1) |
| Kyverno 정책, 부트스트랩 Job, 의존 관계 | OPNsense 경계 통제, 남–북 IDS |
| ArgoCD GitOps 동작 | 실부하·용량 산정 |

---

## 2. 메모리 설계 — B안

### 2-1. 예산

```
물리 (MemTotal, .wslconfig memory=48GB)          47.0 GiB
- OS/systemd                                      0.5
- k3s / containerd / kubelet                      2.0
- DaemonSet 6종                                   1.6
                                                -------
  Allocatable                                    42.9 GiB
  B안 소요 (전 컴포넌트, ADR-066 반영 후)          58.75 GiB
  부족분                                        -15.85 GiB   <- zram 이 메운다
```

> B안 58.75 GiB의 컴포넌트별 내역은 [COMPONENTS.md](./COMPONENTS.md) 참조.
> `governance`는 ADR-066(FreeIPA 제거)으로 7.9 → 5.9 GB다.

### 2-2. QoS 2계층 — zram 제어 장치

**`LimitedSwap`은 Burstable QoS 파드에만 스왑을 준다. Guaranteed(`requests == limits`, cpu·memory 둘 다)는 스왑을 0 받는다.** 이 성질을 스위치로 쓴다.

| 계층 | 대상 | 크기 | 근거 |
|---|---|--:|---|
| **Guaranteed**<br>스왑 배제 | Elasticsearch · Kafka · Trino · PostgreSQL · MariaDB · MongoDB · Redis · MinIO · Hive Metastore | **9.75 GiB** | **JVM은 GC가 힙 전체를 순회**하므로 스왑되면 스래싱한다. **DB 버퍼풀은 정의상 hot data**라 스왑되면 캐시의 의미가 사라진다 |
| **Burstable**<br>zram 허용 | 나머지 전부 (Caldera·LAM·Kerberos·Jenkins·Knox·Ranger usersync·admin·nginx·Grafana·Kibana·GlitchTip worker 등) | **49.0 GiB** | 유휴 시간이 길어 스왑에 적합 |

구현: `kubernetes/overlays/local/patches/qos-guaranteed.yaml` + ES CR JSON6902 패치.

### 2-3. zram 산수

`disksize`는 **논리(비압축) 용량**이고, 실제 RAM 비용은 `저장량 / 압축률`이다.

```
Burstable 실 RAM 잔여 = 42.9 - 9.75 = 33.15 GiB
필요 Burstable 용량   = 58.75 - 9.75 = 49.0 GiB

49.0 = (33.15 - S/R) + S      R=2.2  ->  S = 29.1 GiB (RAM 비용 13.2 GiB)
```

**설정: `disksize=32G`, `mem_limit=14G`.**

`mem_limit`이 안전판이다 — 압축률이 나빠도 zram이 RAM을 14 GiB 이상 점유하지 않고 멈추며, 넘치는 분은 priority -2의 디스크 스왑(16 GB)으로 흘러간다. **이 상한이 없으면 압축률 악화 시 zram이 RAM을 잠식해 노드가 OOM된다.**

| 압축률 | zram 수용(논리) | 필요 29.1 | 판정 |
|--:|--:|---|---|
| 2.5 | 35.0 | | 여유 5.9 |
| **2.2** (기대) | 30.8 | | 여유 1.7 |
| 2.0 | 28.0 | | 1.1 디스크 스왑으로 |
| 1.8 | 25.2 | | 3.9 디스크 스왑으로 |

**여유가 얇다.** 압력 밸브는 `security-full`(10.9 GiB) 지연이다 — 빼면 47.85 GiB로 zram 없이도 성립한다.

### 2-4. 성능 — 무엇이 스왑되느냐가 전부다

| 계층 | 4KB 페이지 접근 | DRAM 대비 |
|---|--:|--:|
| DRAM | ~80 ns | 1x |
| **zram** (lzo-rle 해제) | ~1-3 us | **20-40x** |
| 디스크 스왑 (NVMe + vhdx) | ~80-150 us | **1,000-2,000x** |

2 GiB 힙의 절반이 스왑된 상태에서 Full GC가 돌면 — zram **0.72초**, 디스크 스왑 **26초**(liveness 실패 → 재시작 루프). **QoS 계층화로 JVM·DB를 Guaranteed에 두면 이 시나리오 자체가 발생하지 않는다.**

---

## 3. 절차

```
# 1. local/wslconfig -> C:\Users\<user>\.wslconfig 복사
# 2. Docker Desktop 종료 (docker-desktop 배포판이 메모리를 경합)
# 3. PowerShell:  wsl --shutdown
# 4. 레포를 WSL ext4 로 clone — /mnt/c 는 I/O 가 극도로 느리다
git clone <repo> ~/oim-infra && cd ~/oim-infra && git checkout local

# 5. zram + k3s + StorageClass
./local/bootstrap-wsl-k3s.sh

# 6. 플랫폼 계층 (ArgoCD 밖, wave -1)
cilium install --version 1.16.5 --set socketLB.hostNamespaceOnly=true --set cni.exclusive=false
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
istioctl install --set profile=ambient
# ECK · Kyverno · cert-manager

# 7. 배포
kubectl kustomize kubernetes/overlays/local | kubectl apply -f -
```

**`bootstrap-wsl-k3s.sh`의 k3s 플래그** — NodeSwap은 kubelet 설정이라 **설치 시점에만 정할 수 있다.** 나중에 켜려면 systemd 유닛 편집 + 재시작 = 전 파드 재시작이다.

> **`--memory-swap.swap-behavior`·`--memory-throttling-factor` 는 존재하지 않는 CLI 플래그다.** kubelet 이 `unknown flag` 로 기동을 거부한다. `memorySwap.swapBehavior`·`memoryThrottlingFactor` 는 KubeletConfiguration 전용 필드이므로 `local/kubelet-config.yaml` 로 전달한다. 자세한 것은 §8-5.

```
--flannel-backend=none --disable-network-policy   # Cilium 전제 (클라우드와 동일)
--disable traefik --disable servicelb
--kubelet-arg=config=/etc/rancher/k3s/kubelet-config.yaml   # 스왑 설정 일체
```

---

## 4. 모니터링 — 반드시 볼 것

```
vmstat 1                          # si / so 컬럼
cat /sys/block/zram0/mm_stat      # orig_data_size / compr_data_size -> 실제 압축률
kubectl top pods -n local --sort-by=memory
```

| 관측 | 판정 |
|---|---|
| `si` = 0, `so` 간헐적 | **정상.** 유휴 페이지가 나가기만 하고 안 돌아옴 |
| `si` 수백 KB/s 지속 | 주의. 워킹셋이 스왑에 걸침 |
| `si` MB/s 지속 | **스래싱.** `security-full` 지연 또는 §7 검토 |
| `mm_stat` 압축률 < 2.0 | 디스크 스왑 폴백 발생 중 |

---

## 5. 배포 블로커 (환경 무관)

배포를 진행하며 대부분 해소했다. 상세 경위는 §8.

| # | 블로커 | 상태 |
|:-:|---|---|
| 1 | Secret 렌더링 0개 — `.enc.yaml` 12개가 kustomization 주석 처리 | **해소(로컬)** — `local/create-secrets.sh` 가 14종을 런타임 생성. dev/prod 의 SOPS 정비는 G2·G3 로 남는다 |
| 2 | 오퍼레이터 설치 경로 없음 | **해소** — `local/install-platform.sh`(Cilium·Gateway API) + `local/install-operators.sh`(Istio ambient·ECK·Kyverno·cert-manager). Argo Events·OTel·Trivy Operator 는 미도입 |
| 3 | DB·롤·버킷·토픽 부트스트랩 Job 부재 | **해소(G22)** — `base/bootstrap/` 5종. 함정은 §8-4 |
| 4 | ServiceAccount 12개 부재 | **해소(G18)** — `base/serviceaccounts/` 15종. dev·prod 도 함께 해소된다 |
| **5** | **storageClass `standard` 부재** | **해소** — `local/storageclass-standard.yaml` |
| 6 | 외부 진입점 없음 | 단일 노드는 NodePort 또는 `port-forward` |

---

## 6. OpenTofu의 위치 — 로컬에는 IaC 계층이 없다

`tofu`는 WSL에서 정상 실행된다(Linux amd64). 그러나 **WSL 로컬 배포에는 프로비저닝할 대상이 없다.**

| | Vultr | Hyper-V | **WSL2** |
|---|---|---|---|
| VM 생성 API | 있음 | 있음 (PowerShell cmdlet) | **없음** |
| VPC·방화벽·DNS·블록스토리지 | 있음 | 없음 (ADR-052) | **없음** |
| IaC 대상 | 전체 | VM·네트워크 | **없음** |

`ADR-052`는 *"근본적으로 다른 기반은 별도 루트 모듈"*, `ADR-011`은 *"추상화를 유지한다고 프로바이더 이동이 쉬워지지 않는다"*를 남겼다. 이 논리를 연장하면 **WSL 로컬에는 IaC 모듈을 만들지 않는 것이 맞다.** 셸 스크립트(`bootstrap-wsl-k3s.sh`)가 정직한 도구다.

**다만 `tofu`는 설치할 가치가 있다** — WSL에서 Vultr dev/prod를 조작하기 위해서다. 특히 비용 절감안의 온디맨드 사이클(apply -> 시연 -> 파괴)이 여기서 돌아간다. `DEPLOYMENT.md §2`의 `tofu` 미설치 표기가 이걸로 해소된다.

> Vultr는 인스턴스를 정지해도 과금이 계속되고 **파괴해야 멈춘다.** 상시 운용이 아니라 짧게 띄웠다 지우는 사용이 Vultr의 강점에 맞다.

-> **ADR-067 후보**: *"WSL 로컬 타깃에는 IaC 루트 모듈을 만들지 않는다. 부트스트랩은 셸 스크립트로 하고, OpenTofu는 클라우드 조작 전용으로 유지한다."*

---

## 7. 커널 커스텀 빌드 — 지금은 하지 않는다

| 빠진 기능 | 가치 |
|---|---|
| `LRU_GEN` (MGLRU) | 메모리 압박 시 회수 정확도 향상 -> 스래싱 감소 |
| `ZRAM_BACKEND_ZSTD` | 압축률 2.2 -> 3.2 (실효 +16 GiB) |
| `ZRAM_WRITEBACK` | 불필요 — 우선순위 계층 스왑으로 대체 |
| `BPF_STREAM_PARSER` | 불필요 — M1은 cgroup `sock_addr` 훅이라 무관 |

**전부 6.18보다 한참 전에 mainline에 들어온 기능이다. 버전 문제가 아니라 Microsoft config 문제이므로 `wsl --update`로는 해결되지 않는다.**

**주의: `rolling-lts/wsl/6.18.35.1`은 피할 것** — x86 시각 회귀(ARM64 전용 타이머 레지스터 상수가 x86 게스트에 적용). **6.18.35.2**에서 수정. 현재 쓰는 `6.18.33.2-2`는 회귀 이전이라 안전하다. 시각 정확도는 kubelet 리스 갱신·TLS 유효기간·Iceberg 스냅샷 순서의 직접 의존 항목이다.

**판단: §4의 `si`가 지속적으로 뜨는 것을 실측한 뒤에만 빌드한다.** 커스텀 커널을 `kernel=`로 고정하면 `wsl --update`의 보안 패치가 더 이상 오지 않는다. 빌드 시 `pahole`/`dwarves` 미설치로 **BTF가 빠지면 Falco·Tetragon·Cilium CO-RE가 전멸**하므로 반드시 확인할 것.

---


---

## 8. 실배포에서 확인된 것 (2026-09-01)

이 절은 **실제로 배포하며 부딪힌 것만** 기록한다. 추정은 넣지 않는다.

### 8-1. WSL2 고유 블로커 3건 — 다른 문서에 없다

| # | 증상 | 원인 | 조치 |
|:-:|---|---|---|
| **W1** | `istio-cni-node: CreateContainerError`<br>`path "/var/run/netns" is mounted on "/" but it is not a shared or slave mount`<br>ztunnel: `failed to connect to the Istio CNI node agent over ztunnel.sock` | **WSL2 의 init 이 `/` 를 private 으로 둔다.** 일반 배포판은 systemd 가 부팅 시 `mount --make-rshared /` 를 한다. istio-cni 는 파드 netns 진입에 마운트 전파를 요구한다 | `local/mount-rshared.service` |
| **W2** | Falco: `An error occurred in an event source, forcing termination`<br>`Error: Initialization issues during scap_init` | `/sys/kernel/debug`(debugfs) 미마운트 | `local/mount-debugfs.service` |
| **W3** | W2 조치 후에도 Falco 동일 실패 | modern_ebpf 프로브가 WSL2 커널에서 기동 불가 | 로컬만 스케줄 불가 `nodeSelector` 로 비활성. **ADR-025 의 Tetragon 전환이 채택되면 소멸하는 제약** |

**W1 이 가장 파급이 컸다.** `istioctl install` 이 준비 대기에서 무한히 멈춰 그 뒤의 ECK·Kyverno·cert-manager 설치가 전부 막혔다. 원인이 Istio 가 아니라 WSL 마운트라는 점이 진단을 어렵게 한다.

`ADR-051` 이 WSL2 를 기각한 판단에 근거가 하나 생겼다 — Hyper-V VM 에서는 발생하지 않는다. 다만 유닛 두 장으로 해소되므로 결론(WSL2 사용)은 바뀌지 않는다.

### 8-2. 컨테이너 빌드 — podman

`docker.io` 의 containerd 가 기동하지 못했다.

```
containerd: failed to create unix socket on /run/containerd/containerd.sock: is a directory
```

`/run/containerd/containerd.sock` 이 **디렉터리로 존재**한다(Docker Desktop WSL 통합 잔재로 추정). 고칠 수도 있으나 **podman 이 구조적으로 낫다** — 데몬이 없어 빌드 후 메모리를 남기지 않고, k3s 의 containerd 와 소켓을 다투지 않는다. Docker Desktop 은 자체 WSL 배포판을 띄워 같은 48 GB 예산을 경합한다.

- podman 은 짧은 이미지 이름을 해석하지 않는다 → `FROM docker.io/apache/spark:3.5.6` 처럼 완전한 이름을 쓴다
- 반입: `podman save | k3s ctr -n k8s.io images import -` 후 `docker.io/...` 로 재태그
- **로컬 빌드 이미지는 `imagePullPolicy: IfNotPresent` 가 필수다.** `:latest` 는 기본 정책을 `Always` 로 만들어 반입한 이미지를 무시하고 `ImagePullBackOff` 가 난다

### 8-3. 레포에 원래 있던 결함 — 배포로 드러난 것

| 대상 | 증상 | 원인 | 문서 |
|---|---|---|---|
| Kafka | `UnknownHostException: kafka-1.kafka-headless` | local 오버레이에 단일노드 quorum 패치 부재 (dev 에는 `kafka-dev.yaml` 이 있다) | — |
| Kafka | `Created log ... in /tmp/kafka-logs/` | `KAFKA_LOG_DIRS` 미설정 → PVC 미사용·재시작 시 유실 | **G23** |
| nginx | `admin-headless.dev.svc.cluster.local could not be resolved` | upstream `.dev.svc` 하드코딩. nginx `resolver` 는 검색 도메인을 적용하지 않아 FQDN 이 필요 | **TODO-14** |
| Apicurio | probe `/health/live` → 404 | Apicurio Registry 3.x 는 Quarkus 기본 `/q/health/*` | 신규 |
| Logstash | `exitCode 143`, 31초 생존 | **`startupProbe` 부재.** `livenessProbe` 가 즉시 시작해 3회×10초에 SIGTERM. 파이프라인 컴파일에 60~90초 필요 | 신규 |
| GitLab | `structure.sql:60326: ERROR: out of shared memory` | `max_locks_per_transaction` 기본 64. GitLab 은 6만 줄 스키마를 단일 트랜잭션으로 적재 | 신규 |
| Hive Metastore | `Failed to load driver` | `apache/hive` 이미지에 PostgreSQL JDBC 드라이버가 없다 (StatefulSet 은 initContainer 로 받는다) | **SEC-512** |
| Spark Connect | `Failed to load class ...SparkConnectServer` | Connect 서버 JAR 이 `apache/spark` 배포판에 없다 | 신규 |
| Spark History | S3A `getFileStatus` 실패 | `SimpleAWSCredentialsProvider` 는 `fs.s3a.access.key` 만 읽고 `AWS_ACCESS_KEY_ID` 환경변수를 보지 않는다 | 신규 |
| ES ILM Job | ES 기동 전 실행되어 CrashLoop | 대기 루프 부재 | 신규 |
| cmmn-api | `Couldn't resolve kafka-0.kafka-headless.dev.svc...` | `spring.kafka.consumer/producer.bootstrap-servers` 가 개별 지정되어 `SPRING_KAFKA_BOOTSTRAP_SERVERS` 가 무시된다 | 신규 |
| Spark Connect | `path must be absolute` | 버킷 루트는 `stripSuffix("/")` 후 경로 성분이 사라진다 | 신규 |
| Spark RBAC | `cannot deletecollection resource "services"` | driver 는 종료 시 label selector 로 일괄 삭제한다 | 신규 |

### 8-4. 부트스트랩 Job 이 걸린 함정

- **NetworkPolicy** — `default-deny-ingress` 하에서 Job 이 대상의 allow 규칙에 없어 `Connection timed out` 이 났다. **인증 실패가 아니라 도달 실패**라 로그만 보면 오진하기 쉽다. `allow-postgresql-access` 는 keycloak·gitlab·hive-metastore 만 허용하며 **apicurio 도 빠져 있었다**(G13 계열)
- **롤·DB 이름은 소비자 매니페스트가 진실이다.** GitLab 은 `gitlab`(≠`gitlabhq`), Hive 는 롤 `hive` / DB `hive_metastore` 다. 각 `ensure` 호출 옆에 근거 위치를 주석으로 남겼다
- `pg_isready` 는 **인증까지 확인하지 않는다.** 비밀번호 없이도 통과하므로 실제 `psql` 접속으로 판정해야 한다
- `schematool` 은 `hive-site.xml` 만 읽는다. `SERVICE_OPTS` 의 `-D` 로는 반영되지 않아 `-url/-driver/-userName/-passWord` CLI 플래그가 필요하다

### 8-5. 검증된 설계 요소

| 항목 | 확인 방법 | 결과 |
|---|---|---|
| **`LimitedSwap`** | `/api/v1/nodes/<n>/proxy/configz` | `"memorySwap":{"swapBehavior":"LimitedSwap"}` · `NodeSwap:true` · `failSwapOn:false` · `memoryThrottlingFactor:0.8` |
| **M1 · M2** | `cm/cilium-config` | `bpf-lb-sock-hostns-only: "true"` · `cni-exclusive: "false"` |
| **istio-cni 체인** | `/etc/cni/net.d/05-cilium.conflist` | 191 → 453 바이트 (M2 작동) |
| **QoS 계층화** | 렌더링 결과 | JVM·DB 9종 `requests == limits` (cpu·memory) = **Guaranteed 9.75 GiB** |
| **StorageClass 별칭** | `kubectl get pvc` | 9개 `Bound` |
| **Kyverno** | 파드 이벤트 | `PolicyViolation ... disallow-latest-tag` (local 은 Audit 이라 비차단) |

> **kubelet 플래그 함정** — `--memory-swap.swap-behavior` 와 `--memory-throttling-factor` 는 **존재하지 않는 CLI 플래그**다. `memorySwap.swapBehavior`·`memoryThrottlingFactor` 는 KubeletConfiguration 전용 필드이며, k8s 1.30+ 에서 `swapBehavior` 기본값이 `NoSwap` 이므로 명시하지 않으면 **zram 이 32 GB 있어도 파드가 한 바이트도 쓰지 못한다.**

### 8-6. 실측 메모리 (중간 시점 · 22 파드)

22 파드 Running 시점:

```
Mem: 47 GiB total / 13 GiB used / 34 GiB available
zram: mem_used 2 MiB (disksize 32 GiB)   ← 사실상 미사용
vmstat si: 0                              ← 스왑인 없음
```

상위 소비: Elasticsearch 1,826 Mi · Logstash 930 Mi · Trino 836 Mi · Kibana 564 Mi · Keycloak 527 Mi

**§2 의 zram 설계는 아직 시험되지 않았다.** CrashLoop 중인 워크로드가 메모리를 잡지 않기 때문이며, 전 구성요소가 Running 이 되어야 §2-3 의 압축률 가정을 검증할 수 있다.


### 8-7. 최종 결과 (2026-09-01 배포 세션)

**24 Running · Job 6/6 Complete · 미해결 0**

전 워크로드가 기동했다. 부트스트랩 Job 6종(`postgres` · `mariadb` · `minio` · `kafka-topics` · `hive-schematool` · `elasticsearch-ilm-setup`) 전부 Complete.

#### 마지막까지 남았던 4건

| 대상 | 원인 | 조치 |
|---|---|---|
| **cmmn-api** | `application-kafka.yml` 의 `kafka-dev` 프로파일이 `spring.kafka.consumer.bootstrap-servers`·`producer.bootstrap-servers` 를 개별 지정한다. **더 구체적인 키가 우선하므로 `SPRING_KAFKA_BOOTSTRAP_SERVERS` 가 조용히 무시**됐다 | `SPRING_KAFKA_CONSUMER_/PRODUCER_BOOTSTRAP_SERVERS` 로 교체. **재빌드 없이 해소 — G9 우회** |
| **apicurio-registry** | health 가 관리 포트 9000 의 **`/health/*`** 에 있다(Quarkus 기본 `/q` 접두사 없음). 포트포워딩 실측: `:9000/health/ready`→200, `:9000/q/health/ready`→404, `:8080/*`→404 | 포트·경로 정정 + `startupProbe` 추가 |
| **gitlab** | `max_locks_per_transaction` 을 ConfigMap 에 올렸으나 **파드가 재시작되지 않아 반영되지 않았다**(Reloader 미설치). 값은 64 그대로였고 `structure.sql:60326: out of shared memory` 가 반복됐다 | PostgreSQL 재시작(→256) + 반쯤 적재된 `gitlab` DB 재생성 |
| **spark-connect** | 버킷 루트 `s3a://spark-events/` 는 `stripSuffix("/")` 후 경로 성분이 사라져 `SparkContext.scala:631` 에서 `IllegalArgumentException: path must be absolute` | `s3a://spark-events/events` + `minio-bootstrap` 이 프리픽스 생성 |
| **elasticsearch-ilm-setup** | ES 기동 전에 실행되어 CrashLoop → Failed. 기존 매니페스트에 대기 루프가 없다 | `_cluster/health` 대기 루프 추가 |

> **`envFrom: configMapRef` 는 ConfigMap 을 바꿔도 파드를 재시작하지 않는다.** GitLab 건이 여기서 두 번 헛돌았다. `reloader.stakater.com/auto: "true"` 어노테이션은 붙어 있으나 **Reloader 가 설치되지 않아 작동하지 않는다**(플랫폼 계층 미도입 항목).

#### 이 세션에서 해소한 결함

| 계층 | 건수 | 대표 |
|---|--:|---|
| P0 블로커 | 5 | Secret · 오퍼레이터 · 부트스트랩 · SA · StorageClass |
| WSL2 고유 | 3 | 마운트 전파 · debugfs · Falco |
| 레포 기존 결함 | 14 | G23 · TODO-14 · SEC-512 · G13 · Apicurio 포트/경로 · Logstash·Apicurio startupProbe · PostgreSQL 락 · Kafka quorum · cmmn-api 프로퍼티 · ES ILM 대기 |
| 작성 중 도입한 오류 | 10 | kubelet 플래그 2건 · 롤/DB 이름 2건 · `pg_isready` · SIGPIPE · NetworkPolicy · imagePullPolicy · Spark 버킷 경로 2건 |

**"작성 중 도입한 오류" 10건은 실제로 배포하지 않았다면 전부 드러나지 않았을 것들이다.** 매니페스트가 `kustomize build` 를 통과하는 것과 클러스터에서 동작하는 것은 다른 문제다.

#### 실측 메모리 (전 워크로드 Running)

```
Mem: 47 GiB total / 18 GiB used / 28 GiB available
zram: mem_used 4 MiB (disksize 32 GiB)   ← 여전히 사실상 미사용
vmstat si: 0
```

상위: GitLab 3,154 Mi · Elasticsearch 1,800 Mi · Logstash 1,417 Mi · Trino 863 Mi · Spark Connect 658 Mi · Kafka 605 Mi

**§2 의 zram 설계는 아직 시험되지 않았다.** 현재 배포된 것은 `[구현됨]` 매니페스트 24종이며, B안 58.75 GiB 는 `[목표]` 컴포넌트(Prometheus·Grafana·Loki·Tempo·Wazuh·Vault·Kubescape·lakehouse-v1 8종·governance 8종 등 ~40종)를 포함한 수치다. 그것들의 매니페스트 작성이 선행되어야 §2-3 의 압축률 가정을 검증할 수 있다.


### 8-8. 이미지 최신화 (2026-09-01)

`:latest` 를 전부 걷어내고 실측 최신으로 고정했다. 현재 워크로드 스펙에 `:latest` **0건**.

#### ★ Bitnami 무료 카탈로그 축소 — prod 의 핀이 이미 깨져 있었다

```
없음  bitnami/postgresql:16.4.0     <- prod 핀
없음  bitnami/mariadb:11.4.3        <- prod 핀
없음  bitnami/redis:7.4.1           <- prod 핀
```

Bitnami 가 Docker Hub 무료 카탈로그에서 **버전 태그를 전부 내렸다**(2025-08). `bitnami/*` 에는 `latest` 와 다이제스트 아티팩트만 남았고 구버전은 `bitnamilegacy/*` 로 이동했다. **지금 prod 를 배포하면 이 3개가 `ImagePullBackOff` 로 죽는다.**

`bitnamilegacy` 는 동결 스냅샷이라 오히려 다운그레이드(18.6 → 17.6.0)다. → **다이제스트로 고정**한다. 재현 가능하면서 최신이고 **G37(다이제스트 핀 부재)도 함께 해소**된다.

#### 상향 내역

| | 이전(prod 핀) | 현재 |
|---|---|---|
| postgresql | 16.4.0 | **18.6** (digest) |
| mariadb | 11.4.3 | **13.0.1** (digest) |
| redis | 7.4.1 | **8.10.1** (digest) |
| mongodb | 7.0.14 | 8.3.8 |
| kafka | 4.1.1 | 4.3.1 |
| keycloak | 26.0.7 | 26.7.3 |
| apicurio | 3.0.4 | 3.3.2 |
| akhq | 0.25.1 | 0.28.0 |
| trino | 465 | 483 |
| nginx | 1.27.3 | 1.31.4 (mainline) |
| gitlab | 17.6.2-ee.0 | 19.3.1-ee.0 |
| minio | RELEASE.2024-11-07 | RELEASE.2025-09-07 |
| **Elastic 스택** | **8.17.0** | **9.5.2 (메이저)** |
| hive | 4.0.1 | 4.0.1 (스키마 버전 고정) |

`9.5.3` 은 `artifacts-api.elastic.co` 목록에는 있으나 **`docker.elastic.co` 에 이미지가 아직 게시되지 않았다.** 실제 pull 가능한 최신은 9.5.2 다.

#### Elastic 8 → 9 breaking change 3건

| 대상 | 변경 |
|---|---|
| **Logstash** | `http.host` → **`api.http.host`** (`Setting "http.host" doesn't exist`) |
| **Logstash** | `ssl_certificate_verification` **제거** → `ssl_verification_mode` |
| **Filebeat** | `container` input **제거** → `filestream` + `parsers.container` |

**ECK 웹훅은 다운그레이드를 거부한다** — CR 이 한 번 9.5.3 으로 기록되면 9.5.2 로 내릴 수 없다(`Downgrades are not supported`). CR·PVC 를 지우고 재생성해야 했다. **존재하지 않는 버전을 CR 에 쓰면 되돌리기가 비싸다.**

#### 부수 해소

- 기존 `images:` 블록에 **누락되어 있던 로테이션·스캔 이미지 6종** 추가 (`curl` · `mc` · `alpine/git` · `trivy` · `busybox` · `falco-no-driver`)
- `rotate-redis` 가 쓰던 **`bitnami/redis-cluster` 는 저장소 태그가 비었다.** 워크로드와 다른 이미지를 쓰던 것도 결함이므로 `bitnami/redis` 로 통일했다
- `local` 오버레이에도 동일 핀 적용 → Kyverno `disallow-latest` 위반 해소
- **로컬 빌드 이미지는 `imagePullPolicy: IfNotPresent` + containerd 에 핀 태그를 함께 반입**해야 한다. 태그만 바꾸면 `ImagePullBackOff` 가 난다


### 8-9. bitnami → 공식 이미지 전환 · `:latest` 활용

`bitnami/*` 는 2025-08 무료 카탈로그 축소로 **버전 태그가 사라져 재현 가능한 핀이 불가능**해졌다. 공식 업스트림 이미지로 전환했다.

#### 규약 차이 — 여기서 5건이 깨졌다

| 항목 | bitnami | 공식 | 결과 |
|---|---|---|---|
| PostgreSQL 환경변수 | `POSTGRESQL_USERNAME/DATABASE/PASSWORD` | `POSTGRES_USER/DB/PASSWORD` | ConfigMap·StatefulSet 수정 |
| PostgreSQL 추가 플래그 | `POSTGRESQL_EXTRA_FLAGS` | **대응 없음** | `args: [postgres, -c, max_locks_per_transaction=256]` |
| PostgreSQL 데이터 경로 | `/bitnami/postgresql` | `/var/lib/postgresql/data` + **`PGDATA` 하위 디렉터리 필수** | `lost+found` 때문에 마운트 지점 자체를 못 쓴다 |
| MariaDB 데이터 경로 | `/bitnami/mariadb/data` | `/var/lib/mysql` | |
| **MariaDB 클라이언트** | `mysqladmin` · `mysql` | **`mariadb-admin` · `mariadb`** | MariaDB 11+ 에서 개명. **readiness probe·부트스트랩·로테이션 3곳** |
| Redis 비밀번호 | `REDIS_PASSWORD` 환경변수 | **읽지 않는다** | `--requirepass` 인자로 |
| Redis 데이터 경로 | `/bitnami` | `/data` | |
| uid | 1001 | **999** | `securityContext` 3종 |

**MariaDB 클라이언트 개명이 가장 은밀했다.** readiness probe 가 `mysqladmin` 을 써 `mariadb-0` 이 `0/1` 로 남았고 → headless Service 에 엔드포인트가 생기지 않아 → `mariadb-bootstrap` 과 `cmmn-api` 가 `UnknownHostException: mariadb-headless` 로 죽었다. **증상이 원인에서 두 단계 떨어져 있다.**

#### PVC 정합성

데이터 경로가 바뀌므로 DB 3종의 PVC 를 재생성해야 한다. 그런데 **PostgreSQL PVC 만 지우면 GitLab 이 깨진다** — GitLab 은 자기 PVC 에 "마이그레이션 완료" 상태를 기록하므로, DB 는 비었는데 스키마 적재를 건너뛴다.

```
PG::UndefinedTable: ERROR: relation "application_settings" does not exist
```

→ **GitLab PVC 와 `gitlab` DB 를 함께 재생성**해야 한다.

#### 태그 정책

| 대상 | 정책 |
|---|---|
| `base` | **`:latest`** — 예외 2건: `apache/hive:4.0.1`(스키마 버전에 묶임), `busybox:1.36`(변동 이유 없음) |
| `overlays/local` | `:latest` (base 그대로) |
| `overlays/prod` | **핀 유지** — Kyverno `disallow-latest` 가 **Enforce** 라 `:latest` 는 admission 에서 차단된다 |

prod 핀: `postgres:18.6` · `mariadb:12.3.3` · `redis:8.10.1` · 그 외 20종.


### 8-10. 목표 아키텍처 배포 — 진행 상황과 다음 단계

`[목표]` 컴포넌트는 **매니페스트가 존재하지 않는 ~40종**이다. 한 번에 올리면 원인 추적이 불가능하므로 의존 순서대로 단계별로 올린다.

#### 단계 계획

| 단계 | 구성요소 | 신규 매니페스트 | 상태 |
|:-:|---|--:|---|
| **1** | **Prometheus · Grafana** | 7 | ✅ **완료** — INFRA-601 해소 |
| **2** | **Loki · Tempo · OTel(agent·gateway)** | 13 | ✅ **완료** — 로그·트레이스 경로 개통 |
| **3** | **governance — DS389 · LAM · Solr · Ranger(admin·usersync) · Knox** | 20 | ✅ **완료** — LDAP→Ranger 동기화 실증 |
| **4** | **security-min — Tetragon · Trivy Operator · Policy Reporter · Vault · Wazuh 2종** | 11 + 오퍼레이터 3 | ✅ **완료** |
| **5** | **lakehouse-v1 — ZooKeeper · HDFS · HBase 2종 · HiveServer2** | 20 | ✅ **완료** — HDFS·S3A 동시 처리 실증(§8-16). 단 `overlays/local/` 전용(§8-18) |
| **6** | **GlitchTip · Jenkins · Kafka Bridge** | 16 | ✅ **완료** — 브리지 HTTP 왕복 실증(§8-20). Apicurio Studio 4종은 폐기라 제외 |
| **7** | **security-full — SafeLine · Kubescape · DT · DefectDojo · Caldera** | 17 | ✅ **완료** — 5종 전부 기동(§8-26). **zram 압축률 2.98배 실측** · 소요 3.49 GiB(산정 13.7 GB 의 1/4) |

#### 1단계 결과

```
prometheus-0  1/1 Running   up: apiservers 1 · cadvisor 1 · pods 8
grafana       1/1 Running   Prometheus + Elasticsearch 데이터소스 프로비저닝
```

- 스크레이프는 `prometheus.io/scrape` 어노테이션 옵트인 방식. ClusterRole 은 읽기 전용
- 보존 3일 (문서 §4-6 의 30GB 산정 근거)
- Grafana 데이터소스를 **프로비저닝으로 선언**해 UI 수작업을 남기지 않는다
- `default-deny-ingress` 하에서 스크레이프가 막히므로 네임스페이스 전체에 `prometheus` 인바운드를 허용하는 NetworkPolicy 를 함께 넣었다

#### 2단계 결과 (2026-09-01)

```
loki-0                        1/1 Running
tempo-0                       1/1 Running
otel-agent-*    (DaemonSet)   1/1 Running
otel-gateway-*  (Deployment)  1/1 Running

up: 16 타깃 (pods 12 · cadvisor 1 · apiservers 1 · otel-collector-internal 2)
```

파이프라인:

```
앱 ──OTLP──▶ otel-agent (노드마다 1)
                 │  filelog(/var/log/pods) + hostmetrics + OTLP 수신
                 │  k8sattributes 로 파드 메타데이터 부착
                 ▼
             otel-gateway (백엔드를 아는 유일한 지점)
                 ├─ traces  ──OTLP gRPC──▶ Tempo
                 ├─ logs    ──OTLP HTTP──▶ Loki  (/otlp/v1/logs)
                 └─ metrics ──:8889──────▶ Prometheus 가 스크레이프(pull)
```

**실측 확인**

| 신호 | 확인 방법 | 결과 |
|---|---|---|
| 로그 | `/loki/api/v1/labels` | `k8s_namespace_name`·`k8s_pod_name`·`service_name` 등 8개 라벨, 22개 서비스 |
| 트레이스 | 합성 스팬을 게이트웨이 `:4318/v1/traces` 로 POST → Tempo `/api/traces/{id}` | 조회 성공. TraceQL `{resource.service.name="…"}` 도 매치 |
| 메트릭 | `count({__name__=~"system_.*"})` | 46 시리즈 (hostmetrics 가 agent→gateway→Prometheus 로 도달) |
| 파이프라인 건전성 | `count({__name__=~"otelcol_.*"})` | 130 시리즈 |

**설계 판단**

- **k8sattributes 는 게이트웨이가 아니라 에이전트에 둔다.** 게이트웨이에 두면 소스 IP 가 에이전트 IP 라 `pod_association`의 `connection` 소스가 전부 오배정된다
- **filelog 는 `file_storage` 확장으로 오프셋을 디스크에 남긴다.** 없으면 재시작마다 `start_at: end` 가 다시 적용되어 그 사이 로그가 사라진다
- **로그 수집은 Filebeat→ES 와 병존한다.** 목표 아키텍처가 두 계통을 모두 갖는다. 하나로 합치는 것은 별도 결정이다
- **Loki 저장소는 filesystem.** MinIO 로 옮기면 로그 보존이 레이크하우스 버킷 예산을 침범한다
- **Tempo `metrics_generator` 는 켜지 않았다.** Prometheus 에 `--web.enable-remote-write-receiver` 를 열어야 하는데 로컬 CPU 예산에서 서비스 그래프의 값이 비용을 넘지 않는다
- **otel-agent 는 root + `DAC_READ_SEARCH`.** 컨테이너 로그를 읽어야 한다. Filebeat 와 같은 사유의 **4번째 의도된 예외**다. privileged 도 hostNetwork 도 아니다

**2단계에서 실제로 걸린 것**

1. **Tempo 3.0 이 설정 스키마를 바꿨다.** `grafana/tempo:latest` 는 v3.0.0 이고 2.x 의 최상위 `ingester`·`compactor` 키가 사라졌다.

   ```
   failed to parse configFile: field ingester not found in type app.Config
                                field compactor not found in type app.Config
   ```

   | 2.x | 3.0 |
   |---|---|
   | `ingester.max_block_duration` | `live_store.max_block_duration` |
   | `compactor.compaction.block_retention` | `overrides.defaults.compaction.block_retention` |

   분산 모드는 `distributor → Kafka → block_builder` 를 타지만 **single-binary 는 앱 와이어링이 Kafka 소비를 끈다**(`livestore.Config.ConsumeFromKafka`). Kafka 의존이 새로 생기지는 않는다.

2. **ClusterRoleBinding subject 의 네임스페이스가 base 에 박혀 있었다.** `prometheus` 는 `local`, `falco`·`trivy` 는 `dev` 였다. kustomize 네임스페이스 변환기는 subject 의 `default` 만 오버레이 값으로 바꾼다. 실제 값이 박혀 있으면 **다른 오버레이에서 바인딩이 조용히 빗나간다** — 권한이 안 붙는데 에러는 나지 않는다. 셋 다 `default` 로 고쳤다.

3. **`prometheus.io/port` 어노테이션은 포트를 하나만 가리킨다.** 게이트웨이는 앱 메트릭(`:8889`)과 자기 텔레메트리(`:8888`)를 둘 다 내는데 어노테이션으로는 하나뿐이다. `otel-collector-internal` 전용 잡을 Prometheus 설정에 분리했다. 0.159 의 메트릭 이름에는 `_total` 접미사가 없다(`otelcol_exporter_sent_log_records`).

4. **mongodb 의 liveness 가 `mongosh` 였다.** mongosh 는 Node.js CLI 라 기동만으로 수 초가 걸린다. k3s 재시작으로 CPU 가 몰리자 `timeoutSeconds: 5` 를 넘겨 실패했고, **liveness 실패는 컨테이너를 죽이므로** mongod 가 멀쩡한데 9회 재시작했다. liveness 는 `tcpSocket`, readiness 만 mongosh(timeout 15s)로 바꿨다.

5. **초기 `no children to pick from`·`no such host` 는 정상이다.** 게이트웨이가 백엔드보다 먼저 뜨면 gRPC 리졸버가 빈 결과를 캐시한다. 재시도로 스스로 회복한다 — 30초쯤 기다리고 판단할 것.

6. **hive-metastore 가 같은 이유로 10회 재시작했다.** liveness 가 `tcpSocket` 이었는데도 `i/o timeout` 이 났다 — CPU 가 붐비면 JVM 이 TCP accept 조차 늦다. period 10s · timeout 5s · failureThreshold 3(기본)이면 30초만 밀려도 죽는다. 재시작이 스키마 점검부터 다시 돌아 더 붐비게 만드는 악순환이었다. period 20s · timeout 10s · failureThreshold 6 으로 완화했다.

7. **livy 는 애초에 기동한 적이 없었다.** 2단계와 무관하나 이번에 드러났다. 연쇄로 두 건이다.

   ```
   ① UnsupportedFileSystemException: fs.AbstractFileSystem.s3a.impl=null
   ② IllegalArgumentException: auth requires livy.server.auth..class to be provided
   ```

   ①은 `livy.server.recovery.state-store.url = s3a://livy-recovery/` 때문이다. Livy 의 `FileSystemStateStore` 는 Hadoop 의 **FileContext(AbstractFileSystem) API** 를 쓰는데, s3a 의 AbstractFileSystem 구현(`org.apache.hadoop.fs.s3a.S3A`)은 **Hadoop 2.8+** 에 있고 `oneinch/livy` 이미지의 하둡 클라이언트는 **2.7.3** 이다. `fs.s3a.impl`(FileSystem API)만으로는 안 된다. 이미지의 하둡 클라이언트를 3.x 로 올리기 전까지(TODO-37) emptyDir 위 `file:///opt/livy/recovery` 를 쓴다. 레플리카가 1이라 공유 스토어 요구는 없다.

   ②는 `livy.server.auth.type =` 로 **빈 값**을 둔 탓이다. Livy 는 이 키가 null 인지만 보는데 빈 문자열은 null 이 아니다. 빈 타입으로 인증을 켜고 `livy.server.auth..class` 를 찾는다. **끄려면 키를 아예 두지 않아야 한다.**

   교훈은 하나다 — **startup probe 가 계속 실패하는 파드는 "느린 것"이 아니라 "죽는 중"일 수 있다.** `0/1 Running` 은 정상 기동 중과 구분되지 않으므로 로그를 봐야 한다.

#### CPU 예약을 낮췄다 (2026-09-01)

1단계 종료 시점에 CPU requests 가 68%(13/19)였다. 남은 ~130종은 **메모리가 아니라 CPU requests 에서 먼저 스케줄이 막힌다.**

적용:

- `local/kubelet-config.yaml` 의 `systemReserved.cpu`·`kubeReserved.cpu` **500m → 250m**
  → `/etc/rancher/k3s/kubelet-config.yaml` 갱신 후 `sudo systemctl restart k3s`
  → Allocatable CPU **19 → 19.5**
- 신규 서비스의 `requests.cpu` 를 50~100m 로 억제 (2단계 4종 합계 350m)

**아직 남은 것** — `.wslconfig` 의 `processors=20 → 24`. `wsl --shutdown` 이 필요해 클러스터가 내려간다. 3단계 착수 직전에 하는 편이 낫다.

2단계 종료 시점:

```
requests   메모리 51% (23.6/45 GiB)   CPU 68% (13.35/19.5)
limits     메모리 85%                  CPU 137% (오버커밋)
파드       30 Running(전부 Ready) · 5 Completed · 실패 0
           — livy·mongodb·hive-metastore 결함 3건을 이번에 함께 해소했다
zram       32G 중 81M 사용 (아직 압박 없음)
```

### 8-11. 3단계 결과 — governance (2026-09-01)

```
ds389-0                 1/1 Running    LDAP  3389/3636
lam-*                   1/1 Running    :80
solr-0                  1/1 Running    :8983  ranger_audits 코어 OK
ranger-admin-0          1/1 Running    :6080  ranger DB 78 테이블
knox-*                  1/1 Running    :8443
ds389-bootstrap         Complete       엔트리 3건 검증
```

#### 핵심 설계 — 이미지의 설정을 덮어쓰지 않고 이름을 맞춘다

`apache/ranger:2.9.0` 은 컨테이너용으로 잘 만들어져 있다. `install.properties` 에 이미 다음이 구워져 있다.

```
DB_FLAVOR=POSTGRES        db_host=ranger-db          db_name=ranger
audit_store=solr          audit_solr_urls=http://ranger-solr:8983/solr/ranger_audits
policymgr_external_url=http://ranger-admin:6080
```

엔트리포인트 `ranger.sh` 가 추가로 읽는 것은 `POSTGRES_PASSWORD`·`RANGER_DB_USER`·`RANGER_DB_PASSWORD` 뿐이다.

템플릿 100여 줄을 복사해 유지보수하는 대신 **별칭 Service 로 이름을 맞췄다**.

| Service | 실제 대상 | 이유 |
|---|---|---|
| `ranger-db` | PostgreSQL 파드 | `db_host=ranger-db` |
| `ranger-solr` | Solr 파드 | `audit_solr_urls=http://ranger-solr:8983/...` |
| `ranger-admin` | Ranger admin 파드(ClusterIP) | `policymgr_external_url=http://ranger-admin:6080` |

덮어쓸 설정이 0이고, 이미지가 올라가도 깨질 곳이 그만큼 적다.

`ranger.sh` 는 `${RANGER_HOME}/.setupDone` 으로 재실행을 막는데 `RANGER_HOME=/opt/ranger` 는 이미지 본체라 PVC 로 덮을 수 없다. **영속화하지 않고 매 기동 setup 재실행을 받아들였다** — `setup.sh` 는 스키마 버전을 보고 넘어가므로 안전하고, 대신 재시작이 2~3분 걸린다.

#### v1·인수인계 문서의 오류 정정

| 항목 | 기존 서술 | 실제 |
|---|---|---|
| Knox 이미지 | v1 "로컬 빌드 필요" / 문서 "`apache/knox:2.1.0` 공식 이미지 존재" | **둘 다 틀렸다.** Docker Hub `apache/knox` 태그는 `latest·3.0·3·3.0.0-RC2·3.0.0-RC1` 5개뿐이고 2.x 가 없다. 반대로 downloads.apache.org 의 정식 릴리스는 **2.1.0** 이 최신이고 3.0.0 은 없다. "공식 이미지"와 "정식 릴리스"가 배타적이다 |
| Solr 이미지 | `apache/solr:9.10.0-slim` | `apache/solr` 저장소에 태그가 없다. **`library/solr`** 다 |
| ranger-usersync | `eclipse-temurin` 위에서 tarball 다운로드 | **공식 이미지가 없다.** `apache/ranger` 는 admin 만 담고 있다(`/opt/ranger/ranger-2.9.0-admin`) |
| Ranger JDK | 문서 "2.9 는 JDK 11+ 요구" | 공식 이미지가 **JDK 8**(Temurin 1.8.0_492)로 돌아간다 |
| DS389 env | v1 이 `DS_DOMAIN`·`DS_INSTANCE_NAME` 설정 | `dscontainer` 는 두 변수를 **읽지 않는다.** 인식 목록은 `DS_DM_PASSWORD`·`DS_SUFFIX_NAME`·`DS_ERRORLOG_LEVEL`·`DS_MEMORY_PERCENTAGE`·`DS_REINDEX`·`DS_STARTUP_TIMEOUT`·`DS_STOP_TIMEOUT` |
| DS389 특권 | v1 `privileged: true` | 불필요하다. root + capability 6종으로 뜬다 |

**Knox 는 `apache/knox:3.0`(공식 이미지, 미릴리스 3.0.0 코드)을 택했다.** 로컬 검증 환경이고 로컬 빌드 파이프라인을 만들지 않기로 한 결정이다. 태그가 가변이므로 prod 는 다이제스트로 핀했다.

#### 3단계에서 실제로 걸린 것

**1. `ns-slapd` 의 파일 capability — 가장 오래 헤맨 건**

```
PermissionError: [Errno 1] Operation not permitted: '/usr/sbin/ns-slapd'
```

`/usr/sbin/ns-slapd` 에 `cap_net_bind_service` 가 **파일 capability** 로 박혀 있다. 파일의 permitted 집합이 프로세스 bounding 집합의 부분집합이 아니면 커널이 `execve` 를 EPERM 으로 거부한다. 컨테이너는 3389/3636 을 쓰므로 **기능적으로는 필요 없는데도 exec 하려면 bounding 집합에 있어야 한다.**

증상이 두 단계로 어긋나 보이는 것이 함정이다.

```
1차 시도   EPERM 으로 죽음. 그 전에 /data/config/dse.ldif 를 이미 써 둠
2차 시도~  "Another instance named 'localhost' may already exist"
```

두 번째 메시지만 보고 **볼륨 문제 → 버전 문제로 두 번 오진**했다(3.1→3.0 강등까지 갔다가 되돌렸다). PVC 를 지우고 다시 해도 같았던 것은 매번 1차에서 파일을 쓰고 죽었기 때문이다.

실측 비교:

| capability | 결과 |
|---|---|
| `drop:["ALL"]` + CHOWN·DAC_OVERRIDE·FOWNER·SETGID·SETUID | EPERM |
| 위 + `SETPCAP` | EPERM |
| 위 + **`NET_BIND_SERVICE`** | **정상**(3.0·3.1 모두) |
| `capabilities` 미지정(기본 집합) | 정상 |

> **일반화** — `drop:["ALL"]` 을 넣기 전에 그 이미지의 바이너리에 파일 capability 가 있는지 확인할 것. 있으면 기능상 불필요해도 bounding 집합에 넣어야 exec 이 된다.

**2. root 인데 `Permission denied`**

```
sed: can't read /etc/ldap-account-manager/config.cfg: Permission denied
```

uid 0 인데 EACCES 다. root 가 파일 권한을 무시하는 것은 `CAP_DAC_OVERRIDE` 가 하는 일이라, 그것을 버리면 root 도 남의 파일을 못 읽는다. DS389·LAM 처럼 **root 로 시작해 설정을 마치고 비특권 사용자로 내려가는 이미지**는 `CHOWN·DAC_OVERRIDE·FOWNER·SETGID·SETUID` 가 필요하다.

**3. emptyDir 이 이미지의 내용물을 가린다**

LAM 설정을 영속화하려고 `/var/lib/ldap-account-manager` 에 emptyDir 를 걸었더니 이미지가 담고 있던 설정 템플릿이 가려졌다.

```
cp: cannot stat '/var/lib/ldap-account-manager/config/unix.sample.conf'
```

LAM 설정은 env 로 매 기동 재생성되므로 영속화할 것이 애초에 없었다.

**4. Ranger 가 기본 `admin/admin` 으로 남았다 — 보안 결함**

배포 후 확인해 보니 `admin/admin` 이 API 에 200 을 돌려주었다. `ranger.sh` 는 `rangerAdmin_password=${RANGER_DB_PASSWORD}` 를 넣는데, **Ranger 의 비밀번호 정책**(대문자·소문자·숫자·특수문자 `@#$%^&+=` 각 1자 이상, 8자 이상)에 걸리면 조용히 넘어가고 기본값이 남는다. `create-secrets.sh` 의 `gen()` 은 소문자 hex 만 만들어 정책을 통과하지 못했다.

**실패도 경고도 없다.** 배포 후 `admin/admin` 을 직접 찔러보지 않았으면 그대로 넘어갔을 것이다.

→ `ranger-secret` 만 정책을 만족하는 형식으로 생성한다. PostgreSQL 은 문자 구성을 따지지 않으므로 DB 롤에도 같은 값을 쓴다.

**5. 389ds 는 suffix 백엔드를 만들지 않는다**

`DS_SUFFIX_NAME` 을 주어도 백엔드가 생기지 않는다. rootDSE 의 `namingContexts` 가 비어 있고 백엔드 목록도 0건이다. 그 상태에서는 루트 엔트리 추가마저 거부된다.

```
ldapsearch -b dc=oneinchmarket,dc=co,dc=kr  ->  result: 32 No such object
ldapadd   dc=oneinchmarket,dc=co,dc=kr      ->  ldap_add: No such object (32)
```

→ `ds389-bootstrap` Job 이 `dsconf backend create --create-suffix` 로 백엔드와 루트를 함께 만들고 `ou=people`·`ou=groups` 를 추가한다.

**6. 내가 만든 Job 이 조용히 성공했다**

첫 버전의 `ds389-bootstrap` 은 세 번의 `ldapadd` 가 전부 32 로 실패했는데도 `Complete` 로 끝났다. `set -e` 가 없고 마지막 명령이 `echo` 라 종료 코드가 0이었다. → 마지막에 실제로 조회해 엔트리 수를 세고 3건 미만이면 `exit 1`.

> 부트스트랩 Job 은 **끝에 검증을 넣고 검증 실패를 종료 코드로 드러내야 한다.** 그러지 않으면 아무것도 안 한 Job 이 초록색으로 남는다.

**7. LDIF 의 line folding**

YAML 블록 안에서 LDIF 를 쓰면 들여쓰기가 그대로 넘어간다. LDIF 는 **공백으로 시작하는 줄을 앞줄의 이어붙임으로 해석**하므로 `sed 's/^[[:space:]]*//'` 로 벗겨내야 한다.

#### ranger-usersync — 로컬 빌드로 배포했다

처음에는 "공식 이미지가 없으니 보류" 로 두었으나 **Apache Ranger 저장소에 UserSync Dockerfile 이 있다.**

```
apache/ranger @ release-ranger-2.9.0
  dev-support/ranger-docker/Dockerfile.ranger-usersync
  dev-support/ranger-docker/scripts/usersync/ranger-usersync.sh
  dev-support/ranger-docker/scripts/usersync/ranger-usersync-install.properties
```

"공식 이미지가 없다" 는 맞았지만 **그 빌드가 무겁다고 본 것이 틀렸다.** 실제로는 공식 베이스(`apache/ranger-base`) + 정식 릴리스 tarball + 스크립트 하나이고, 이 레포에는 이미 `docker/` + `local/build-images.sh`(podman 빌드 → k3s containerd import) 경로가 있다.

`docker/ranger-usersync/` 로 이식했다. upstream 과의 차이는 하나뿐이다.

| | upstream | 여기 |
|---|---|---|
| usersync 배포물 | 소스 빌드 산출물 `./dist/` 를 COPY | `downloads.apache.org` 의 릴리스 tarball 을 **빌드 시점에** `ADD` |

v1 이 **파드 기동마다** 받던 것과는 다르다 — 런타임 인터넷 의존이 없다.

**비밀번호를 ConfigMap 에 두지 않는다.** `install.properties` 에는 LDAP bind 비밀번호와 `rangerUsersync_password` 가 들어가는데 upstream 엔트리포인트는 그 파일을 읽을 뿐이라 주입 지점이 없다. ConfigMap 에 자리표시자를 둔 템플릿을 두고, 파드 기동 시 Secret 에서 온 env 로 치환한 뒤 upstream 스크립트를 `exec` 한다. v1 은 이 값들을 ConfigMap 평문으로 두었다.

**DS389 매핑** — upstream 기본값이 그대로는 맞지 않는다.

| 항목 | upstream 기본 | DS389 |
|---|---|---|
| `SYNC_LDAP_USER_OBJECT_CLASS` | `person` | `inetOrgPerson` |
| `SYNC_LDAP_USER_NAME_ATTRIBUTE` | `cn` | `uid` |
| 그룹 원천 | 사용자 엔트리의 `memberof` | `ou=groups` 직접 검색(`SYNC_GROUP_SEARCH_ENABLED=true`, `groupOfNames`/`member`) |

**빌드·배포에서 걸린 것 5건**

1. **podman 은 short-name 을 해석하지 않는다.** `apache/ranger-base:...` 가 `did not resolve to an alias and no unqualified-search registries are defined` 로 실패한다. `docker.io/` 를 명시해야 한다
2. **`ranger-base` 의 `ranger` 는 uid 1000, `apache/ranger`(admin)는 uid 1001 이다.** admin 쪽 값을 복사해 써서 `/opt/ranger/usersync`(1000 소유)에 install.properties 를 쓰지 못했다
3. **Kerberos 를 안 써도 `hadoop_conf` 키는 있어야 한다.** `setup.py:369` 가 `globalDict['hadoop_conf']` 를 조건 없이 읽는다. `KeyError` 로 setup 이 죽으면 `conf/` 가 만들어지지 않아 그다음 `start.sh` 까지 연쇄로 실패한다
4. **로그·pid 디렉터리에 emptyDir 를 걸면 안 된다.** `setup.py:492` 가 두 디렉터리에 `os.chown` 을 거는데, emptyDir 는 `root:fsGroup` 소유로 붙어 비특권 uid 가 소유자를 바꾸려면 `CAP_CHOWN` 이 필요하다 → EPERM. 이미지가 이미 ranger 소유로 만들어 둔다
5. **upstream 의 `/etc/init.d` 준비를 지우면 안 된다.** "SysV init 은 컨테이너에서 안 쓴다" 며 지웠다가 되돌렸다. `setup.py:319 initializeInitD` 가 `/etc/init.d/ranger-usersync` 에 직접 쓴다. 파일이 미리 없으면 비특권 uid 가 만들지 못한다

> **일반화** — upstream Dockerfile 을 이식할 때 "컨테이너에서 안 쓸 것 같은 줄" 을 지우지 말 것. `setup.py` 처럼 뒤에서 그 경로를 쓰는 코드가 있다. 지운 줄 3·4·5 가 전부 그런 경우였다.

**실증** — DS389 의 스모크 픽스처가 Ranger 로 넘어왔다.

```
ds389  uid=oim-svc,ou=people,dc=oneinchmarket,dc=co,dc=kr
       cn=oim-admins,ou=groups,dc=oneinchmarket,dc=co,dc=kr
   ↓ usersync (SYNC_INTERVAL 5분)
ranger /service/xusers/users   -> admin · oim-svc · rangertagsync · rangerusersync
       /service/xusers/groups  -> oim-admins · public
```

`ds389-bootstrap` 이 픽스처 2건을 만든다. 원천이 비어 있으면 "0명 동기화" 와 "설정이 틀려 0명" 을 구분할 수 없다.

#### 3단계 종료 시점 자원

```
requests   메모리 57% (26.4/45 GiB)   CPU 71% (14.0/19.5)
limits     메모리 98%                  CPU 154% (오버커밋)
파드       36 Running(전부 Ready) · 6 Completed · 실패 0
```

**★ 메모리 limits 가 98% 다.** requests 는 아직 여유가 있으나 limits 합이 노드 용량에 사실상 닿았다. **4단계 착수 전에 반드시 정리해야 한다.**

- 신규 워크로드의 limits 를 보수적으로 잡거나
- 기존 워크로드(GitLab·Trino·Elasticsearch·Kafka)의 limits 를 실사용 기준으로 낮추거나
- `.wslconfig` 의 `memory=48GB` 를 올린다(호스트 63.4 GB 중 15 GB 를 Windows 에 남겨 둔 상태다)

`.wslconfig` 의 `processors=20 → 24` 는 아직 하지 않았다. CPU 71% 로 3단계를 넘겼다 — 이번 병목은 CPU 가 아니라 메모리 limits 다.

### 8-12. 4단계 결과 — security-min (2026-09-01)

```
tetragon-*         2/2 Running   (DaemonSet)      ns tetragon
tetragon-operator  1/1 Running                    ns tetragon
trivy-operator     1/1 Running   configaudit 188  ns trivy-system
policy-reporter    1/1 Running   policyreports    ns policy-reporter
vault-0            1/1 Running   Sealed=false     ns local
wazuh-indexer-0    1/1 Running   OpenSearch       ns local
wazuh-manager-0    1/1 Running   ossec 9종 가동   ns local
```

#### 선행 작업 — 메모리 limits 정리

3단계 종료 시점에 노드 메모리 limits 합이 **98%** 였다. requests 는 57% 라 스케줄은 되지만, limits 오버커밋은 실 RAM 압박으로 이어져 zram 스래싱과 축출로 나타난다.

`kubectl top` 과 대조해 과다한 13종을 낮춰 **81%** 로 내렸다(약 7.6 GiB 회수). 이후 4단계 워크로드를 올려 최종 93%다.

이 작업에서 두 가지를 배웠고, 둘 다 실패로 배웠다. 아래 "실제로 걸린 것" 1·2번이다.

#### 설치 경로

| 구성요소 | 경로 | 비고 |
|---|---|---|
| Tetragon 1.7.1 | `install-operators.sh` · `helm template \| kubectl apply` | 정적 매니페스트가 없다 |
| Trivy Operator v0.34.0 | `install-operators.sh` · `deploy/static/trivy-operator.yaml` | |
| Policy Reporter 3.10.0 | `install-operators.sh` · 얕은 클론 후 `install.yaml` | |
| Vault 2.1.0 | `kubernetes/base/security/vault` (wave 4) | 수기 매니페스트 |
| Wazuh 4.14.7 | `kubernetes/base/security/wazuh` (wave 4) | 수기 매니페스트 |

**Helm 을 "설치 도구"가 아니라 "템플릿 렌더러"로만 쓴다.** Tetragon 은 정적 매니페스트를 배포하지 않는다(Helm 차트뿐). 2천 줄을 손으로 옮기면 업스트림 추종이 불가능해지므로 `helm template | kubectl apply` 로 **렌더만** 한다. 클러스터에 Helm 릴리스가 남지 않으므로 CLAUDE.md 의 "No Helm" 과 어긋나지 않는다 — 배포 시점에 Helm 이 관여하지 않는다.

#### Vault — 올려만 두었다

**시크릿 원천을 Vault 로 옮기는 것은 ADR-024 결정이며 이 단계에서 하지 않았다.** 옮기면 로테이션 CronJob 8종·git-sync·`.enc.yaml` 12개가 제거된다. 그때까지 `local/create-secrets.sh` 가 계속 원천이다.

- **dev 모드가 아니다.** 실제 봉인 상태로 뜨며 `local/vault-init.sh` 로 초기화·해제한다. dev 모드는 재시작마다 데이터가 사라지고 root token 이 고정이라 습관을 잘못 들인다
- **재시작하면 다시 봉인된다.** auto-unseal 은 KMS 를 요구하는데 로컬에 없다. `vault-init.sh unseal`
- unseal 키와 root token 을 같은 클러스터의 Secret `vault-init` 에 둔다. **프로덕션에서는 틀린 배치다.** ADR-024 때 반드시 재논의할 것

#### Wazuh — indexer 의 OpenSearch security 를 켰다

처음에는 껐다. "인증서·bcrypt 해시·`securityadmin.sh` 부트스트랩이 이 단계의 목적에 비해 크다"는 판단이었고, 대신 NetworkPolicy 로 `wazuh-manager` 만 9200 에 닿게 했다.

**그 판단이 과했다.** cert-manager 가 이미 설치되어 있어 가장 번거로운 인증서 발급이 선언적으로 해결되고, `allow_default_init_securityindex: true` 가 `securityadmin.sh` 단계를 없앤다. 남는 것은 해시 생성뿐이었다. 되돌려서 켰다.

**cert-manager 의 첫 실사용처다(TODO-02).** 지금까지 cert-manager 는 설치만 되어 있고 Issuer/Certificate 가 하나도 없었다.

```
selfsigned Issuer ─▶ CA 인증서(10년) ─▶ CA Issuer ─┬─▶ 노드 인증서 CN=wazuh-indexer,O=oneinchmarket
                                                    └─▶ admin 인증서 CN=wazuh-admin,O=oneinchmarket
```

`internal_users.yml` 은 **bcrypt 해시**를 요구하므로 ConfigMap 에 미리 넣을 수 없다 — 해시를 커밋해야 하고 비밀번호를 바꾸면 다시 만들어야 한다. initContainer 가 이미지의 `hash.sh` 로 기동 시점에 만든다. 기본 설정 일체를 emptyDir 로 복사한 뒤 `internal_users.yml` 만 덮어쓴다(디렉터리째 마운트하면 `roles.yml`·`config.yml` 이 가려져 플러그인이 뜨지 않는다).

**데모 사용자 6명(admin·anomalyadmin·kibanaserver·logstash·readall·snapshotrestore)을 전부 지웠다.** 기본 해시가 공개되어 있어 남기면 인증을 켠 의미가 없다.

**실측 — 켠 뒤에 실제로 막히는지 확인했다**

```
평문 http                    -> 000  (연결 실패 = TLS 전용)
https 인증 없음              -> 401
https 데모 admin/admin       -> 401   ← 데모 계정 제거 확인
https 데모 kibanaserver      -> 401
https admin/<생성 비밀번호>   -> 200
https filebeat/<비밀번호>     -> 200
내부 사용자                  -> admin, filebeat 둘뿐
manager 의 filebeat          -> https://wazuh-indexer:9200 연결 확립 (CA 검증 full)
wazuh-alerts-4.x-2026.09.01  -> 문서 4건   ← 알림이 실제로 흐른다
```

`FILEBEAT_SSL_VERIFICATION_MODE` 도 `none` → `full` 이다. CA 를 마운트하고 SAN 까지 검증한다.

**남은 것** — `filebeat` 사용자가 지금은 `backend_roles: ["admin"]`(= `all_access`)이다. `wazuh-alerts-*` 쓰기만 허용하는 역할로 좁히는 것은 별도 작업이다.

#### 4단계에서 실제로 걸린 것

**1. limit 을 request 아래로 내리면 워크로드가 조용히 사라진다 — 이번 세션 최악의 실수**

`minio` 의 limit 을 512Mi 로 내렸는데 requests 가 1Gi 였다(`qos-guaranteed.yaml` 이 Guaranteed 로 만들어 둔 값).

```
Pod "minio-0" is invalid: spec.containers[0].resources.requests:
  Invalid value: "1Gi": must be less than or equal to memory limit of 512Mi
```

`kustomize build` 도 `kubectl apply` 도 통과한다 — **StatefulSet 자체는 유효**하기 때문이다. 실패하는 것은 파드 생성이라 `get pods` 에는 아무것도 나타나지 않는다. CrashLoop 도 Pending 도 아니고 **그냥 없다.** `FailedCreate` 이벤트는 StatefulSet 에만 남는다.

97분 동안 모르고 지나갔다. 그리고 그동안 **엉뚱한 것을 고치고 있었다** — spark-connect 가 기동하지 못하는 것을 노드 경합 탓으로 보고 startup 예산을 5분→10분→15분으로 늘렸다. 실제로는 spark-connect 가 이벤트 로그를 여는 S3A 초기화에서 사라진 MinIO 를 기다리고 있었다. MinIO 를 되살리자 즉시 1/1 이 되었다.

> **일반화** — `limits` 를 만질 때는 그 워크로드의 `requests` 를 먼저 볼 것.
> 그리고 적용 후 `kubectl get sts` 의 READY 열을 확인할 것.
> **`get pods` 는 존재하지 않는 파드를 보여주지 않는다.**

**2. `kubectl top` 은 '지금'이지 기동 피크가 아니다**

spark-connect 를 유휴 관측값 459Mi 기준으로 1Gi 로 잡았다가 기동 중 `exit 137`(OOMKilled)로 죽었다. 1.5Gi 도 마찬가지였다. JVM 은 특히 그렇다 — 유휴 사용량으로 limit 을 정하지 말 것. 결국 base 값(2Gi)으로 되돌렸다.

**3. Vault: 파싱보다 저장이 먼저다 — unseal 키를 잃었다**

`vault operator init -format=json` 의 출력을 여러 줄인 채로 한 줄 grep 에 넣어 파싱이 실패했고 `set -e` 가 거기서 멈췄다. 그런데 init 자체는 이미 성공한 뒤였다.

```
Initialized  true      Sealed  true      vault-init Secret  NotFound
```

unseal 키는 그 출력 외에 어디에도 없다. **열쇠 없는 금고**가 되어 PVC 를 버리고 다시 초기화하는 것 말고 방법이 없었다.

> 되돌릴 수 없는 값을 만드는 명령은 **저장을 먼저, 파싱을 나중에.**
> `vault-init.sh` 는 이제 init 출력을 통째로 Secret(`init-json`)에 넣은 뒤 편의 키를 뽑는다.

**4. Vault: 이미지 엔트리포인트가 `-config` 를 이미 붙인다**

`args` 에 `-config=/vault/config/vault.hcl` 을 직접 주었더니 같은 파일을 두 번 읽어 리스너가 중복 등록되었다.

```
Error initializing listener of type tcp:
  listen tcp4 0.0.0.0:8200: bind: address already in use
```

`docker-entrypoint.sh` 가 첫 인자가 `server` 이면 `-config=/vault/config` 를 스스로 덧붙인다. 디렉터리만 마운트하고 인자는 `server` 하나만 준다.

**5. Wazuh: ossec 데몬은 chroot 한다 — `SYS_CHROOT`**

파드 로그에는 보이지 않고 `/var/ossec/logs/ossec.log` 에만 남아 있었다.

```
wazuh-analysisd: CRITICAL: (1132): Unable to chroot to directory
  '/var/ossec' due to [(1)-(Operation not permitted)]
```

`drop:["ALL"]` 로 `CAP_SYS_CHROOT` 를 버려서 filebeat 만 뜨고 ossec 데몬 12종이 전부 `not running` 으로 남았다. 여기까지 오는 데 세 번 헛짚었다 — 볼륨 배치(→ upstream 의 subPath 방식으로 교정), s6/`no_new_privs`(→ 틀렸다. filebeat 가 s6 아래에서 잘 돌고 있었다), 그리고 마지막에 chroot.

> **파드 로그가 조용하면 애플리케이션 자체 로그를 볼 것.**
> 그리고 3단계에서 이미 배운 "root 인데 EACCES 면 capability" 를 또 밟았다.
> `drop:["ALL"]` 은 이 레포에서 지금까지 5번 문제를 냈다
> (DS389 `NET_BIND_SERVICE`, LAM·wazuh `DAC_OVERRIDE`, wazuh `SYS_CHROOT`).

**6. Trivy Operator 의 동시 스캔 기본값 10은 이 노드에 과하다**

설치 직후 워크로드 40여 개를 한꺼번에 스캔하며 메모리 limits 를 102% 까지 밀어 올렸다. 키 이름은 `OPERATOR_CONCURRENT_SCAN_JOBS_LIMIT` 이다 — 처음에 `scanJob.concurrentLimit` 이라는 존재하지 않는 키로 patch 해서 **조용히 무시되는 키가 하나 늘었을 뿐** 동시 스캔은 그대로 10개였다.

**7. 설치 경로의 잔가지 3건**

- `oci://ghcr.io/cilium/charts/tetragon` 은 익명 pull 이 **403 denied** 다. `helm repo add cilium https://helm.cilium.io` 를 쓴다
- kustomize 의 원격 git fetch 에는 **27초 하드 타임아웃**이 있어 policy-reporter 저장소에서 늘 실패한다(`hit 27s timeout running git fetch`). 얕은 클론 후 로컬에서 읽는다
- Policy Reporter 배포물은 kustomization 이 아니라 `install.yaml` 한 장이고 **네임스페이스를 스스로 만들지 않는다**

**8. Wazuh security 를 켜면서 다섯 번 더 걸렸다**

전부 "설정이 무시되거나 스크립트가 조용히 죽는" 계열이었다.

| 증상 | 원인 |
|---|---|
| `cp: preserving times for '/security-config/.': Operation not permitted` | `cp -a` 가 emptyDir 마운트 루트의 타임스탬프·소유권을 보존하려 했다. `cp -r` 로 충분하다 |
| initContainer 가 **로그를 한 줄도 안 남기고** 죽는다 | YAML 블록 스칼라 안에 heredoc 을 썼다. 종료 토큰도 함께 들여쓰기되는데 `<<TOKEN` 은 0열을 요구한다. heredoc 이 안 끝나 구문 오류 → 출력 없이 종료. **3단계 LDIF line folding 과 같은 계열** |
| 그 뒤에도 **로그가 없다** | `hash.sh` 가 `java: command not found`(rc=127). `command` 로 엔트리포인트를 대체해 `OPENSEARCH_JAVA_HOME` 을 못 받았다. 게다가 `2>/dev/null` 로 stderr 를 버려 원인이 보이지 않았다 |
| `SecurityManager.checkRead -> SslCertificatesLoader.resolvePath` access denied | 인증서를 `config/` 밖(`/usr/share/wazuh-indexer/certs`)에 두었다. OpenSearch 는 `OPENSEARCH_PATH_CONF` 밖의 파일 읽기를 SecurityManager 로 막는다. 이미지 기본 `opensearch.yml` 이 `config/certs` 를 가리키고 있었는데 그 힌트를 놓쳤다 |
| (예방) 노드가 자기를 클러스터 구성원으로 인정 안 함 | `nodes_dn`·`authcz.admin_dn` 은 RFC2253 DN **문자열 비교**다. cert-manager 의 `commonName` + `subject.organizations` 가 만드는 DN 과 정확히 맞춰야 한다. `privateKey.encoding: PKCS8` 도 필수 — PKCS1 은 읽지 못한다 |

> **일반화 둘**
> - **실패를 진단할 스크립트에서 stderr 를 먼저 버리지 말 것.** `2>/dev/null` 하나로 두 번의 디버깅 라운드를 낭비했다
> - **YAML 안에 셸을 쓸 때 들여쓰기가 의미를 갖는 구문(heredoc·LDIF)은 피할 것.** `printf` 나열이 안전하다

#### Falco 와 Tetragon 을 함께 둔 이유

Falco 는 시스템콜 기반 탐지, Tetragon 은 eBPF 기반 관측 + 정책 강제(TracingPolicy)다. 목표 아키텍처가 둘 다 포함하므로 병존시킨다.

`base/observability/trivy` 의 주간 CronJob 도 Trivy Operator 와 역할이 겹친다. 오퍼레이터는 워크로드 변경을 감지해 즉시 스캔하고 결과를 CRD 로 남긴다. **CronJob 제거는 dev/prod 에도 영향이 있어 별도 결정으로 둔다** — 주간 실행이라 유휴 비용은 0이다.

#### 4단계 종료 시점 자원

```
requests   메모리 60% (28.0/45 GiB)   CPU 73% (14.3/19.5)
limits     메모리 93%                  CPU 170% (오버커밋)
파드       local 39 Running(전부 Ready) · 6 Completed
           tetragon 2 · trivy-system 1 · policy-reporter 1
```

메모리 limits 가 다시 93% 다. 5단계(lakehouse-v1, ~35종)는 Hadoop·HBase JVM 이 대거 들어오므로 **`.wslconfig` 의 `memory=48GB` 상향이 사실상 전제**다(호스트 63.4 GB 중 15 GB 를 Windows 에 남겨 둔 상태다). `processors=20 → 24` 도 같이 볼 것.

#### 5단계는 설계가 선행되어야 한다

- **TODO-33** — Hive warehouse 를 HDFS 로 되돌릴지, S3A 를 유지하고 HDFS 를 별도 용도로 둘지, Trino 에 두 카탈로그를 병행할지 미결
- **Kerberos 채택 여부** — 현재 `hadoop.security.authentication = simple`. Hadoop 네이티브 CLI 접근 요구가 없으면 불필요(§8-3 관련 논의)
- **hbase:2.6.3 로컬 빌드** — `v1/hbase/Dockerfile` 기반. 레지스트리 경로 필요(TODO-37)

#### ~~3단계 착수 전 반영할 버전 조사 결과~~ — 폐기 (2026-09-01)

이 표는 **실배포로 반증되었다.** §8-11 의 "v1·인수인계 문서의 오류 정정" 을 볼 것. 특히 다음 두 줄이 틀렸다.

- ~~`apache/knox:2.1.0` 공식 이미지 존재~~ → `apache/knox` 에 2.x 태그가 없다. 정식 릴리스 2.1.0 과 공식 이미지(3.0.x)는 배타적이다
- ~~ranger-usersync 는 `eclipse-temurin:17-jdk`~~ → 공식 이미지가 없고, `apache/ranger` 는 JDK 8 로 돌아간다


### 8-13. API 계약 도구체인 검토 (2026-09-01)

#### 발단 — Apicurio 페이지가 Apitomy 로 이동해 있었다

확인 결과 **이동한 것은 Registry 가 아니다.**

| Apicurio 프로젝트 | 상태 | 행선지 |
|---|---|---|
| **Registry** | **유지·활발** | CNCF Sandbox. 3.3.2(2026-08-27), 저장소 커밋 2026-09-01 |
| **Studio** | **완전 폐기** | → Registry 3.1.0 에 opt-in 기능으로 흡수 |
| Data Models | 이동 | → Apitomy |
| Codegen | 이동 | → Apitomy |
| Apicurito | 이동 | → Apitomy |

> *"Apicurio Studio is now fully deprecated. Studio functionality has been integrated
> into Apicurio Registry 3.1.0 as an opt-in feature."* — apicur.io/studio

**Apitomy 는 Apicurio 의 후계자가 아니다.** OpenAPI/AsyncAPI 파싱·검증·생성·변환
라이브러리(Java/TS), 클라이언트 SDK·서버 스텁 생성, 시각적 OpenAPI 편집 React 컴포넌트
— 즉 **라이브러리·코드생성 조각들의 새 집**이다. Registry 는 Apicurio 에 남아 있다.

#### 조치 — 대체재를 찾을 필요가 없었다

Studio 후계 기능이 **이미 배포된 이미지 안에 있었고 꺼져 있었을 뿐**이다.
실행 중인 3.3.2 의 `/admin/config/properties` 에서 확인했다.

```
apicurio.rest.mutability.artifact-version-content.enabled = false   ← 이 스위치
apicurio.rest.draft.production-mode.enabled              = false
```

1. **`apicurio-registry-ui:3.3.2` 배포** — Registry 3.x 는 UI 가 별도 이미지다.
   v1 에는 `registry-ui` 가 있었는데 v2 로 오면서 빠졌다. 그래서 지금까지
   레지스트리를 REST 로만 볼 수 있었다(registry 컨테이너의 `/ui/` 는 404).
   **제외 결정이 아니라 누락이었다.**
2. **편집 기능 활성** — `APICURIO_REST_MUTABILITY_ARTIFACT_VERSION_CONTENT_ENABLED=true`
3. **NetworkPolicy 2종 신규** — `apicurio-registry` 에 인바운드 허용 규칙이 **아예 없었다.**
   default-deny 아래에서 파드→레지스트리 호출이 전부 막혀 있었다(부트스트랩 Job 만 예외).

**실증**

```
콘솔                          http 200
콘솔의 API 주소               http://localhost:8080/apis/registry/v3  (로컬 오버레이 값이 렌더됨)
DRAFT 로 OpenAPI 등록          http 200 · state=DRAFT
DRAFT 내용 수정                http 204
수정 반영                     "title":"OIM Sample (edited)"
```

#### ★ `REGISTRY_API_URL` 은 브라우저가 부르는 주소다

Registry UI 는 SPA 라 백엔드 호출을 **브라우저가 직접** 한다. 클러스터 내부 DNS 를
넣으면 화면은 뜨지만 목록이 비어 보인다. 외부 진입점(Ingress/Gateway)이 0개이므로
로컬은 `overlays/local/patches/apicurio-ui-local.yaml` 이 port-forward 주소로 덮는다.

```bash
kubectl -n local port-forward apicurio-registry-0 8080:8080   # API
kubectl -n local port-forward deploy/apicurio-ui  8888:8080   # 콘솔
# 브라우저에서 http://localhost:8888
```

#### 곁들여 알게 된 것 — 삭제가 기본 비활성이다

```
apicurio.rest.deletion.artifact.enabled          = false
apicurio.rest.deletion.artifact-version.enabled  = false
apicurio.rest.deletion.group.enabled             = false
```

실증용 아티팩트를 지우려다 405 를 받았다. 설정은 `/admin/config/properties/{name}` 에
PUT 으로 **런타임 변경**이 되므로, 켰다가 지우고 되돌렸다. 계약 레지스트리의 기본값으로
타당하다 — 그대로 둔다.

#### 전역 규칙을 세웠다 — 게이트가 실제로 막는다

규칙은 DB 에 사는 **런타임 상태**라 매니페스트로 직접 표현할 수 없다. `postgres`·`ds389` 와 같은 방식으로 `bootstrap/apicurio-rules.yaml` Job 이 멱등하게 세운다(POST → 409 면 PUT). `curl` 이 레지스트리 이미지에 있어 새 이미지를 끌어오지 않는다.

```
VALIDITY      = FULL       등록 내용이 해당 타입으로 파싱·검증되는가
COMPATIBILITY = BACKWARD   새 버전이 직전 버전과 하위 호환인가
```

**실증**

| 시나리오 | 결과 |
|---|---|
| 올바른 OpenAPI (비-DRAFT) | `200` |
| **깨진 내용** | **`400 RuleViolationException` — "Syntax violation for OpenAPI artifact."** |
| 깨진 내용을 **DRAFT 로** 등록 | `200` — 초안은 규칙을 건너뛴다 |

세 번째가 중요하다. `apicurio.rest.draft.production-mode.enabled=false`(기본)에서는 **DRAFT 버전에 규칙이 평가되지 않는다.** 초안을 자유롭게 고치고 DRAFT 를 벗어날 때 검사받는 흐름이며, 앞의 편집 기능과 정확히 맞물린다. 초안 단계에서도 검사받게 하려면 그 속성을 켜면 된다.

**알고 쓸 것** — `COMPATIBILITY` 는 Avro·Protobuf·JSON Schema 에서 의미가 크고 OPENAPI/ASYNCAPI 는 검사 깊이가 제한적이다. 그래도 전역으로 둔다. 스키마가 들어오는 순간부터 게이트가 서고, 필요하면 아티팩트별 규칙으로 덮을 수 있다.

#### 나머지 도구 — 결론

| 도구 | 결론 | 이유 |
|---|---|---|
| **Spectral** | 채택 (CI) | 유일하게 스타일·거버넌스를 검사한다. Registry 의 VALIDITY 규칙은 구문 검증까지다 |
| **Microcks** | 채택 (6단계) | 모킹 + 계약 테스트. 대체재 없음. **Keycloak·MongoDB 를 이미 갖고 있어** 보통 4~5 컴포넌트가 2개로 준다 |
| Swagger UI | 조건부 | 실행 가능한 문서. Microcks 를 넣으면 상당 부분 흡수된다 |
| AsyncAPI CLI | 보류 | AsyncAPI 문서를 실제로 쓰기 시작한 뒤. 린팅은 Spectral 이 커버 |
| **Swagger Editor** | **제외** | Registry 가 편집기를 갖게 되었다. 게다가 저장 위치가 브라우저 로컬이라 계약의 원천이 못 된다 |
| OpenAPI Generator | 이 레포 아님 | 앱 레포 CI 소관. Apitomy Codegen 이 같은 자리지만 openapi-generator 가 훨씬 성숙하다 |
| Swagger Parser | 배포 대상 아님 | 라이브러리다. Registry 의 VALIDITY 규칙이 이미 파싱하고, 그 자리는 Apitomy Data Models 다 |

#### 계약 우선으로 확정했다 (ADR-067)

`contracts/` 의 파일이 원천이고 구현이 거기에 맞춘다.

**정정** — 위에서 "`admin`·`cmmn-api` 가 Quarkus 이므로 코드 우선이 마찰이 적다"고 적었는데
틀렸다. 그때 본 `QUARKUS_*` 는 Apicurio 자신의 환경변수였다.

| | 실제 |
|---|---|
| `cmmn-api` | **Spring Boot**(`SPRING_*`, `/actuator/health`). OpenAPI 엔드포인트 없음 |
| `admin` | **프론트엔드**(포트 3000, env 없음, `/` 프로브). REST 계약 주체가 아니다 |

두 앱 모두 OpenAPI 문서를 내놓지 않으므로 **코드 우선을 택했어도 추출할 것이 없었다.**

**필수 귀결 — `auto.register.schemas` 를 껐다**

`cmmn-api` 는 이미 ccompat 을 가리키고 있었는데(`.../apis/ccompat/v7`) 레지스트리는 비어
있었다. Confluent serdes 의 기본값 `auto.register.schemas=true` 를 그대로 두면 **앱이 처음
메시지를 보낼 때 스키마를 스스로 등록한다** — 그것이 코드 우선이다.

```
SPRING_KAFKA_PROPERTIES_AUTO_REGISTER_SCHEMAS = false
SPRING_KAFKA_PROPERTIES_USE_LATEST_VERSION    = true
```

이제 앱은 등록된 최신 스키마를 찾아 쓰고 없으면 실패한다. 계약이 먼저 있어야 한다는
뜻이고 그것이 의도다.

**기구 — 이중 게이트**

```
contracts/ 수정 ─▶ CI validate : Spectral      (스타일·거버넌스)
                 ─▶ CI deploy   : Apicurio 게시 (VALIDITY·COMPATIBILITY 가 여기서 다시 막는다)
                 ─▶ 앱은 레지스트리에서 읽어 쓴다 (auto-register 꺼짐)
```

**Spectral 실증**

```
규약 준수 계약   0 errors           exit 0
규약 위반 계약   5 errors           oas3-api-servers · info-contact · info-description
                                    · oim-semver · operation-operationId
```

#### ★ YAML 겹따옴표 안의 정규식이 규칙을 조용히 죽인다

이번에 가장 오래 붙잡은 것이다. 커스텀 규칙이 **오류도 경고도 없이** 발화하지 않았다.

```yaml
match: "^\d+\.\d+\.\d+$"      # 조용히 죽는다
match: '^[0-9]+\.[0-9]+\.[0-9]+$'   # 정상 발화
```

YAML **겹따옴표** 스칼라에서 `\d` 는 유효한 이스케이프가 아니다. 파서가 삼키고, 남은
정규식으로는 규칙이 성립하지 않는데 **spectral 은 아무 말도 하지 않는다.**
`Found 113 rules (94 enabled)` 라고 표시되므로 규칙이 살아 있는 줄 알게 된다.

> **일반화** — 설정 파일에 정규식을 넣을 때는 **홑따옴표 + 문자클래스**를 쓸 것.
> 백슬래시 이스케이프를 YAML·셸·JSON 여러 층에 통과시키지 말 것.

진단 과정에서 한 번 더 헛디뎠다. 판정을 `grep -q "error"` 로 했는데 spectral 이 정상일 때
출력하는 `"No results with a severity of 'error' found!"` 에도 `error` 가 들어 있어
**네 건이 전부 거짓 양성**이었다. 규칙 이름으로 다시 판정하고 나서야 진상이 드러났다.

> **일반화 둘** — 검증 스크립트의 판정 문자열이 "성공 메시지"에도 들어 있지 않은지 볼 것.

#### ★ 선행 조건 — 지금 스펙이 0개다

```
등록된 아티팩트  0개
레포의 OpenAPI/AsyncAPI/Avro 파일  0개
```

그리고 앱 소스(`admin`·`cmmn-api`)가 이 레포에 없다(이미지만 참조하고 CI 가 부르는
`v1/*/Dockerfile` 은 부재 — G9). **스펙을 소비하는 도구는 전부 지금 먹일 것이 없다.**

Spectral·Microcks 를 넣기 전에 정할 것은 하나다.

> ~~계약 우선인가, 코드 우선인가?~~ → **계약 우선으로 확정**(ADR-067, 위 절 참조).

남은 것은 **초기 계약을 손으로 작성하는 일**이다. 앱 소스가 이 레포에 없고(G9)
두 앱 모두 OpenAPI 문서를 내놓지 않으므로 추출할 원본이 없다.

레지스트리 전역 규칙은 **이미 세웠다**(위 "전역 규칙을 세웠다" 참조). 스펙이 들어오는
순간부터 게이트가 선다.

### 8-14. 5단계 1/3 — ZooKeeper + HDFS (2026-09-02)

```
zookeeper-0        1/1 Running   3.9.5, srvr 응답
hadoop-namenode-0  1/1 Running   :8020 RPC · :9870 UI
hadoop-datanode-0  1/1 Running   NN 에 등록 완료
```

#### ★★ 먼저 — 클러스터가 조용히 죽고 있었다

5단계 착수를 위해 `.wslconfig` 를 고치고 `wsl --shutdown` 을 한 뒤, 부팅 이력에서 **의도하지 않은 재부팅**을 발견했다.

```
-2  09-01 22:53 → 09-02 15:12   (의도한 wsl --shutdown)
-1  15:12:41    → 15:21:58      ← 9분 만에 systemd poweroff
 0  15:26:59    → ...            ← 그리고 또
```

**WSL2 는 VM 에 붙은 프로세스가 없으면 VM 을 내린다.** systemd 로 k3s 가 돌고 있어도 마찬가지다. 매니페스트를 Windows 쪽에서 편집하는 동안 WSL 을 건드리지 않으면 VM 이 clean poweroff 되고, 다음 `wsl` 명령에 새로 부팅되면서 **40개 파드가 전부 재시작**한다.

증상이 원인을 가린다.

- 노드에는 아무 압박도 남지 않는다 — `MemoryPressure=False`, Windows 여유 45 GB
- 재시작 횟수만 조용히 쌓인다 — hive-metastore **35회**, cilium 10회, kyverno 7회
- Kyverno 웹훅 엔드포인트가 사라져 파드 생성이 `no endpoints available for service "kyverno-svc"` 로 거부되기도 한다
- 실메모리 사용이 4.8 GiB 로 이상하게 낮게 보인다(전부 막 기동 중이라)

**메모리 상향 때문이 아니다.** 56GB 를 줘도 Windows 는 45 GB 여유였다.

조치 두 가지.

1. `.wslconfig` 의 `[experimental] vmIdleTimeout=86400000` — **다만 WSL 2.7.12 에서는 경고와 함께 무시된다.** 넣어 두되 이것만 믿으면 안 된다
2. `local/keep-alive.ps1` — `wsl -d Ubuntu -- sleep infinity` 를 숨김 프로세스로 띄운다. **이쪽이 확실한 방법이다.** 로그온 시 자동 실행은 작업 스케줄러로 등록한다

> 이 프로젝트를 로컬에서 다룰 때는 **작업 시작 전에 keep-alive 를 먼저 띄울 것.**
> 그러지 않으면 원인 모를 재시작에 시간을 쓰게 된다.

#### 자원 — 48GB → 56GB, 20 → 24코어

```
            상향 전            상향 후
allocatable CPU 19.5   메모리 45 GiB   →   CPU 23.5   메모리 52.9 GiB
limits      메모리 94%                 →   80%
requests    CPU 73%                    →   60%
```

#### v1 대비 — HA 를 걷어냈다

v1 은 NameNode 2 + JournalNode 5 + ZKFC + RBF 라우터로 **Hadoop 만 9파드**였다. 단일 노드에서는 그 전부가 같은 커널 위에 있어 가용성이 늘지 않는다.

| | v1 | v2 로컬 |
|---|---|---|
| NameNode | 2 (HA) | **1** |
| JournalNode | 5 | **0** |
| ZKFC · RBF 라우터 | 있음 | **없음** |
| `dfs.replication` | 3 | **1** (복제본을 늘려도 같은 디스크다) |
| 인증 | — | `simple`. **Kerberos 미채택** |
| 그룹 매핑 | ds389 LDAP | **없음** |

- **Kerberos** — Hadoop 네이티브 CLI 접근 요구가 없으면 KDC·keytab 배포·주체 관리가 전부 순비용이다. 채택하려면 별도 결정이 필요하다
- **LDAP 그룹 매핑** — v1 은 `ou=users` 를 가리켰는데 우리 트리는 `ou=people` 이다. 인증이 `simple` 인 이상 그룹만 LDAP 에서 끌어와 얻는 것이 없다
- **ZooKeeper 는 HBase 전용**이다. Kafka 는 KRaft 라 쓰지 않고(v1→v2 전환의 핵심 중 하나였다) Hadoop 도 비-HA 라 ZKFC 가 없다

#### 실증

```
dfsadmin -report   Live datanodes (1) · Capacity 1006.85 GB · Remaining 87.03%
쓰기               hdfs dfs -put → /oim/smoke/smoke.txt (46 B)
읽기               oneinchmarket hdfs smoke 2026-09-02T06:54:54Z
fsck               Status: HEALTHY · 1 block · Under-replicated 0
ZooKeeper          srvr 응답, 3.9.5
```

#### 걸린 것

**1. DataNode 가 3초 만에 죽었다 — PVC 마운트 지점의 소유권**

```
NativeIO$POSIX.chmod → RawLocalFileSystem.setPermission
  → DiskChecker.mkdirsWithExistsAndPermissionCheck
DiskErrorException: Too many failed volumes -
  current valid volumes: 0, volumes configured: 1, volumes failed: 1
```

DataNode 는 데이터 디렉터리에 `dfs.datanode.data.dir.perm`(기본 700)으로 `chmod` 를 건다. PVC 를 **그 경로에 직접** 걸면 마운트 루트가 root 소유라 uid 1000 이 소유자가 아니어서 EPERM 이다.

→ 한 단계 위(`/hadoop/dfs`)에 걸어 DataNode 가 **자기 소유의** `data/` 를 만들게 한다. `fsGroup` 이 마운트 루트를 그룹 쓰기 가능으로 만들어 하위 디렉터리 생성은 되고, 만든 디렉터리의 소유자는 uid 1000 이라 `chmod` 가 통과한다.

> **일반화** — 컨테이너가 마운트 지점 자체에 `chmod`·`chown` 을 거는 워크로드는
> PVC 를 한 단계 위에 걸 것. Wazuh 의 `os.chown`(§8-12)과 같은 계열이다.

**2. DataNode 등록에는 호스트명이 필요하다**

`dfs.datanode.use.datanode.hostname=true` 를 넣었다. StatefulSet 파드는 재시작하면 IP 가 바뀌므로 IP 로 등록하면 NameNode 가 죽은 DataNode 를 계속 들고 있게 된다. 그리고 DataNode headless Service 에 `publishNotReadyAddresses: true` 가 필요하다 — DataNode 는 NameNode 에 등록되어야 Ready 인데 등록하려면 자기 호스트명이 풀려야 해서, 기본값이면 서로를 기다리는 교착이 된다.

**3. NetworkPolicy 는 양방향이어야 한다**

등록·하트비트는 DataNode → NameNode 지만 **블록 명령은 NameNode → DataNode** 다. 한쪽만 열면 등록은 되는데 블록이 움직이지 않는다.

#### 남은 것

| | 상태 |
|---|---|
| HBase 2종 | **로컬 빌드 필요.** `apache/hbase` 저장소가 Docker Hub 에 없다(404) → §8-15 에서 `docker/hbase/Dockerfile` 로 해소 |
| Hive Server | **TODO-33 이 여기서 물린다** — Hive warehouse 를 HDFS 로 되돌릴지, S3A 를 유지할지 → §8-16 에서 "양자택일이 아니다"로 해소 |


### 8-15. 5단계 2/3 — HBase (2026-09-02)

#### 이미지 — `docker/hbase/Dockerfile`

`apache/hbase` 는 Docker Hub 에 없다(404). `v1/hbase/Dockerfile` 이 있었으나 그대로 쓸 수 없어 새로 썼다.

| v1 의 문제 | 고친 것 |
|---|---|
| `FROM openjdk:8` — HBase 2.6 은 JDK 8 을 지원 종료했다 | `eclipse-temurin:17-jre-noble` |
| 체크섬 검증 없음 | `HBASE_SHA512` ARG + `sha512sum -c -` |
| root 로 실행 | `groupadd -g 1001 hbase` + `USER hbase` |
| `archive.apache.org` 고정 | `dlcdn.apache.org` (미러) |

`local/build-images.sh` 가 이제 4종을 빌드한다 — `spark-iceberg`, `livy`, `ranger-usersync`, `hbase`. 전부 `--network host` 다(§8-14).

#### 결과

```
hbase-master-0        1/1 Running   registered as active master
hbase-regionserver-0  1/1 Running   reportForDuty -> Serving as ...
create/put/get        value=hbase  (HDFS 위)
HDFS                  /hbase/data/default/oim_smoke/{.tabledesc,<region>/cf}
```

#### 걸린 것 — NetworkPolicy 는 "소스로 등록"만으로는 부족하다

RegionServer 가 init 에서 멈췄다. `hbase-master`·`hbase-regionserver` 는 다른 정책의 **from 목록에는** 들어 있었지만 **자기 자신을 podSelector 로 하는 ingress 정책이 없었다**. default-deny-ingress 아래에서는 인바운드 정책이 없으면 아무도 들어오지 못한다.

> **점검 항목** — 워크로드를 추가할 때 "이 워크로드가 접속할 대상"만 열고 끝내기 쉽다.
> `podSelector` 가 그 워크로드인 정책이 실제로 존재하는지 따로 확인할 것.

### 8-16. 5단계 3/3 — HiveServer2 · "Hive 는 Hadoop 과 같이 쓸 수 있나"

#### 결론 — 쓸 수 있다. Hadoop 전용 Hive 를 따로 띄울 이유가 없다

`apache/hive:4.0.1` 한 이미지 안에 두 파일시스템 구현체가 함께 들어 있다.

```
/opt/hadoop/share/hadoop/hdfs/hadoop-hdfs-client-3.3.6.jar   ← hdfs://
/opt/hadoop/share/hadoop/tools/lib/hadoop-aws-3.3.6.jar      ← s3a://
/opt/hadoop/share/hadoop/tools/lib/aws-java-sdk-bundle-1.12.367.jar
```

Hadoop 의 `FileSystem` 은 URI 스킴별로 구현체를 고르므로, 한 HiveServer2 가 데이터베이스·테이블마다 `LOCATION 'hdfs://...'` 와 `LOCATION 's3a://...'` 를 섞어 쓸 수 있다. **인스턴스를 나눠야 하는 제약은 없다.**

그래서 다음 배치로 끝냈다.

| | |
|---|---|
| `fs.defaultFS` | `hdfs://hadoop-namenode:8020` — scratchdir·중간 결과가 HDFS 로 간다 |
| `hive.metastore.warehouse.dir` | `s3a://warehouse/tables` — 기본 웨어하우스는 그대로 오브젝트 스토리지 |
| 테이블별 | `LOCATION` 으로 스킴을 골라 쓴다 |

TODO-33("warehouse 를 HDFS 로 되돌릴지")은 **양자택일이 아니었다**. 기본값만 정하면 되고, 나머지는 테이블 단위로 지정한다.

#### 실행 엔진 — YARN 을 띄우지 않는다

Hive 4 의 기본 엔진은 Tez 이고 Tez 는 보통 YARN 을 요구한다. ResourceManager + NodeManager 2파드를 더 올리는 대신 **Tez 로컬 모드**(`tez.local.mode=true`)를 썼다 — DAG 를 HiveServer2 JVM 안에서 실행한다. 이미지에 Tez 0.10.4 가 이미 들어 있다.

- 적합: 스모크·DDL·소규모 질의, 카탈로그 호환성 확인
- 부적합: 실제 분산 배치 — 그때는 YARN 2파드를 올리고 `tez.local.mode` 를 끈다 (TODO-49)

대량 처리 경로는 이미 Spark(K8s 네이티브)와 Trino 가 맡고 있어 로컬에서 YARN 을 세울 이유가 약하다.

#### 걸린 것 6건 — 전부 "조용히 틀리는" 부류였다

**1. entrypoint 가 매번 schematool 을 돌린다**

```bash
SKIP_SCHEMA_INIT="${IS_RESUME:-false}"
: ${DB_DRIVER:=derby}
...
$HIVE_HOME/bin/schematool -dbType $DB_DRIVER -initOrUpgradeSchema || exit 1
```

`IS_RESUME` 를 주지 않으면 HiveServer2 도 **derby 로** 스키마 초기화를 시도하고 실패하면 `exit 1` 한다. 스키마 소유자는 hive-metastore 이므로 `IS_RESUME=true` 로 건너뛴다.

**2. 알림 이벤트 API 인가는 메타스토어 쪽 설정이다**

HiveServer2 가 기동하지 않고 60초마다 재시도했다. 파드 stdout 에는 `Hive Session ID = ...` 만 반복될 뿐 이유가 없었다 — 실제 로그는 `/tmp/hive/hive.log` 에 있다.

```
WARN  server.HiveServer2: Error starting HiveServer2 on attempt 1, will retry in 60000ms
java.lang.RuntimeException: Error initializing notification event poll
Caused by: TApplicationException: Internal error processing get_current_notificationEventId
```

메타스토어 로그에 원인과 처방이 함께 있었다.

```
ERROR metastore.HMSHandler: Not authorized to make the get_notification_events_count call.
      You can try to disable metastore.metastore.event.db.notification.api.auth
```

`metastore.event.db.notification.api.auth=false` 를 **hive-metastore 의** hive-site.xml 에 넣어야 한다. HiveServer2 쪽에 같은 이름을 넣어도 서버 판정은 바뀌지 않는다.

**3. `hadoop-aws` 는 기본 클래스패스에 없다**

```
ClassNotFoundException: Class org.apache.hadoop.fs.s3a.S3AFileSystem not found
```

`share/hadoop/tools/lib` 는 Hadoop 기본 클래스패스에서 빠져 있다. hive-site.xml 에 `fs.s3a.impl` 을 적어 두어도 **클래스가 없으면 의미가 없다.** `HADOOP_CLASSPATH` 에 두 jar 를 명시했다(와일드카드로 tools/lib 전체를 넣으면 쓰지 않는 azure·gcs 커넥터와 중복 SDK 가 딸려 온다).

> 이 문제는 **메타스토어에도 원래 있었다.** `hive.metastore.warehouse.dir=s3a://...` 로
> 설정돼 있었지만 Hive 가 그 경로를 실제로 해석할 일이 없어 드러나지 않았다.
> Trino·Spark 는 각자의 S3 클라이언트를 쓰므로 레이크하우스는 정상으로 보였다.

**4. `${env:...}` 치환은 메타스토어에서 동작하지 않는다**

```
AccessDeniedException s3a://warehouse/... : AmazonS3Exception: Forbidden (403)
```

`fs.s3a.access.key` 에 `${env:MINIO_ACCESS_KEY}` 를 쓰던 방식은 HiveServer2 에서는 `HiveConf.get()` 이 치환해 주지만 독립 메타스토어에서는 치환되지 않아 **리터럴 문자열이 그대로 액세스 키가 된다.** MinIO 는 이를 403 으로 돌려준다 — 설정 오류처럼 보이지 않고 권한 오류처럼 보인다.

→ 값이 아니라 **공급자**로 넘긴다. `fs.s3a.aws.credentials.provider=com.amazonaws.auth.EnvironmentVariableCredentialsProvider` + `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. AWS SDK 가 환경변수를 직접 읽으므로 Hadoop 의 변수 치환 규칙에 의존하지 않는다.

#### 덤으로 드러난 것 — 메타스토어 재시작 39회의 원인

`overlays/local/patches/qos-guaranteed.yaml` 이 hive-metastore 를 **512Mi** 로 고정하고 있었는데 entrypoint 는 `HADOOP_CLIENT_OPTS` 에 `-Xmx1G` 를 박아 넣는다. 힙만으로 한계를 넘으니 JVM 이 아니라 커널이 죽인다. 힙을 `SERVICE_OPTS` 의 `-Xmx768m` 로 눌러 잡고(뒤에 온 `-Xmx` 가 이긴다) limit 을 1280Mi 로 올렸다.

> **일반화** — 컨테이너 limit 을 줄일 때 **그 안에서 도는 JVM 의 `-Xmx` 를 같이 보지 않으면**
> 워크로드는 "가끔 죽는" 상태로 남는다. Guaranteed QoS 는 스왑도 못 쓰므로 여유가 없다.

또 hive-metastore StatefulSet 이 같은 ConfigMap 을 `envFrom` 으로도 참조하고 있었다. 이 ConfigMap 의 유일한 키가 `hive-site.xml` 이라 **`hive-site.xml` 이라는 이름의 환경변수에 XML 전문이 들어가 있었다.** 제거했다.

**5. `doAs=false` 로도 프록시는 남는다**

```
TezTask return code 1: User: hive is not allowed to impersonate hive
```

`hive.server2.enable.doAs=false` 는 **클라이언트 유저를 위임하지 않는다**는 뜻이지 UGI 프록시를 아예 쓰지 않는다는 뜻이 아니다. Tez 태스크는 `UGI.doAs` 로 감싸여 실행되고, `ProxyUsers` 검사는 자기가 자기를 위임하는 경우도 화이트리스트를 요구한다.

```xml
<property><name>hadoop.proxyuser.hive.hosts</name><value>*</value></property>
<property><name>hadoop.proxyuser.hive.groups</name><value>*</value></property>
```

**두 곳 모두** 필요하다 — NameNode 의 `core-site.xml`(원격 검사)과 HiveServer2 의 `hive-site.xml`(Tez 로컬 모드는 같은 JVM 안에서 검사한다).

**6. Tez 는 `/user/<유저>` 에 jar 를 올린다**

```
Permission denied: user=hive, access=WRITE, inode="/user":hadoop:supergroup:drwxr-xr-x
```

`hive.user.install.directory`(기본 `/user`) 아래에 세션마다 `hive-exec` jar 를 업로드한다. `/user/hive` 가 미리 있으면 `/user` 에 쓸 필요가 없다. `hdfs-bootstrap` 에 `mk /user/hive hive 755` 를 추가하고 검증 목록에도 넣었다.

#### 검증 — 한 인스턴스가 두 파일시스템을 JOIN 한다

`apache/hive:4.0.1` beeline 파드에서 HiveServer2 에 접속해 실행했다.

```sql
-- HDFS 쪽
CREATE DATABASE oim_hdfs
  LOCATION        'hdfs://hadoop-namenode:8020/warehouse/oim_hdfs.db'
  MANAGEDLOCATION 'hdfs://hadoop-namenode:8020/warehouse/oim_hdfs_managed.db';
CREATE EXTERNAL TABLE oim_hdfs.t (id INT, v STRING) STORED AS TEXTFILE;
INSERT INTO oim_hdfs.t VALUES (1, 'from-hdfs');

-- S3A(MinIO) 쪽
CREATE DATABASE oim_s3
  LOCATION        's3a://warehouse/tables/oim_s3.db'
  MANAGEDLOCATION 's3a://warehouse/tables/oim_s3_managed.db';
CREATE EXTERNAL TABLE oim_s3.t (id INT, v STRING) STORED AS TEXTFILE;
INSERT INTO oim_s3.t VALUES (1, 'from-s3a');

-- 한 질의에서 두 스킴을 JOIN
SELECT h.v, s.v FROM oim_hdfs.t h JOIN oim_s3.t s ON h.id = s.id;
```

```
from-hdfs	from-s3a

DESCRIBE FORMATTED oim_hdfs.t → Location: hdfs://hadoop-namenode:8020/warehouse/oim_hdfs.db/t
DESCRIBE FORMATTED oim_s3.t   → Location: s3a://warehouse/tables/oim_s3.db/t
```

`INSERT` 는 Tez DAG 를 돌리므로 로컬 모드 실행 경로도 함께 검증된다.

> `MANAGEDLOCATION` 을 명시한 이유 — `CREATE DATABASE ... LOCATION` 은 **external**
> 위치만 정한다. 관리 위치는 `hive.metastore.warehouse.dir`(=S3A) 를 따르므로,
> 명시하지 않으면 HDFS 데이터베이스인데 관리 경로만 S3A 로 남는다.

#### 최종 상태

| | |
|---|---|
| `hive-metastore-0` | 1/1 · 1280Mi Guaranteed · 힙 768m |
| `hive-server-0` | 1/1 · thrift 10000 · WebUI 10002 · 힙 1536m |
| HDFS | `/hbase`(hbase) `/warehouse`(hive) `/user/hive`(hive) `/tmp`(1777) |
| NetworkPolicy | `allow-hive-server-access` — data-lakehouse·application 계층에서 10000/10002 |

`local/NEXT-SESSION.md` 의 재현 절차에 스모크 SQL 을 그대로 옮겨 두었다. 레포에는 Job 을 커밋하지 않는다 — 테스트용 데이터베이스를 sync 마다 만들게 되기 때문이다.

### 8-17. 로컬에서 고친 것을 dev/prod 로 (2026-09-02)

§8-16 의 수정 대부분은 `kubernetes/base/` 에 있어 dev·prod 가 **자동으로 상속한다.**
문제는 그중 일부가 **로컬 전용 값**인데 base 에 들어갔다는 점이었다. 분리했다.

#### 1. 힙을 별도 키로 분리 — 오버레이가 한 줄만 덮게

`hive-metastore` 의 `SERVICE_OPTS` 는 JDBC 접속 문자열까지 담고 있다. 여기에 `-Xmx768m`
(로컬 limit 1280Mi 기준)을 넣어 버리면 dev/prod 도 768m 가 되고, 되돌리려면 오버레이가
**JDBC 문자열 전체를 복제**해야 한다 — ADR-011 이 경고한 드리프트다.

```yaml
# base — limit 2Gi 기준
- name: HIVE_HEAP
  value: "-Xmx1536m"
- name: SERVICE_OPTS
  value: >-
    -Djavax.jdo.option.ConnectionURL=jdbc:postgresql://…
    $(HIVE_HEAP)          # ← k8s 가 파드 생성 시 펼친다
```

```yaml
# overlays/local/patches/qos-guaranteed.yaml — limit 1280Mi 기준
env:
  - name: HIVE_HEAP
    value: "-Xmx768m"
```

`env` 는 `name` 을 키로 하는 병합 리스트라 전략적 병합 패치가 이 항목만 덮는다.

```
local  -Xmx768m     dev  -Xmx1536m     prod  -Xmx1536m
```

> **"뒤에 온 `-Xmx` 가 이긴다"는 추정이 아니다.** 같은 이미지의 JVM 으로 확인했다.
>
> ```
> java -Xmx1G -Xmx768m -XX:+PrintFlagsFinal -version | grep MaxHeapSize
>   → MaxHeapSize := 805306368        (= 768 MiB)
> java -Xmx1G          -XX:+PrintFlagsFinal -version | grep MaxHeapSize
>   → MaxHeapSize := 1073741824       (= 1 GiB)
> ```
>
> entrypoint 가 `HADOOP_CLIENT_OPTS="$HADOOP_CLIENT_OPTS -Xmx1G $SERVICE_OPTS"` 로
> 조립하므로, 이미지가 박아 넣은 기본 힙을 **덮어쓰는 유일한 수단**이 이것이다.

#### 2. `proxyuser` 를 `groups=*` → `users=hive` 로

기능에 필요한 것은 "hive 가 hive 로 실행"뿐인데 `groups=*` 는 **임의 사용자로의 위임**까지
연다. Kerberos 를 채택하지 않아(`hadoop.security.authentication=simple`) 위임 자체를 검증할
수단이 없으므로 범위를 최소로 좁혔다. 좁힌 뒤에도 스모크는 통과한다.

`hosts=*` 는 남았다 — 파드 IP 가 고정이 아니라 좁힐 대상이 마땅치 않다. **SEC-211** 로
기록했고 dev/prod 에서는 Knox·Ranger 경유로 대체할지 결정한다(TODO-48).

#### 3. prod 에서 따로 할 일은 없었다

| 점검 | 결과 |
|---|---|
| 이미지 핀닝(Kyverno `disallow-latest` Enforce) | `apache/hive: 4.0.1` 이 이미 `images:` 에 있다 |
| PSS `restricted` | hive-server 는 uid 1000 · `drop:["ALL"]` · `RuntimeDefault` — 적격 |
| Kyverno require-probes·resources·labels | 전부 충족 |
| PDB | **추가하지 않는다.** prod PDB 는 레플리카 2 이상인 8종에만 있다. 레플리카 1 에 `minAvailable: 1` 을 걸면 노드를 비울 수 없다 (hive-metastore 도 같은 이유로 없다) |

#### 문서에서 바로잡은 사실 3건

배포 결과가 문서의 **예측과 달랐던** 것들이다.

- **SECURITY.md `[목표]` 예외 — "Hadoop/HBase/Knox(root 실행)"은 빗나갔다.**
  셋 다 비특권으로 돈다: hadoop uid 1000 · hbase uid 1001 · knox uid 8000, 전부
  `drop:["ALL"]`. v1 매니페스트가 root 로 돌았던 것이지 이미지의 제약이 아니었다
- **NetworkPolicy 공백은 6건이 아니라 3건**(Keycloak·Trino·GitLab). MinIO·Hive
  Metastore·Apicurio 는 이후 배포 과정에서 해소됐는데 표가 따라오지 않았다
- **COMPONENTS.md 의 "Kerberos는 필요 없다 — HDFS가 아니라 S3를 쓰므로"** 는 근거가
  사라졌다. HBase 가 HDFS 를 요구해 HDFS 가 들어왔다. 결론(미채택)은 같지만 이유가 다르다

> `[목표]` 로 표시된 표는 **실배포로 확인하기 전까지 추정**이다. 세 건 모두 그 표에 있었다.

#### 남긴 것

- 스모크 SQL 은 **멱등이 아니다.** `CREATE ... IF NOT EXISTS` 뒤의 `INSERT` 는 매번 행을
  더한다(재실행 4회 후 JOIN 이 4행). 존재 확인용이라 그대로 두었다
- **dev/prod 에는 아직 적용하지 않았다.** base 를 상속하므로 다음 sync 때 HiveServer2 가
  함께 올라간다 — Tez 로컬 모드(TODO-49)와 `proxyuser`(TODO-48)를 그 전에 결정할 것

### 8-18. local / dev / prod 분리 (2026-09-02)

§8-17 은 "dev/prod 는 base 를 상속하므로 다음 sync 때 HiveServer2 가 함께 올라간다"를
**결정 대기 항목으로 남겼다.** 그 상태 자체가 결함이다 — 검증하지 않은 단일 노드 설정이
아무도 결정하지 않은 채로 dev/prod 에 도달한다.

#### base 에 들어간 로컬 전제 — hive-server 만의 문제가 아니었다

| 값 | base 값 | dev/prod 목표 |
|---|---|---|
| `dfs.replication` | `1` | 3 |
| NameNode HA | 없음(JournalNode·ZKFC 부재) | NN 2 + JN 3 |
| `hbase.master.wait.on.regionservers.mintostart` | `1` | RegionServer 수에 맞춤 |
| `tez.local.mode` | `true`(YARN 없음) | YARN 또는 다른 엔진 |
| `hadoop.proxyuser.hive.hosts` | `*` | 좁히거나 Knox·Ranger 경유 |

레플리카 `1` 은 문제가 아니다 — base 는 1 로 두고 오버레이가 올리는 것이 이 레포의 규약이다.
문제는 **ConfigMap 안의 XML 값**이다. 키 하나가 파일 전체를 담고 있어 오버레이가 일부만
덮을 수단이 없다. 덮으려면 XML 전문을 복제해야 하고 그 순간 드리프트다.

#### 결정 — 설정 분리 방식이 정해질 때까지 base 에 올리지 않는다

```
kubernetes/overlays/local/lakehouse-local/
  kustomization.yaml          승격 조건을 머리말에 적어 둔다
  workloads/                  sync-wave 3
    zookeeper/ hadoop/ hbase/ hive-server/
    serviceaccount.yaml       hive-server SA
    hdfs-bootstrap.yaml
  netpol/                     sync-wave 0
    netpol.yaml               대상 정책 7종
```

`workloads` 와 `netpol` 을 나눈 이유 — **wave 가 다르다.** kustomize 의
`commonAnnotations` 는 기존 값을 덮어쓰므로 한 kustomization 으로는 두 wave 를 만들 수 없다.
base 가 `data-lakehouse`(3)와 `network-policies`(0)를 따로 두는 것과 같은 구조다.

**base 에 남는 것** — MinIO·Trino·Hive Metastore·Spark·Livy. 오브젝트 스토리지만 쓰므로
환경 의존 값이 없다.

#### 검증 — 렌더 결과로 확인한다

```
                zookeeper  namenode  datanode  hbase-m  hbase-rs  hive-server  hdfs-bootstrap
local              2          2         1         2        2          2             1
dev                0          0         0         0        0          0             0
prod               0          0         0         0        0          0             0

dev 에 남은 로컬 전제 값:
  dfs.replication 0 · tez.local.mode 0 · hadoop.proxyuser 0 · mintostart 0 · hbase.rootdir 0
```

#### 곁가지 1 — 메타스토어의 `proxyuser` 는 애초에 필요 없었다

§8-16 에서 `hadoop.proxyuser.hive.*` 를 NameNode·HiveServer2·**메타스토어** 세 곳에 넣었다.
근거가 있었던 것은 앞의 둘뿐이고 메타스토어는 "혹시 몰라서"였다. 빼고 스모크를 다시 돌려
**필요 없음을 확인했다.** 덕분에 base 에서 로컬 전제가 완전히 사라졌다.

> 증상 없이 넣은 설정은 뺐을 때 아무 일도 일어나지 않는다. 그런 줄이 base 에 남으면
> "왜 있는지 모르지만 무서워서 못 지우는" 설정이 된다.

#### 곁가지 2 — XML 정합성은 파서로 확인한다

`sed` 로 XML 블록을 잘라내다 `</property>` 를 하나 남겼다. **kustomize 도 kubectl 도
통과한다** — ConfigMap 안의 값은 그저 문자열이기 때문이다. Hive 가 기동할 때 파싱에서
터진다.

렌더 결과의 모든 `*-site.xml` 을 실제 XML 파서에 넣어 검사했다.

```
local  core-site(6) hdfs-site(8) hbase-site(12) hive-metastore(11) hive-server(26)  실패 0
dev    hive-metastore(11)  실패 0
prod   hive-metastore(11)  실패 0
```

> **ConfigMap 안의 구조화 문서(XML·JSON·properties)는 `kustomize build` 가 검사하지
> 않는다.** kubeconform 도 마찬가지다 — 스키마상 그냥 문자열이다. 별도로 파싱할 것.

#### prod 의 이미지 핀 3종은 남겼다

`apache/hadoop`·`zookeeper`·`oneinch/hbase` 는 이제 prod 에서 대상이 없다. kustomize 는
대상 없는 `images:` 항목을 조용히 무시하므로 오류가 나지는 않지만, 그대로 두면 "prod 가
이것들을 배포한다"고 읽힌다. **미사용임을 주석으로 표시**하고 승격 시점을 위해 값은 유지했다.

### 8-19. zram 이 처음으로 동작했다 (2026-09-03)

§8-6·§8-7 은 두 번 모두 *"zram 은 사실상 미사용(mem_used 2~4 MiB)"* 으로 끝났다. 5단계까지
올린 지금 처음으로 실제 스왑이 발생했다.

```
/dev/zram0  lzo-rle  DISKSIZE 32G  DATA 234.4M  COMPR 70.7M  TOTAL 73.5M
used swap 252 MB / 41.9 GB
```

**압축률 234.4 / 70.7 = 3.32 배.** §7 의 커널 빌드 검토는 lzo-rle 를 2.2 로 잡고
`ZRAM_BACKEND_ZSTD` 로 3.2 까지 올리는 것을 근거로 삼았는데, **실측 lzo-rle 가 이미 그
가정치를 넘는다.**

> 다만 표본이 234 MiB 로 작다. 지금 스왑된 것은 기동 후 손대지 않은 콜드 페이지라
> 압축이 잘 되는 쪽에 치우쳐 있을 수 있다. **7단계(zram 실측 지점)에서 수 GiB 규모로
> 다시 볼 것.** 지금 수치로 커널 빌드 필요 없음을 결론짓기에는 이르다.

`vmstat` 의 스왑인은 여전히 관측되지 않는다 — 스왑 아웃만 있었고 되읽지 않았다는 뜻이라
스래싱은 없다.

#### 6단계 착수 시점의 여유

```
requests  33.2 / 54 GiB (61%)   ← 스케줄링을 실제로 막는 값. 여유 약 21 GiB
limits    53.3 / 54 GiB (98%)   ← 오버커밋 허용치라 게이트가 아니다
실사용    27 GiB used / 27 GiB available
```

상위 소비: GitLab 3,665 Mi · Elasticsearch 1,849 Mi · Logstash 1,781 Mi ·
Ranger admin 1,162 Mi · cmmn-api 1,017 Mi

### 8-20. 6단계 — Kafka Bridge · Jenkins · GlitchTip (2026-09-03)

세 구성요소 모두 기동하고 기능까지 확인했다. Apicurio Studio 4종은 폐기라 제외했다(§8-13).

```
kafka-bridge-*      1/1  HTTP produce/consume 왕복 확인
jenkins-0           1/1  /login 200 (devops 계층에서)
glitchtip-web-*     1/1  /_health/ 200
glitchtip-worker-*  1/1  manage.py runworker --scheduler
glitchtip-migrate   Complete — 미적용 마이그레이션 0 건
```

#### 이미지 계약을 먼저 실측했다

이 세션에서 entrypoint 추측으로 여러 번 물렸으므로(Vault `-config`, Hive `IS_RESUME`)
매니페스트를 쓰기 전에 이미지를 직접 열었다. **네 건이 추측과 달랐다.**

| | 확인된 사실 |
|---|---|
| kafka-bridge | uid **1001**/gid 0. entrypoint 없이 Cmd 만 있어 `command`·`args` 를 **둘 다** 써야 한다. 설정은 `--config-file=<경로>` |
| kafka-bridge | 헬스는 `http.management.port`(**8081**)다. **8080 의 `/healthy`·`/ready` 는 501 을 준다** — 프로브를 8080 에 걸면 영원히 실패한다 |
| glitchtip | uid **5000**(app), 포트 8000. Redis 변수명이 `REDIS_URL` 이 아니라 **`VALKEY_URL`** 이다(6.x 개명) |
| glitchtip | **`bin/start.sh` 는 `$DYNO`(Heroku)일 때만 migrate 를 돌린다.** 쿠버네티스에서는 절대 실행되지 않는다 |

마지막 항목이 특히 조용하다 — 마이그레이션 없이 뜨면 파드는 Running 인데 요청마다
`relation does not exist` 가 난다. `glitchtip-migrate` Job(wave 6)을 따로 두고 끝에
`showmigrations --plan` 으로 미적용 건수를 세어 0 이 아니면 `exit 1` 하게 했다.

메트릭도 실측했다 — `bridge.metrics=strimziMetricsReporter` 는 별도 설정 파일이 필요
없고(`jmxPrometheusExporter` 는 요구한다) 활성화하면 `:8081/metrics` 가 200 을 준다.
배포 직후 Prometheus 가 바로 스크레이프했다.

#### ★ 곁가지에서 나온 것 — prod 배포가 통째로 거부될 상태였다

Jenkins 파드 이벤트에 Kyverno 위반이 찍혔다.

```
policy disallow-root-user/validate-run-as-non-root fail:
  Containers must set securityContext.runAsNonRoot to true.
  rule failed at path /spec/containers/0/securityContext/runAsNonRoot/
```

내 매니페스트만의 문제가 아니었다. **prod 렌더를 전수 조사하니 컨테이너 53개 전부가
위반이고, 컨테이너 레벨에 `runAsNonRoot` 를 명시한 것은 0개였다.**

원인은 매니페스트가 아니라 **정책 쪽이다.**

```yaml
# 고치기 전 — containers[*] 만 본다
pattern:
  spec:
    containers:
      - securityContext:
          runAsNonRoot: true
```

이 레포의 규약은 `runAsNonRoot` 를 **파드 레벨에 한 번** 두는 것이고, Pod Security
Standards `restricted` 의 실제 판정도 "파드 레벨 **또는** 컨테이너 레벨"이다 —
컨테이너에서 정의하지 않으면 파드 값을 상속한다. 정책이 자기가 구현한다고 적어 둔
표준보다 엄격했다. `anyPattern` 으로 양쪽을 인정하게 고쳤다.

**local 은 Audit 이라 이벤트로만 쌓였고 아무도 보지 않았다. prod 는 Enforce 다** —
그대로 배포하면 53개 컨테이너가 admission 에서 거부된다. 첫 prod 배포에서야 드러났을
결함이고, 그때는 "매니페스트 53개를 고칠 것인가"로 오진하기 좋았다.

고친 뒤:

```
disallow-root-user   pass 147 · fail 16
local 네임스페이스의 남은 위반 = 의도된 예외 7건뿐
  falco · filebeat · otel-agent · lam · ds389 · gitlab · wazuh-manager
나머지는 kube-system·istio-system·tetragon·trivy-system (TODO-13·15 소관)
```

> **일반화** — 정책이 `Audit` 인 환경에서만 돌려 보면 "정책이 있다"는 것만 알 뿐
> **그 정책이 무엇을 거부할지는 모른다.** Enforce 환경에 올리기 전에 렌더 결과를
> 정책 기준으로 전수 검사할 것.

#### 그 외 결정

- **Jenkins 는 설치 마법사를 켠 채로 둔다.** `runSetupWizard=false` 는 흔히 쓰이지만
  관리자 계정·보안 영역을 함께 넣지 않으면 **인증 없는 Jenkins** 가 된다. 선언으로
  넣으려면 JCasC 플러그인이 필요한데 공식 이미지에 없고 런타임에 받으면 SEC-512
  계열이 된다 → **TODO-50**. 그때까지 초기 비밀번호로 1회 설정한다.
  ```
  kubectl -n local exec jenkins-0 -- cat /var/jenkins_home/secrets/initialAdminPassword
  ```
- **Jenkins 태그는 `:lts`.** base 의 기본은 `:latest` 지만 Jenkins 의 latest 는 주간
  릴리스다. "base 는 움직이는 태그, prod 는 핀" 이라는 정책 자체는 지켜진다
- **GlitchTip 은 2 파드다.** ADR-036 ⓓ 는 3~4 파드로 봤으나 6.x 의 워커가
  `--scheduler` 를 포함해 beat 파드가 필요 없다
- **PostgreSQL `max_locks_per_transaction` 256 → 512.** GlitchTip 은 이벤트 테이블을
  파티셔닝하고, 파티션을 하나로 좁히지 못하는 질의는 모든 파티션과 인덱스에 락을 건다.
  설치 문서가 자체 호스팅에 512 를 권장한다. 이 값은 소비자 중 가장 큰 요구를 따른다
- **ADR-037(ClickHouse)·ADR-038(전용 Kafka·Redis)은 불필요해졌다.** GlitchTip 은
  Django + PostgreSQL + Redis 만 쓴다. Redis 는 DB 인덱스 3 으로 기존 인스턴스를 공유한다
- **`devops-netpol.yaml` 신설.** GitLab 이 "NetworkPolicy 커버리지 공백 3건" 중
  하나였는데 devops 계층에 netpol 파일 자체가 없었다. Jenkins 를 넣으면서 함께 만들어
  공백이 2건(Keycloak·Trino)으로 줄었다

#### 스모크 — 접근 통제까지 함께 확인한다

```
1. 토픽 목록  ["keycloak-events","falco-alerts","dev.api.cmmn.menu",…]
2. produce    {"offsets":[{"partition":0,"offset":1}]}
3. 구독       HTTP 204
4. consume    [{"topic":"oim.bridge.smoke","key":"k1","value":{"src":"kafka-bridge",…}}]
5. Jenkins    application -> jenkins:8080 = 000   ← 차단이 정상이다
6. GlitchTip  application -> :8000/_health/ = 200
SMOKE OK
```

5번을 실패가 아니라 **기대값**으로 둔 것이 요점이다. 처음에는 이 호출이 응답 없이
멈춰 스모크가 2분간 매달렸는데, 원인은 결함이 아니라 `allow-jenkins-access` 가
`devops`·`nginx`·`oauth2-proxy` 만 열기 때문이었다. 브리지에 자체 인증이 없는 것과
같은 이유로(SEC-206) **NetworkPolicy 가 사실상 유일한 접근 통제**라, 열려 있는지가
아니라 **닫혀 있는지**를 확인해야 한다.

### 8-21. Jenkins 마무리 — 설치 마법사 대신 JCasC (2026-09-03)

§8-20 은 Jenkins 를 **설치 마법사가 뜬 채로** 남겨 두고 TODO-50 으로 미뤘다. 이제 닫는다.

#### 왜 커스텀 이미지가 필요했나

`jenkins.install.runSetupWizard=false` 는 흔히 쓰이지만, **그것만 주면 보안 영역이 없는
= 인증 없는 Jenkins** 가 된다. 도달 가능한 누구나 스크립트 콘솔로 임의 코드를 실행한다.
관리자 계정을 선언으로 넣으려면 `configuration-as-code` 플러그인이 필요한데 **공식
이미지에는 플러그인이 하나도 없다.** 런타임에 받으면 SEC-512(런타임 외부 의존)다.

→ `docker/jenkins/` 로컬 빌드 이미지에 빌드 시점으로 굽는다. 요청 4종
(`configuration-as-code`·`git`·`workflow-aggregator`·`credentials-binding`)에 의존까지
합쳐 **59개**가 들어간다.

플러그인 버전은 고정하지 않는다 — `jenkins-plugin-cli` 가 **코어와 호환되는** 버전을
고르므로, 여기서 버전을 박으면 베이스 `:lts` 가 올라갈 때 조합이 깨진다. 재현성은
이미지 태그로 잡는다.

#### 검증 — 로그인이 실제로 되는지까지

```
익명   /api/json                 -> 403   (allowAnonymousRead: false)
admin  /api/json                 -> 200   systemMessage 가 JCasC 값으로 뜬다
       ?tree=numExecutors,mode   -> {"mode":"NORMAL","numExecutors":1}  마법사 없음
       /manage/configuration-as-code/ -> 200
활성 플러그인 59 — 요청 4종 전부 있음
```

비밀번호는 `jenkins-secret` 에서 **환경변수**로 주입되고 JCasC 가 `${JENKINS_ADMIN_PASSWORD}`
로 읽는다. ConfigMap 에 평문이 남지 않는다. `local/create-secrets.sh` 가 값을 만들고
마지막에 출력한다.

#### 걸린 것 2건

**1. `--base-name` 이 항상 `docker.io/` 이름을 만들어 주지는 않는다**

```
Failed to pull image "oneinch/jenkins:latest":
  failed to resolve reference "docker.io/oneinch/jenkins:latest"
```

`k3s ctr images import --base-name docker.io/...` 로 반입했는데 containerd 에는
`localhost/oneinch/jenkins:latest` **하나만** 들어갔다. 아카이브가 이미 이름을 갖고
있으면 `--base-name` 이 쓰이지 않는다. 앞선 4종은 우연히 양쪽 이름이 다 생겼던 것이라
같은 스크립트인데도 이번만 실패했다.

→ `local/build-images.sh` 의 반입 루프에 **명시적 `ctr images tag`** 를 넣어 확정했다.

**2. JCasC 는 모르는 속성을 만나면 기동을 중단시킨다**

```
SEVERE  Failed ConfigurationAsCode.init
io.jenkins.plugins.casc.UnknownAttributesException: security:
  Invalid configuration elements for type: GlobalConfigurationCategory$Security
  : globalJobDslSecurityConfiguration
```

`globalJobDslSecurityConfiguration` 은 `job-dsl` 플러그인이 제공하는데 설치하지 않았다.
추측으로 넣은 블록이었다.

> **이건 좋은 동작이다.** 무시하고 지나갔다면 "설정을 넣었는데 적용되지 않는" 상태가
> 조용히 남는다 — 이 세션에서 반복해 만난 부류다. JCasC 는 그렇게 하지 않는다.
> 대신 **플러그인과 설정은 한 몸으로 움직여야 한다** — 플러그인을 추가할 때 설정도,
> 설정을 추가할 때 플러그인도 함께 본다.

#### 남은 것

- **에이전트가 없어 빌드가 컨트롤러에서 돈다**(`numExecutors: 1`). 에이전트를 붙이면
  0 으로 내리고 `mode: EXCLUSIVE` 로 바꿀 것. `allow-jenkins-access` 에 `jenkins-agent`
  셀렉터를 미리 열어 두었다
- **TODO-40**(Jenkins ↔ GitLab CI 역할 분담)은 그대로 미결이다. 지금 Jenkins 에는
  잡이 하나도 없다 — 무엇을 Jenkins 로 옮길지가 정해지지 않았다
- 플러그인 다운로드에 체크섬 검증이 없다 — `docker/spark-iceberg`·`docker/livy` 와
  같은 계열이다(TODO-44)

### 8-22. Pyroscope — 프로파일링 공백을 22 GiB 가 아니라 0.5 GiB 로 (2026-09-03)

Sentry 도입을 검토하다 나온 결론의 실행이다. Sentry 가 GlitchTip 보다 나은 지점은
**프로파일링과 세션 리플레이 둘뿐**이고, 나머지(트레이싱·메트릭·로그)는 이미
Tempo·Prometheus·Loki 가 받고 있다. 프로파일링만 따로 채우면 22 GiB 가 필요 없다.

```
pyroscope-0   1/1 Running   실사용 54Mi (requests 512Mi / limit 1536Mi)
/ready        ready
수집 확인     process_cpu:cpu · memory:{alloc,inuse}_{space,objects} ·
              goroutines · mutex · block  — 10종 이상의 프로파일 타입이 질의된다
Grafana       datasource `pyroscope` 프로비저닝
```

#### 산정이 틀렸던 점 — "1 GiB / 2 파드"는 낙관이었다

차트를 렌더해 본 requests 합계가 0.05 GiB 로 나와 그대로 인용했는데, **차트가
메모리 requests 를 설정하지 않아서**였지 가벼워서가 아니었다. 실제로는 Pyroscope
2.x 가 **v2 아키텍처**(raft 메타스토어 · memberlist · query-backend 분리)를 쓴다.

> 차트의 선언값은 "필요량"이 아니다. 값이 비어 있는 것과 작은 것은 다르다.

#### 네 번 막혔다 — 전부 v2 아키텍처를 그대로 옮긴 탓

차트가 `-target=all` 에 넘기는 인자를 그대로 옮겼더니 순서대로 걸렸다.

| # | 증상 | 원인 |
|:-:|---|---|
| 1 | `failed to create discovery: open /var/run/secrets/.../token: no such file` | `metastore.address=kubernetes:///…` 가 **API 서버 디스커버리**라 SA 토큰을 요구한다. 이 레포는 `automountServiceAccountToken: false` 가 규약이다(SEC-202) |
| 2 | `address pyroscope-0.pyroscope-headless: missing port in address` | raft `advertise-address` 에 포트 누락 |
| 3 | `bootstrap peers can't be resolved` | `dnssrvnoa+_raft._tcp.…` 로 **자기 자신조차** 찾지 못한다 |
| 4 | `/ready` 가 계속 503 | 앞의 셋을 피하려 memberlist 포트까지 걷어냈더니 distributor·ingester·compactor·store-gateway 가 `waiting until X is ACTIVE in the ring` 에서 멈췄다 |

**1번은 토큰을 켜는 대신 DNS 디스커버리로 바꿨다.** 권한을 하나도 주지 않고 해결된다 —
`automountServiceAccountToken: false` 를 지키는 편이 낫다.

**결론적으로 raft 메타스토어 배선을 전부 걷어냈다.** 1 레플리카에 raft 합의는 얻는 것이
없다. 남긴 것은 `-target=all` · 설정 파일 · 포트 · 자기 프로파일링, 그리고 **memberlist
포트**뿐이다. join 대상을 주지 않으면 단일 노드가 자기 링을 만들고 ACTIVE 가 된다.

> **4번이 교훈이다.** 1~3 을 피하려고 관련 인자를 통째로 지웠는데, memberlist 는
> raft 와 무관하게 **링 참여**에 필요했다. 한 덩어리로 보이는 설정도 역할이 다르다.

#### 검증을 자기 프로파일링으로 잡은 이유

`-self-profiling.disable-push=false` 로 두었다(차트는 끈다). Pyroscope 가 **자기 자신을**
프로파일링하므로 배포 직후 수집→저장→질의 경로가 실제로 도는지 확인할 수 있다.

이게 없으면 "파드는 Running 인데 데이터가 0" 인 상태를 구분하지 못한다 — 6단계의
GlitchTip 마이그레이션 누락과 같은 부류이고, OpenReplay 검토에서 우려한 것과도 같다.

#### ★ 남은 것 — 애플리케이션 프로파일링은 아직 안 된다

지금 Pyroscope 가 보는 것은 **자기 자신뿐**이다. `cmmn-api`(Spring Boot)를 프로파일링하려면
둘 중 하나가 필요하다.

| 경로 | 장애물 |
|---|---|
| Pyroscope Java 에이전트 | 앱 재빌드 필요 — **G9(Dockerfile 부재)** |
| Grafana Alloy eBPF 프로파일링 | 앱 변경 불필요하나 **WSL2 에서 eBPF 가 될지 미검증**. Falco 의 modern_ebpf 는 실패했고(W3) Tetragon 은 동작한다 |

→ **TODO-51.** 둘 중 어느 쪽이든 결정 전까지 Pyroscope 는 자기 자신만 본다.
"도구는 섰지만 대상이 없다"는 상태를 그대로 기록해 둔다.

### 8-23. otel-agent 에 도달 경로가 없었다 (2026-09-03)

애플리케이션 연동 문서를 쓰다 드러났다. **문서화가 결함을 찾은 사례다.**

`allow-otel-agent-ingress` 는 `podSelector: {}` 로 **네임스페이스 전체**에 4317·4318 을
열어 두었다. 그런데 `otel-agent` DaemonSet 에는 **hostPort 도, hostNetwork 도, Service 도
없었다.** 애플리케이션이 주소를 지정할 방법 자체가 없어, 트레이싱 배선이 문서상으로만
존재했다.

> 정책이 열려 있다고 경로가 있는 것이 아니다. NetworkPolicy 는 **도달했을 때**
> 통과시킬지를 정할 뿐, 도달 수단을 만들어 주지 않는다.

#### hostPort 는 이 클러스터에서 동작하지 않는다

DaemonSet 의 표준 해법인 hostPort 를 먼저 넣었다. 롤아웃은 성공했으나 실제로는 죽어 있었다.

```
sudo ss -lntp | grep -E ":4317|:4318"   →  리슨 없음
curl 127.0.0.1:4318          →  000
curl <노드IP>:4318           →  000
```

Cilium 구성이 hostPort 를 처리하지 않는다. **파드는 Running 이고 롤아웃도 성공하므로
증상이 보이지 않는다** — 앱이 붙는 순간에야 드러난다.

#### 해법 — Service + `internalTrafficPolicy: Local`

```yaml
spec:
  internalTrafficPolicy: Local   # 같은 노드의 파드로만 라우팅
```

DaemonSet 앞의 보통 Service 는 **아무 노드의** 에이전트나 고른다. 앱은 자기 노드의
에이전트로 보내야 게이트웨이 쪽 `k8sattributes` 가 소스 IP 로 보낸 파드를 식별한다.
`internalTrafficPolicy: Local` 이 hostPort 없이 그 성질을 준다 — **CNI 에 의존하지
않는다는 점이 hostPort 보다 낫다.**

검증(`component: application` 라벨을 단 파드에서):

```
POST http://otel-agent:4318/v1/traces -> 200
POST http://otel-agent:4318/v1/logs   -> 200
```

#### 문서

`docs/APP-INTEGRATION.md` 를 신설했다. 애플리케이션 개발자가 이 플랫폼에 붙일 때 보는
문서이며 **실제로 호출해 확인한 것만** 적는다. 확인하지 못한 것(앱 프로파일링 경로 등)은
"미검증"으로 표시한다 — 개발자가 그 문서를 보고 코드를 쓰기 때문이다.

### 8-24. OpenReplay + ClickHouse 도입 (2026-09-03)

ADR-069·070 의 실행이다. **다만 전제 2건은 여전히 미해결이라 세션 리플레이는
동작하지 않는다** — 아래 "지금 못 하는 것" 참조.

```
clickhouse-0             1/1   OpenReplay 전용(ADR-070)
openreplay-postgresql-0  1/1   PostgreSQL 17.11 — 전용 (§8-25 에서 제거)
OpenReplay               17/17
PostgreSQL 스키마        public 41 테이블
ClickHouse 스키마        experimental 7 테이블
클러스터                 103 파드 · 미준비 0
```

#### 규모가 예상과 달랐다

검토 단계에서 "8 GB / 10~12종"으로 잡았는데 실제로는 **Deployment 17 · Service 19
· Ingress 12 · ServiceAccount 18 · CronJob 1** 이다. 그리고 차트가 **워크로드
20종의 requests·limits 를 하나도 선언하지 않는다.**

`local/render-openreplay.sh` 를 생성기로 두었다. `helm template` 을 배포가 아니라
**생성 도구**로만 쓴다(Tetragon 과 같은 방식, ADR-003 유지). 스크립트가 자원·
레포 규약 라벨·자격증명 배선을 주입한다.

#### 배선이 다섯 겹으로 막혔다

| # | 증상 | 원인 |
|:-:|---|---|
| 1 | 오버라이드가 통째로 무시됨 | `vars.yaml` 이 YAML 앵커(`&postgres`)로 최상위를 정의하고 `global` 이 별칭(`*postgres`)으로 참조한다. **최상위만 덮으면 서브차트가 읽는 `global.*` 는 그대로다.** 특히 initContainer 는 호스트명을 셸 스크립트에 갖고 있어 파드 env 후처리로는 못 고친다 |
| 2 | DSN 파싱 실패 | 차트가 `pg_password` 를 자기 Secret 에서 주는데 값이 미치환 `{{ randAlphaNum 20}}` 였다 |
| 3 | `unknown port` | `CLICKHOUSE_STRING` 에 DB 이름을 붙이면 Go 클라이언트가 포트를 `9000/openreplay` 로 자른다 |
| 4 | DB 연결 타임아웃 | 마이그레이션 Job 파드에 `instance` 라벨이 없어 NetworkPolicy 가 막았다. **DNS 는 풀리는데 연결만 안 되므로** 인증 실패처럼 보이지 않는다 |
| 5 | `exit 101` | **PostgreSQL 버전** — 아래 |

#### ★ 공용 PostgreSQL 을 쓸 수 없다

```
공용        postgres:latest = 18.6
OpenReplay  16.4 ~ 17 만 지원 (initContainer 가 검사하고 범위 밖이면 exit 101)
```

공용 인스턴스는 keycloak·gitlab·apicurio·hive·ranger·glitchtip **6종**이 쓰므로
낮출 수 없다. → **전용 PostgreSQL 17** 을 세웠다(`postgres:17` 고정 — `latest` 면
18 로 올라가 다시 거부된다).

> ADR-038(전용 인스턴스 분리)의 논리가 **부하 격리가 아니라 버전 제약** 형태로
> 되살아났다. "기존 저장소를 재사용한다"는 계획은 버전 호환성 앞에서 깨질 수 있다.

#### ★ 로그 파이프라인이 먼저 죽었다

OpenReplay 를 올린 직후 **`loki-0` OOMKilled 12회 · `otel-agent` OOMKilled 7회.**
노드 압박이 아니라(MemoryPressure=False) 각자의 컨테이너 한계에서 죽었다.
파드가 80 → 103 이 되며 수집량이 뛴 것이다.

```
loki        768Mi -> 1280Mi (requests 384Mi)
otel-agent  384Mi ->  640Mi (requests 192Mi)
```

> **로그 파이프라인 용량은 파드 수에 비례한다.** 워크로드를 대량 추가할 때 함께
> 조정하지 않으면 **관측성이 가장 먼저 죽는다** — 그리고 그 시점에 진단 수단을
> 잃는다. 다음에 대량 추가를 할 때는 Loki·otel-agent 한계를 먼저 올릴 것.
>
> CrashLoop 중인 StatefulSet 은 롤링이 진행되지 않아 한계를 올려도 반영되지
> 않는다. 파드를 직접 지워야 한다.

#### 스키마 — Complete 로 끝난 Job 이 아무것도 하지 않았다

차트의 `databases-migrate` 가 `Complete` 인데 테이블이 0개였다.
`PREVIOUS_APP_VERSION == CHART_APP_VERSION` 이라 적용할 버전 델타가 없어
`migrate` 경로로 돌았고 신규 설치용 `init` 을 타지 않았다.

초기 스키마를 직접 적용했다.

```
scripts/schema/db/init_dbs/postgresql/init_schema.sql      -> public 41 테이블
scripts/schema/db/init_dbs/clickhouse/create/init_schema.sql -> experimental 7 테이블
```

이 레포에서 반복된 부류다(§8-4 부트스트랩 Job, §8-20 GlitchTip 마이그레이션).

#### 지금 못 하는 것 — 세션 리플레이는 동작하지 않는다

스택은 섰고 배선은 검증됐다. 그러나 **데이터가 들어오지 않는다.**

| 전제 | 상태 |
|---|---|
| 외부 HTTPS 진입점 | **없음**(배포 블로커 #6). Ingress 12개가 컨트롤러 없이 렌더돼 비활성이다 |
| 프런트엔드 계측 | **불가**(G9). `admin` 재빌드 경로가 없어 브라우저 트래커를 심을 수 없다 |

ADR-069 의 순서 1·2 가 그대로 남아 있다.

#### 의도된 예외

차트가 `securityContext` 를 선언하지 않아 컨테이너가 이미지 기본 사용자로 돈다.
로컬은 Kyverno 가 Audit 이라 기동하지만 **prod 는 Enforce 다.** base 승격 시 반드시
해소해야 한다. 프로브도 없어 `require-health-probes` 도 위반한다.
### 8-25. 전용 PostgreSQL 을 걷어내고 공용 18.6 으로 (2026-09-03)

§8-24 에서 전용 인스턴스를 세운 이유는 하나였다 — OpenReplay 마이그레이션 Job 이
**PostgreSQL 16.4~17 만 허용**하고 공용 인스턴스가 18.6 이라서다. 상류에서 근거를
찾은 뒤 **상한을 18 로 올려 공용을 쓰기로 했다.** 판단 근거는 ADR-071 에 있다.

렌더 스크립트가 자동으로 패치한다 — 사람이 기억할 필요가 없다:

```python
# local/render-openreplay.py
def patch_version_gate(spec):   # highVersion=17 → 18
```

#### 결과

```
공용 PostgreSQL     18.6 (Debian 18.6-1.pgdg13+2)
마이그레이션 Job    Complete — 14초        ← 버전 게이트 통과
OpenReplay          17/17 Running · 재시작 0회
chalice             GET:/signup 200        ← 런타임 질의가 실제로 돈다
제거                StatefulSet · Service · PVC · NetworkPolicy
```

**DDL 만이 아니라 런타임 질의까지 18.6 에서 돈다.** 이것이 상한을 올린 판단의
실증이다. 사전에는 스키마 정적 분석(생성 컬럼 19건이 전부 아이덴티티,
`GENERATED ALWAYS AS (...)` 0건)까지만 확인했었다.

#### 정작 걸린 것은 버전이 아니었다

전환 직후 `chalice` 만 CrashLoop 했다. 로그는 버전과 무관했다:

```
psycopg2.errors.InsufficientPrivilege: permission denied for table tenants
→ public 41 테이블 소유자가 전부 postgres
```

§8-24 에서 `init_schema.sql` 을 **슈퍼유저로 수동 적용**해서 생긴 것이다.
애플리케이션 롤 `openreplay` 에 권한이 없었다. 62개 객체를 넘겨 해소했다.

**연결된 시퀀스는 소유자를 직접 못 바꾼다:**

```
ERROR: cannot change owner of sequence "users_user_id_seq"
DETAIL: Sequence "users_user_id_seq" is linked to table "users".
```

identity·serial 시퀀스는 테이블 소유자를 자동으로 따라가므로 `pg_depend` 의
`deptype IN ('a','i')` 로 걸러야 한다. 걸러내지 않으면 DO 블록 전체가 롤백된다.

**교훈 — 부트스트랩 SQL 은 애플리케이션 롤로 적용하라.** 슈퍼유저로 넣으면
적용은 조용히 성공하고 **첫 질의에서 터진다.** 게다가 그 증상은 버전 비호환과
구분되지 않아 보여서, 하마터면 멀쩡한 결정을 되돌릴 뻔했다.

#### 곁가지 — trivy 스캔 잡의 캐시 락 경합

전환 중 `scan-vulnerabilityreport` 파드 2건이 Error 였다. PG 와 무관했다:

```
ERROR Failed to acquire cache or database lock
```

컨테이너 5개짜리 파드를 스캔하며 **컨테이너별 스캔 컨테이너가 같은 trivy DB
캐시를 동시에 잡는다.** 단일 노드 동시 스캔의 알려진 한계다. 대상이 일회성 Job
이라 정리했다.

### 8-26. 7단계 security-full — 그리고 zram 실측 (2026-09-03)

`[목표]` 마지막 단계다. **여기가 zram 실측 지점**이었다.

```
Kubescape          CronJob — AllControls 61.56 · NSA 68.82 · MITRE 62.07
Dependency-Track   apiserver 1/1 · frontend 1/1 — NVD 미러 동기화 동작
DefectDojo         django · nginx · celery worker · beat 4/4 + 초기화 Job
Caldera            1/1 — egress 격리 검증 완료
SafeLine           core 4/4 (mgt·detector·tengine·chaos) + fvm + luigi
클러스터           파드 114 · 미준비 0
```

#### 용량 산정이 크게 빗나갔다

문서는 `security-full` 을 **+13.7 GB** 로 잡고 "**128 GB 이상에서만 검증
가능**"이라고 판정했다([DEPLOYMENT.md §295-297](./DEPLOYMENT.md)). 실측은 다르다.

| | 산정 | 실측 |
|---|--:|--:|
| security-full 소요 | 13.7 GB | **3.49 GiB** |
| 판정 | ❌ 64 GB 초과 10.6 | ✅ **여유 23.5 GiB** |

**4배 과대 산정이었다.** 원인은 벤더 권장값을 그대로 더한 것이다 — 예컨대
Dependency-Track 은 힙 4 GB 를 권장하지만 SBOM 이 0건인 상태에서 실사용은
459Mi 다. 산정은 "가득 찬 시스템"을, 실측은 "방금 올린 시스템"을 말한다.
**둘 다 맞고, 지금 필요한 판단은 후자다.**

#### zram 실측

7단계 투입 전후:

```
투입 전   Mem 29.8/54.9 · Swap 1.00 GiB · 파드 103
투입 후   Mem 31.4/54.9 · Swap 6.13 GiB · 파드 114

zram      원본 5.47 GiB → 압축 1.84 GiB (2.98x) · 실점유 1.88 GiB
```

**압축률 2.98배.** §2 의 설계 가정(3배)이 실측과 일치한다. 스왑 5.13 GiB 증가분이
실제로는 **1.7 GiB 남짓의 RAM**만 먹었다. B안이 성립한다.

스래싱은 없었다 — 7단계 워크로드가 대부분 유휴라 스왑에 적합하다는 §2-1 의
분류(Burstable/zram 허용)가 맞았다.

#### Kubescape — 오퍼레이터가 아니라 CronJob

node-agent 는 노드당 1.6 GB 라 로컬 제외 대상이고(§220), ADR-052 가 Kubescape 를
`batch-low` 로 둔다. 단일 노드에서 하루 1회면 충분하므로 오퍼레이터 스택
(storage APIServer·synchronizer·gateway)을 들이지 않았다.

**이미지를 잘못 골랐다** — `kubescape:latest` 는 distroless 이고 PATH 에
`kubescape` 바이너리가 없다. 전용 CLI 는 `kubescape-cli` 다.

```
exec: "/bin/sh": stat /bin/sh: no such file or directory
exec: "kubescape": executable file not found in $PATH
```

둘 다 셸이 없으므로 `command` 를 덮지 말고 `args` 만 줘야 한다. 프레임워크
반복을 셸 루프로 짜려던 계획이 그래서 무산됐고, `framework all` 한 번으로 바꿨다.

첫 스캔 결과:

```
Critical 0 · High 566
  Resources memory limit and request     13/115 실패
  Resource limits                        17/115 실패
  List Kubernetes secrets                21/122 실패
  Writable hostPath mount                15/115 실패
```

#### 같은 실수를 세 번 했다 — emptyDir 이 이미지 파일을 가린다

```
DefectDojo nginx : /var/run 에 emptyDir → 이미지의 /var/run/defectdojo 가 가려짐
                   "can't create /run/defectdojo/uwsgi_pass: nonexistent directory"
Caldera          : /usr/src/app/conf 에 emptyDir → agents.yml 이 가려짐
                   "FileNotFoundError: conf/agents.yml"
SafeLine tengine : /etc/nginx 에 얹으려다 앞의 둘을 떠올려 중단
```

**규칙 — 컨테이너가 쓰기를 요구하는 경로가 이미지에 이미 파일을 갖고 있으면
디렉터리째 덮지 말 것.** 해법은 둘이다: 중첩 마운트로 하위 디렉터리를 되살리거나
(`/var/run` + `/var/run/defectdojo`), `subPath` 로 파일 하나만 얹는다
(Caldera 의 `local.yml`). 이 실패는 **기동 시점에만** 드러나므로 렌더 검증이나
kubeconform 으로는 잡히지 않는다.

#### NetworkPolicy 를 세 번 빠뜨렸다 — 증상이 전부 타임아웃이었다

```
DefectDojo  nginx → django 정책 없음 → /login 이 499  (인증 오류가 아니다)
SafeLine    mgt → fvm 정책 없음      → "context deadline exceeded" panic
SafeLine    mgt → 공용 PG 정책 없음  → luigi "failed to connect database"
```

셋 다 **상류 애플리케이션이 고장 난 것처럼 보인다.** `default-deny-ingress`
아래에서는 새 워크로드를 넣을 때마다 정책을 함께 넣어야 하는데, 빠뜨려도
매니페스트는 정상 렌더되고 파드도 뜬다.

#### 오버레이 라벨 변환기가 NetworkPolicy 를 조용히 무력화한다

Caldera 의 DNS 허용 규칙이 아무것도 매칭하지 않았다.

```yaml
# 작성한 것                        # 렌더된 것
podSelector:                       podSelector:
  matchLabels:                       matchLabels:
    k8s-app: kube-dns                  k8s-app: kube-dns
                                       environment: local    ← 주입됨
```

CoreDNS 는 `kube-system` 에 있어 `environment: local` 이 없다. **오버레이의 라벨
변환기가 상대편 selector 에까지 라벨을 넣는다.** 이 레포의 기존 정책은 전부 같은
네임스페이스를 가리켜 지금까지 드러나지 않았다 — **네임스페이스를 넘는 peer
selector 를 쓰는 순간 조용히 깨진다.**

해법은 `to:` 를 비우고 포트로만 한정하는 것이다. 범위는 포트 53 이라 여전히 최소다.

#### Caldera 격리 검증 (ADR-030)

ADR-030 의 "위험 요소가 아니라 검증 도구" 라는 전제는 격리가 실제로 서야 성립한다.
그래서 재봤다:

```
DNS                    동작       10.0.0.232
Caldera → PostgreSQL   차단       TimeoutError
Caldera → DefectDojo   차단       TimeoutError
DefectDojo → Caldera   차단       TimeoutError
```

이 레포에서 **egress 까지 막는 유일한 정책**이다(`default-deny` 는 ingress 전용).
C2 서버이므로 나가는 경로가 곧 위험이다. 훈련을 실행하려면 이 정책을 의도적으로
완화해야 하고, **그 완화가 곧 "훈련 창"의 기술적 표현**이 된다.

#### SafeLine — compose 전용 제품을 k8s 로 옮기며 만난 것들

상류는 docker-compose 만 지원하고 서비스끼리 **고정 IP**(`SUBNET_PREFIX.4`=mgt ·
`.5`=detector · `.10`=chaos)로 참조한다. 한 파드에 넣으면 전부 `127.0.0.1` 이 되어
그 가정이 성립한다 — 다만 그 대가로 여섯 가지가 새로 생겼다.

**① 포트 충돌** — fvm 과 tengine 이 둘 다 `:80` 을 잡는다.

```
listen tcp :80: bind: address already in use
```

compose 는 서비스마다 네트워크 네임스페이스가 따로라 없던 문제다. 볼륨을 공유하는
4종만 한 파드에 두고 fvm·luigi 를 분리했다.

**② 준비성 순환 의존** — mgt 는 기동 중에 `http://safeline-chaos:8080` 을 부르는데,
그때 파드는 아직 Ready 가 아니다. 준비되지 않은 파드는 Service 엔드포인트에서
빠지므로 `connection refused` 가 되고, 그래서 **영원히 Ready 가 되지 못한다.**
compose 에는 준비 개념이 없어 없던 문제다. `publishNotReadyAddresses: true` 로 끊었다.

**③ container_name 이 곧 호스트명 계약** — 같은 파드 안에 있어도 mgt 는 chaos 를
DNS 이름으로 부른다. compose 의 `container_name` 과 같은 이름의 Service 가 필요하다.

**④ 포트 목록이 문서에 없다** — mgt 가 chaos 의 8080 → 8088 을, fvm 의 80 → 9004(gRPC)를
차례로 부른다. 하나씩 열면 panic 을 한 번씩 더 만난다. `/proc/net/tcp` **와
`/proc/net/tcp6`** 를 함께 읽어 8001·8080·8088·9000 을 한 번에 확보했다.

> **자기 정정** — IPv4 테이블만 보고 "8080 은 없다"고 판단해 Service 를 9000 으로
> 돌렸다가 404 를 받았다. chaos 의 auth 는 **IPv6 와일드카드**(`[::]:8080`)에 붙어
> 있었다. 포트는 처음부터 맞았고 진짜 원인은 ②였다.

**⑤ root 가 필요하다 (의도된 예외 8번째)** — detector 와 tengine 의 엔트리포인트가
작업 디렉터리를 chown 한다.

```
detector: chown: changing ownership of '/resources/detector': Operation not permitted
tengine : nginx: [emerg] chown("/usr/local/nginx/client_body_temp", 203) failed
```

`CHOWN·SETUID·SETGID·DAC_OVERRIDE`(+tengine `NET_BIND_SERVICE`)를 준다.
**prod 제약** — Kyverno `disallow-root` 가 prod 에서 Enforce 다. 기존 root 예외
7건도 같은 상태라 SafeLine 만의 문제는 아니지만, **prod 승격 전에 정책 예외
목록이 필요하다.**

**⑥ nginx 워커 수는 cgroup 을 보지 않는다** — tengine 이 768Mi 와 1536Mi 에서
연달아 `exit 137`(OOMKilled) 이었다.

```
노드 코어 24 → nginx worker_processes auto 가 24 워커를 띄운다
cpu limit "2" 를 걸어도 워커 수는 줄지 않는다
tengine 실사용 1783Mi → limit 3Gi
```

`worker_processes auto` 는 **cgroup CPU 한도가 아니라 호스트의 온라인 코어 수**를
읽는다. compose 는 메모리 상한이 없어 드러나지 않는 차이다.

#### SafeLine 이 지금 지키는 것은 없다

ADR-029 의 체인은 `OPNsense → SafeLine → ingress-nginx → oauth2-proxy → 서비스` 다.
그런데 이 클러스터에는 **IngressClass 가 0개**이고 LoadBalancer·NodePort 도 없다.
OpenReplay 가 만든 Ingress 12개도 컨트롤러가 없어 무용이다.

즉 **SafeLine 은 배포되어 동작하지만 앞단에 트래픽이 없다.** 여기서 실증된 것은
"WAF 가 이 클러스터에서 뜬다"이지 "체인이 선다"가 아니다. 체인을 세우려면
ingress-nginx 가 선행해야 한다(ADR-069 순서 1-2, G9 — 보류 중).

### 8-27. requests 실측 정정 — 예약 80% 대 실사용 46% (2026-09-03)

L0 랩(§9)을 세울 메모리를 만들려다 시작했는데, 정정 자체가 더 큰 문제를 드러냈다.

```
노드 allocatable        52.9 GiB
memory requests         43536Mi (80%)
실제 컨테이너 RSS 합    24.3 GiB (46%)
                        ─────────────
                        18 GiB 이 예약만 되고 놀았다
```

이 상태에서는 새 워크로드를 넣을 자리가 없는데, 그 원인이 **실제 부족이 아니라
과대 예약**이었다.

#### 순수 삭감이 아니었다 — 5건은 오히려 부족했다

| 워크로드 | 예약 | 실사용 | 차이 |
|---|--:|--:|--:|
| safeline | 1216Mi | 2020Mi | **−804** |
| logstash | 1024Mi | 1357Mi | **−333** |
| loki | 384Mi | 672Mi | **−288** |
| spark-history | 512Mi | 707Mi | **−195** |
| gitlab | 2048Mi | 2077Mi | −29 |

**이쪽이 과대 예약보다 위험하다.** requests 미만으로 쓰는 파드는 축출 순위에서
보호받지만 **초과하는 파드는 가장 먼저 축출된다.** 노드가 압박을 받으면
safeline·logstash·loki 가 먼저 죽는 상태였고, 공교롭게 **loki 는 로그 파이프라인
자체**다 — 압박이 시작되면 그 원인을 볼 수단부터 사라진다.

safeline 의 원인은 §8-26 의 그것이다. tengine 이 nginx 워커를 **호스트 코어
수(24)만큼** 띄우고 각각 탐지 룰셋을 올린다. limit 은 OOM 을 겪고 3Gi 로
올렸으면서 **requests 는 384Mi 그대로 두었다** — limit 만 보고 requests 를 잊었다.

#### 결과

```
                 이전        이후
memory requests  43536Mi     36688Mi     −6.7 GiB
                 (80%)       (67%)
파드             113         113          손실 없음
sts/deploy       37/40       37/40        전부 충족
```

#### istiod 가 단일 최대 낭비였다

```
istiod    예약 2048Mi · 실사용   69Mi   → 256Mi
ztunnel   예약  512Mi · 실사용    6Mi   → 128Mi
```

둘이서 노드 allocatable 의 **4.8%** 를 잡고 있었다. `istioctl install` 의 기본값이
다중 노드 프로덕션 기준이라 그렇다. **kustomize 오버레이가 닿지 않는다** —
오퍼레이터 계층은 `local/install-operators.sh` 가 설치하므로 거기에
`--set values.pilot.resources.requests.*` 를 넣었다. 라이브 객체도 함께 패치했다.

오퍼레이터 계층은 오버레이의 사각지대다. 지금까지 이 계층의 자원을 한 번도
보지 않았는데, 노드 예약의 5% 가 거기 있었다.

#### 규칙

- **Burstable** — 실사용의 1.3~2배. JVM 은 기동 피크가 유휴보다 높으므로 넉넉히
- **Guaranteed 8종** — `qos-guaranteed.yaml` 에서 requests·limits 를 **함께**
  바꾼다. 한쪽만 바꾸면 zram 배제 성질이 깨진다. Guaranteed 는 스왑을 0 받으므로
  **과대 예약의 대가가 Burstable 보다 크다** — 실 RAM 을 그대로 점유한다
- **limit 을 넘는 request 를 쓰지 않는다** — limits-local 이 기록한 그 함정이
  requests 방향으로도 성립한다. 파드가 CrashLoop 도 Pending 도 아니고 그냥 사라진다

#### 왜 지금까지 몰랐나

`limits-local.yaml` 이 3단계에서 limits 를 정리하며 명시적으로 적어 뒀다 —
"**requests 는 손대지 않는다. 스케줄 여유(57%)는 문제가 아니었다.**"
그때는 맞는 판단이었다. 파드가 103 → 113 으로 늘고 7단계가 들어오면서
57% 가 80% 가 되었는데, **limits 만 보는 습관이 남아 requests 를 다시 보지 않았다.**

### 8-28. 재부팅 후 — 클러스터가 10분마다 죽었다 (2026-09-03)

L-1 준비(Hyper-V 활성화 + WSL 캡 44GB)를 위해 재부팅했더니 클러스터가
**약 10~12분마다 전멸**했다. 원인을 찾는 데 오래 걸렸고, 중간에 잘못된 결론을
두 번 냈다.

#### 증상과 오진

```
k3s PID 가 계속 바뀜 → "k3s 크래시"
  level=error msg="scheduler exited: finished without leader elect"
  systemd[1]: k3s.service: Main process exited, code=exited, status=1/FAILURE
```

**오진 ①: 메모리 부족.** 캡을 56→44 GB 로 줄인 직후라 그렇게 보였다.
실측은 반대였다 — Mem 3.8/43.1 GiB, 스왑 0, OOM 0건, 스래싱 없음.
`memory.max`·`MemoryMax` 도 전부 `infinity` 였다.

**오진 ②: VM 유휴 종료.** `Reached target poweroff.target` 을 보고 그렇다고
했다가, `uptime` 이 연속이고 `boot_id` 가 같아서 **아니라고 정정**했다.
그 정정도 틀렸다 — 마침 살아 있는 구간을 본 것이었다.

`scheduler exited` 는 원인이 아니라 **종료 경로의 마지막 로그**다. k3s 의
스케줄러는 `--leader-elect=false` 라 컨텍스트가 취소되면 그 문구로 끝난다.
이 줄을 원인으로 읽으면 계속 엉뚱한 곳을 판다.

#### 실제 원인

시스템 전체 저널을 k3s 유닛 밖까지 넓히자 나왔다.

```
WSL (2 - init-systemd(Ubuntu)) ERROR: InitTerminateInstanceInternal:2763:
systemctl poweroff did not terminate...
```

**WSL 이 배포판 인스턴스를 종료시키고 있었다.** 붙은 프로세스가 없으면
WSL 이 `systemctl poweroff` 를 넣는다. systemd 가 k3s 를 정지시키고,
다음 `wsl.exe` 명령에서 배포판이 새로 뜨며 파드가 전부 재시작한다.

**왜 지금까지 안 드러났나** — 사람이 WSL 터미널을 열어 두면 그 셸이 상주
프로세스 역할을 한다. 재부팅으로 터미널이 사라지고 짧은 `wsl.exe -- <명령>`
만 돌리는 상황이 되자 표면화됐다.

#### `.wslconfig` 의 vmIdleTimeout 은 두 가지가 잘못돼 있었다

**① 섹션이 틀렸다.** `[experimental]` 이 아니라 **`[wsl2]`** 다. WSL 은
모르는 키를 "unknown key" 로 **조용히 무시**하므로, 24시간으로 설정해 둔
값이 처음부터 적용된 적이 없었다. 기본값 60초가 내내 걸려 있었다.

**② 그것으로도 부족하다.** `vmIdleTimeout` 은 **VM 유휴 타임아웃**이고
여기서 일어난 것은 **배포판 종료**다. 별개 메커니즘이라 `-1` 을 넣어도
이 현상은 남는다. 실측:

```
vmIdleTimeout=-1 적용 후에도  →  k3s 누적 기동 8회 (부팅 1회 내)
Windows 쪽 분리 상주 프로세스 →  유휴 6분간 재시작 0회
```

#### 해법 — `local/keepalive.ps1`

```powershell
Start-Process wsl.exe -ArgumentList '-d','Ubuntu','--','sleep','infinity' -WindowStyle Hidden
```

**`Start-Process` 로 분리해야 한다.** 호출한 셸에 매달면 그 셸이 끝날 때
함께 죽어 재발한다 — 실제로 그렇게 한 번 실패했다.

검증:

```
기준   uptime 2772s · k3s 누적기동 13   (20:38:31)
6분간 WSL 무접촉
결과   uptime 3125s · k3s 누적기동 13   재시작 0회
```

#### 같이 드러난 결함 3건

**loki `exit 137`** — 정상 운용 실사용은 672Mi 인데 **콜드 스타트에서
110여 파드가 동시에 뿜는 로그 버스트**가 limit 1280Mi 를 넘겼다. 2Gi 로 올렸다.
이 워크로드는 유휴 사용량으로 한도를 정하면 안 된다.

**kibana `exit 134`(SIGABRT)** — base 가 limit 1Gi 인데 실사용 797Mi 다.
Node 힙 + RSS 오버헤드가 그 위에서 abort 한다. 재시작 51회. requests 도
256Mi 로 실사용의 1/3 이라 축출 1순위였다(§8-27 과 같은 유형).
로컬 오버레이에서 768Mi/1536Mi 로 조정했다.

**Kyverno 웹훅 fail-closed 교착** — `kyverno-admission-controller` 가
`Unknown` 으로 멈추자 서비스 엔드포인트가 비었고, `validate.kyverno.svc-fail`
이 **모든 쓰기를 막았다.** `kubectl delete` 조차 거부된다.

```
Error from server (InternalError): Internal error occurred:
  failed calling webhook "validate.kyverno.svc-fail"
```

파드를 강제 삭제해 엔드포인트를 되살려야 풀린다. **정책 엔진이 자기 복구를
막는 구조**라, 배포판 종료로 컨트롤러가 죽을 때마다 재현된다.

#### 부수 확인 — 캡 44GB 는 맞았다

```
allocatable  43101832Ki (41.1 GiB)
requests     37200Mi (88%)
Pending      0
```

§8-27 의 requests 정정(80%→67%)이 선행되지 않았으면 이 캡에서 파드가
스케줄되지 않았다.

#### StatefulSet 에 남은 제약

§8-27 과 함께 넣은 `storageClassName: standard` 명시가 **기존 StatefulSet 에는
적용되지 않는다** — `volumeClaimTemplates` 가 불변이다.

```
StatefulSet.apps "gitlab" is invalid: spec: Forbidden:
  updates to statefulset spec for fields other than 'replicas', 'ordinals', ...
```

`--cascade=orphan` 으로 지웠다 다시 만들면 파드·PVC 를 유지한 채 반영되지만,
그 작업 자체가 대량 롤아웃을 유발해 클러스터를 흔든다. **이미 바인딩된 PVC 는
전부 `standard` 라 실동작에 차이가 없으므로** 재구축 시점에 반영되게 두었다.
clickhouse 만 작업 중 삭제돼 개별 복구했다.

### 8-29. Kyverno root 예외 목록 — prod 배포 블로커였다 (2026-09-04)

§8-26 에서 SafeLine 을 8번째 root 예외로 추가하며 남겨 둔 항목이다.
`disallow-root-user` 는 **prod 에서 Enforce** 인데 예외 목록이 없었다.

#### 두 부류가 걸려 있었다

정책을 그대로 Enforce 로 올리면 39건이 거부된다.

| 부류 | 건수 | 성격 |
|---|--:|---|
| 의도된 예외(매니페스트에 사유 기록) | 9 | gitlab·falco·filebeat·otel-agent·ds389·lam·wazuh-manager·safeline(fvm·luigi 포함) |
| **오퍼레이터·시스템 계층** | 11 | cilium(3)·coredns·local-path-provisioner·istio-cni·ztunnel·tetragon·trivy(2) |
| OpenReplay | 18 | 전 워크로드 + 마이그레이션 Job |

**둘째 부류가 더 위험하다.** ClusterPolicy 는 전 네임스페이스를 대상으로 하므로,
Enforce 상태에서 **cilium 이나 coredns 가 재시작하려는 순간 admission 이
거부한다.** 클러스터가 스스로 복구하지 못하는 상태가 된다. 이건 정책이 워크로드가
아니라 **플랫폼 자신을 막는** 경우다.

#### 왜 이름으로 한정했나

어노테이션 opt-out(예: `allow-root: "true"`)이면 워크로드 쪽에서 스스로 예외를
선언할 수 있어 정책의 의미가 없어진다. **정책 파일에 이름을 넣는 행위 자체가
리뷰 지점이어야 한다.**

#### 실측

```
예외 추가 전   39건 실패
라벨 예외 8종   → 28건
네임스페이스 8개 → 18건 (전부 local/OpenReplay)
```

#### ★ PolicyReport 는 정책 변경으로 갱신되지 않는다

여기서 한참 헤맸다. 예외를 넣고 정책을 적용해도 보고서가 계속 `fail` 이었다.
라벨도 정책도 정확한데 결과가 안 바뀌니 문법을 의심하게 된다.

```
정책 갱신     01:11:03
보고서 시각   01:12:12   ← 정책보다 나중인데도 fail
```

**타임스탬프가 갱신되어도 재평가된 것이 아니다.** reports-controller 를
재시작해도 마찬가지였다. 해당 PolicyReport(파드 UID 이름)를 **삭제해야**
재생성되면서 예외가 반영된다.

```bash
kubectl -n <ns> delete polr "$(kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.uid}')"
```

이 성질 때문에 **정책 변경의 효과를 보고서로 확인하려면 반드시 보고서를
지워야 한다.** 안 그러면 "고쳤는데 안 된다"로 오판한다.

> 참고로 `exclude.any[].resources` 에 `selector` 만 두면 매칭되지 않았다.
> `kinds: [Pod]` 를 함께 줘야 한다. 다만 이 수정과 보고서 캐시가 겹쳐 있어
> 어느 쪽이 결정적이었는지는 분리해 확인하지 않았다 — 둘 다 넣은 상태가
> 동작하는 것만 확인했다.

#### 남은 것 — OpenReplay 18건

`overlays/local` 전용이라 지금 prod 에 영향은 없다. 그러나 **ADR-069 의 승격
조건에 이 항목이 추가되어야 한다** — 17개 워크로드 전부가 root 로 뜨고,
상류 차트가 그렇게 만든다.

선택지는 둘이다.

- **예외 목록에 추가** — 3자 앱 17종을 보안 정책에서 빼는 것이라 정책의
  실효 범위가 크게 줄어든다
- **승격하지 않는다** — 로컬 검증 도구로만 쓴다

**결정하지 않고 남긴다.** 어느 쪽이든 ADR-069 를 다시 열어야 하는 사안이다.


### 8-30. PowerShell 스크립트가 BOM 없이 저장되면 코드가 조용히 사라진다 (2026-09-04)

L0 랩을 만들다 만난 것이지만 **원인은 랩과 무관하고 이 레포의 `.ps1` 전부에
해당한다.** 별도 항목으로 둔다.

#### 증상

`setup-l0-lab.ps1` 을 관리자 권한으로 돌렸더니 OPNsense VM 만 만들어지고
`L0-Target` 은 만들어지지 않았다. **오류도 경고도 없었다.** 스크립트는
"완료" 를 출력하고 정상 종료했으며, 마지막 상태 표에도 VM 이 하나만 찍혔다.

#### 원인

파일이 UTF-8 인데 **BOM 이 없다.** PowerShell 5.1 은 BOM 이 없는 `.ps1` 을
시스템 ANSI 코드페이지(여기서는 CP949)로 읽는다. 한글 주석의 UTF-8 바이트가
CP949 로 잘못 디코딩되면서 따옴표 짝이 어긋났고, target VM 생성 블록 40여 줄이
**문자열 리터럴 안으로 흡수**됐다.

AST 로 확인한 것이 결정적이다.

| | 줄 수 | 파싱 오류 | 인식된 `New-VM` |
|---|--:|--:|---|
| BOM 없음 | 205 | **0** | 115 |
| BOM 있음 | 211 | 0 | 115 · **148 · 154** |

```powershell
$t=$null; $e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($f,[ref]$t,[ref]$e)
$e.Count   # 0 — 구문 오류가 아니다
$ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and
              $n.GetCommandName() -eq 'New-VM'}, $true)
```

**`parseErr` 가 0 인 것이 이 결함의 성질을 말해준다.** 구문 오류라면 즉시
드러난다. 여기서는 문법적으로 완결된 다른 프로그램이 되어 버리므로 검증
수단이 없다 — 실행 결과를 세어 보는 것 말고는.

#### 왜 지금까지 드러나지 않았는가

`local/keepalive.ps1` · `local/keep-alive.ps1` 도 BOM 이 없고 같은 조건이다.
둘은 각각 4줄씩 잃지만 **잃은 것이 전부 주석 줄이라 명령 수가 변하지 않아**
지금까지 정상 동작했다.

```
keep-alive.ps1 : lines 30 vs 34 | commands 6 vs 6
keepalive.ps1  : lines 63 vs 67 | commands 11 vs 11
```

즉 지금까지는 운이 좋았을 뿐이고, 주석 한 줄만 고쳐도 명령이 사라질 수 있다.
`keepalive.ps1` 은 클러스터 생존 스크립트다(§8-28, Gotcha 6).

#### 조치

세 파일 전부에 BOM 을 붙였다. 내용은 바이트 단위로 그대로 두고 앞에만 붙인다.

```powershell
$b=[IO.File]::ReadAllBytes($f)
[IO.File]::WriteAllBytes($f, (,[byte]0xEF+[byte]0xBB+[byte]0xBF)+$b)
```

**앞으로 이 레포에 `.ps1` 을 추가할 때는 BOM 을 확인할 것.** 한글 주석을
쓰는 한 이 문제는 반복된다. 확인은 아래 한 줄이면 된다.

```bash
head -c3 file.ps1 | od -An -tx1   # efbbbf 여야 한다
```

#### 곁가지 — 같은 실행에서 드러난 스크립트 결함 3건

1. **경로 검증이 VM 생성 뒤에 있었다.** ISO 가 아직 없는 상태로 `-IsoPath` 를
   주고 돌린 실행이 OPNsense VM 을 만든 **직후** `throw` 했고, 랩이 반만 남았다.
   재실행하면 "이미 존재 — 건너뜀" 이 결손을 덮는다. 검증을 §0 으로 옮겼다
2. **`qemu-img` 의 vhdx 드라이버는 resize 를 구현하지 않는다.**
   `Image format driver does not support resize` — 변환 **전에** qcow2 단계에서
   늘려야 한다. 게다가 실패 시점에 vhdx 는 이미 만들어져 있어 크기만 틀린
   파일이 남고, 존재 검사에 걸려 재실행이 조용히 건너뛴다
3. **`genisoimage` 의 stderr 를 버리고 있었다.** 실행 중인 VM 의 DVD 에 물린
   ISO 는 잠겨 있어 재생성이 실패하는데, 메시지를 지우면 줄 번호만 남는다

### 8-31. H5 검증 완료 — Hyper-V 에서 Cilium 이 동작한다 (2026-09-04)

`ADR-051`(A안, k3s 를 Hyper-V 다중 노드로 이설)의 마지막 `[UNVERIFIED]` 항목이다.
Hyper-V 합성 NIC(`hv_netvsc`)에서 Cilium eBPF 가 도는지 확인된 바가 없었다.

**데이터를 날린 뒤에 알게 되는 것을 피하려고 랩 VM 한 대에서 먼저 확인했다.**
이설은 PVC 27개(PostgreSQL·GitLab·ES·MinIO·Kafka)를 재생성하며 되돌릴 수 없다.

#### 환경

L0-Target(Hyper-V Gen2 · Ubuntu 24.04 클라우드 이미지 · 4 GiB · 커널 6.8.0-138),
k3s v1.31.4+k3s1 · Cilium 1.16.5 — **클러스터와 동일한 플래그**로 세웠다.

#### 결과 — PASS 12 · FAIL 0

| 단계 | 확인한 것 | 결과 |
|:-:|---|---|
| 0 | `hv_netvsc` · BTF 6.1 MB · `xt_TPROXY`·`xt_socket`·`nf_conntrack` | 5/5 |
| 1 | k3s API | PASS |
| 2 | **Cilium 정상 기동** | PASS |
| 3 | CoreDNS · 파드 IP · Service DNS + socketLB | 3/3 |
| 4 | **NetworkPolicy 강제 + 제거 후 복귀** | 2/2 |
| 5 | XDP `Device Mode: veth` | 참고 |

**4번이 핵심이다.** ADR-043 이 지적한 M1 의 실패 모드가 "설정이 틀려도 통신은
정상이고 정책만 조용히 적용되지 않는다" 이기 때문이다. 세 경로 전부에서 확인했다.

| | DNS | ClusterIP | PodIP |
|---|---|---|---|
| 기준선 | 200 | 200 | 200 |
| default-deny 적용 | 000 | 000 | 000 |
| 정책 제거 | 200 | — | 200 |

XDP 는 예상대로 미지원이다(`veth`). H5 의 판정은 **"기능은 정상이나 성능
기준선으로 쓰지 말 것"** 이고, 이 검증은 기능만 답한다.

#### 첫 실행은 FAIL 1 이었고, 그 해석이 틀릴 뻔했다

처음 돌렸을 때 3단계 `Service 경유 통신 실패 — socketLB 또는 DNS` 가 났다.
그대로면 **H5 미해소**이고 ADR-051 은 중단이다. 그런데 직접 재현해 보니:

```
호스트 → ClusterIP   200
파드   → PodIP       200
파드   → ClusterIP   200      ← socketLB 는 정상이었다
파드   → DNS 이름    000
```

몇 분 뒤 같은 검사가 3회 연속 200 이었다. **CoreDNS 가 Cilium 기동 직후
아직 준비되지 않은 시점에 쏜 것**이다(CNI 가 바뀌면서 IP 를 다시 받는다).
환경 특성이 아니라 검증 스크립트의 경쟁 조건이었다.

#### 더 나빴던 것 — 4단계가 거짓 통과였다

같은 실행에서 4단계는 **PASS** 로 찍혔다. 판정이 `응답 != 200 이면 차단됨`
이었기 때문이다. 3단계에서 이미 통신이 죽어 있었으므로 **정책과 무관하게
무조건 통과**한다. 정책이 걸렸다는 근거가 전혀 아니었다.

FAIL 하나가 눈에 띄어 들여다보지 않았다면, "핵심 항목인 4단계는 통과했다" 는
잘못된 결론을 그대로 문서에 남겼을 것이다.

`verify-h5.sh` 를 세 곳 고쳤다.

1. 3단계 전에 **CoreDNS rollout 을 기다린다**
2. 4단계는 **기준선을 먼저 200 으로 확인**하고, 아니면 통과도 실패도 아닌
   **판정 불가**로 남긴다
3. 정책 제거 후 **200 으로 복귀하는지까지** 본다 — 차단만 보면 "정책이 걸렸다"
   와 "그 사이 무언가 고장났다" 를 구분할 수 없다

#### 남는 것은 기술 위험이 아니라 비용이다

H5 가 해소되었으므로 ADR-051(A안)의 기술적 중단 사유는 없다. 남는 판단은
`local/l0-lab/README.md` 에 적어 둔 셋이다 — **PVC 27개 재생성**(되돌릴 수 없다),
**정적 메모리 분할**(H1 이 동적 메모리를 금지해 VM 간 슬랙이 넘어가지 않는다),
클러스터 재구축 시간. 메모리는 실측상 들어간다(2노드 44.7 GiB · 3노드 48.7 GiB).

> 검증 동안 target 의 NIC 을 Hyper-V 내장 `Default Switch`(NAT)로 옮겼다.
> k3s·Cilium 을 내려받아야 하는데 `L0-LAN` 은 Internal 이고 OPNsense 가 아직
> 게이트웨이가 아니기 때문이다. **`L0-WAN`(External)을 쓰지 않았다** — 그쪽은
> 물리 LAN 에 그대로 노출되고 이 VM 에는 랩 전용 약한 자격이 들어 있다.
> 검증 후 `L0-LAN` 으로 되돌렸다. 되돌리지 않으면 "target 의 유일한 출구가
> OPNsense" 라는 랩의 전제가 깨진다.

### 8-32. OPNsense 무인 구성 — 시리얼 콘솔로 사람 손 없이 (2026-09-04)

`local/l0-lab/README.md` 는 "OPNsense 설치 프로그램은 콘솔 대화형이라
자동화하지 않는다" 고 적고 있었다. **그 판단은 이미지 선택의 결과였지
OPNsense 의 성질이 아니었다.**

#### 잘못 짚었던 것

| 내가 적었던 것 | 실제 |
|---|---|
| "콘솔 대화형이라 자동화 불가" | DVD **설치 프로그램**만 그렇다. `nano` 는 설치 과정이 없다 |
| "다운로드에 몇 시간" | 미러를 재보지 않았다. leaseweb 381 KB/s — 468 MB 에 20~70분 |
| "관리자 권한이 필요" | 권한과 무관하다. DVD 가 **VGA 프레임버퍼**에 그려 텍스트 스트림이 아닌 것이 원인이다 |

미러 실측(2026-09-04): `pkg.opnsense.org` 63 KB/s · `dotsrc` 101 · `c0urier` 168 ·
`leaseweb` **381**. 하루 전 다른 미러의 20 KB/s 를 재보지 않고 옮겨 쓴 것이
"몇 시간" 의 근거였다.

#### 자동화 경로

`nano` 이미지는 **이미 설치된 시스템**이고 임베디드용이라 시리얼 콘솔이 기본이다.
Hyper-V 는 Gen2 를 포함해 VM 의 COM 포트를 named pipe 에 붙일 수 있다.

```
Set-VMComPort -VMName L0-OPNsense -Number 1 -Path \.\pipe\opnsense-com1
```

그 파이프가 곧 읽고 쓸 수 있는 텍스트 스트림이다. `serial-console.ps1`(데몬) +
`serial-expect.ps1`(패턴 대기) 로 콘솔 메뉴 전체를 몰 수 있다. 실측 결과
**사람 개입 0회**로 부팅 → 로그인 → 인터페이스 주소 변경 → SSH 활성화까지 갔다.

#### Gen1 이어야 한다 — 붙이기 전에 확인했다

```
Disklabel type: dos          ← MBR, EFI System Partition 없음
```

Gen2(UEFI)로는 부팅하지 못한다. **부팅시켜 보고 검은 화면을 해석하는 대신
이미지의 파티션 표를 먼저 읽었다.** 실제로는 파티션 표조차 없다 —
디스크 전체가 UFS 인 "dangerously dedicated" 레이아웃이다(`glabel` 이
`ufs/OPNsense_Nano` 를 `da0` 자체에 붙인다).

#### 사고 — NIC 순서 때문에 물리망에서 공유기 IP 를 주장했다

OPNsense 기본 설정은 **첫 NIC 을 LAN 에** 배정하고 192.168.1.1/24 + DHCP 서버를
올린다. 랩 스크립트는 첫 NIC 을 `L0-WAN`(External, 물리 NIC 공유)에 붙이고
있었다. 결과:

```
LAN (hn0) -> v4: 192.168.1.1/24     ← 물리망에 붙은 인터페이스
호스트 주소            192.168.1.222
호스트 기본 게이트웨이  192.168.1.1   ← 같은 주소
```

부팅 직후 약 1분간 **공유기의 IP 를 물리망에서 주장하며 DHCP 서버를 돌리고
있었다.** 게이트웨이 ARP 가 실제 공유기 MAC(`74-24-9F-…`)을 유지했고 호스트
연결도 끊기지 않았지만, 우연에 기댄 결과다.

조치 두 가지.

1. `setup-l0-lab.ps1` 이 **첫 NIC 을 `L0-LAN`(Internal)에** 붙인다. 배정이
   틀려도 격리된 스위치라 물리망에 닿지 않는다
2. LAN 대역을 `10.77.0.1/24` 로 옮겼다. 기본값 192.168.1.0/24 는 이 호스트의
   실제 대역과 같아, Internal 스위치에 두더라도 호스트에 같은 대역 인터페이스가
   둘 생겨 라우팅이 깨진다

Hyper-V 어댑터 이름도 실제와 맞췄다. **'LAN' 이라 이름 붙은 어댑터가 실제로는
WAN 인 상태**가 이 사고를 키웠다.

#### authorized_keys 는 파일에 넣으면 안 된다

`/root/.ssh/authorized_keys` 에 직접 넣은 키가 **재부팅 후 사라졌다.** 파일 자체가
없어졌다. OPNsense 는 `config.xml` 을 원천으로 삼아 그 파일을 재생성한다.

```xml
<name>root</name><authorizedkeys>BASE64</authorizedkeys>
```

주의: 사용자 블록에 **빈 `<authorizedkeys/>` 가 이미 있다.** 새로 추가하면
중복이 되어 뒤엣것이 이긴다 — 빈 쪽을 지워야 한다.

증상이 오해를 부른다. SSH 핸드셰이크는 성공하고 호스트 키까지 등록된 뒤
**keyboard-interactive 로 넘어가 멈춘다.** `ssh -v` 없이는 "SSH 가 먹통"으로만
보이고, 원인이 인증이라는 것이 드러나지 않는다.

#### nano 의 대가 — /var 가 램디스크다

```
use_mfs_tmp / use_mfs_var
tmpfs on /var/log (tmpfs, local)
```

이 랩의 목적이 하필 *"Suricata EVE JSON · Zeek 로그 → Logstash"* 라서,
그대로 두면 **검증하려는 로그가 재부팅마다 사라진다.** `config.xml` 에서
두 항목을 지우고 재부팅해 해소했다. 루트는 읽기·쓰기로 붙어 있어
(`ufs, local, noatime, soft-updates`) 그대로 써도 된다.

**디스크 확장은 실패했다.** VHDX 를 16 GB 로 늘려 게스트도 16 G 로 인식하지만
(`diskinfo` 확인), 마운트 상태의 `growfs` 가 커밋되지 않고 `/etc/rc.d/growfs` 도
파티션 기반 레이아웃을 전제해 동작하지 않는다. **여유 530 MB 로 남아 있다.**
Suricata 에는 충분하나 Zeek 은 어렵다. 단일 사용자 모드에서 언마운트 상태로
`growfs` 를 돌리는 것이 남은 방법이다.

#### 현재 상태

```
OPNsense 26.7 (FreeBSD 15.1-RELEASE-p1) · Gen1 · 6 GiB · 2 vCPU
LAN  hn0 10.77.0.1/24   (L0-LAN, Internal, DHCP 10.77.0.100-199)
WAN  hn1 192.168.1.23   (L0-WAN, External, 인터넷 확인됨)
SSH  키 인증 (config.xml 영속)
Suricata 8.0.6 — **기본 탑재다.** os-suricata 플러그인은 없다.
  NETMAP 지원 포함 — 인라인 IPS 모드의 전제
Zeek — 이 저장소에 패키지가 없다. 별도 경로가 필요하다
```

남은 것은 Suricata 를 **LAN 인터페이스에 IPS 모드로** 거는 것과 ADR-031
로그 파이프라인이다.

### 8-33. Suricata 인라인 IPS 검증 — 설정 필드 하나가 조용히 무시됐다 (2026-09-04)

§8-32 에서 세운 OPNsense 위에 Suricata 를 **LAN 인라인 IPS** 로 걸고,
룰이 실제로 차단하는지 확인했다. `local/l0-lab/suricata/` 에 룰과 절차를 남겼다.

#### 먼저 — 플러그인이 필요 없다

```
/usr/local/bin/suricata → This is Suricata version 8.0.6 RELEASE
Features: ... NETMAP ... HAVE_JA3 HAVE_JA4 ...
```

**OPNsense 기본 탑재다.** `os-suricata` 플러그인은 존재하지 않는다.
`NETMAP` 이 컴파일되어 있어 인라인 모드의 전제가 이미 충족되어 있다.

#### 설정 필드를 잘못 짚었다 — 그리고 조용히 무시됐다

처음에 `config.xml` 에 `<ips>1</ips>` 을 넣었다. **모델에 그런 필드가 없다.**

```
IDS.xml:  <mode type="OptionField"> <Default>pcap</Default>
            pcap   PCAP live mode (IDS)     ← 관측만
            netmap Netmap (IPS)
            divert Divert (IPS)
```

템플릿이 실제로 보는 것은 `mode` 다.

```jinja
{% if OPNsense.IDS.general.mode|default("") == "netmap" %}
```

그래서 생성된 `/etc/rc.conf.d/suricata` 가 `# IDS mode, pcap live mode` 였다.

**이 실패가 위험한 이유는 아무 증상이 없다는 것이다.** suricata 는 정상
기동하고 `configctl ids status` 는 running 이며 `eve.json` 에 alert 도 쌓인다.
그런데 **아무것도 차단되지 않는다.** ADR-043 이 M1 에서 지적한 실패 모드와
같은 형태다 — "설정이 틀려도 통신은 정상이고 정책만 적용되지 않는다".

구분하는 방법은 프로세스 인자를 보는 것뿐이다.

```
suricata -D --pcap=hn0 ...   ← 관측
suricata -D --netmap ...     ← 인라인
```

#### 검증 — 세 단계를 다 밟았다

`mode=netmap` 으로 고친 뒤, target(10.77.0.191) 의 ICMP 만 떨어뜨리는 룰
하나로 확인했다.

| 단계 | ICMP | DNS(UDP) | HTTP(TCP) |
|---|---|---|---|
| 기준선(룰 없음) | 0% 손실 | — | — |
| **룰 적용** | **100% 손실** | 정상 | 301 |
| 룰 제거 | 0% 손실 | — | — |

**DNS·TCP 를 함께 본 것이 핵심이다.** 실제로 첫 확인에서 HTTP 도 000 이 나와
"전부 막힌 것 아닌가" 를 의심했다. 확인해 보니 그 사이트(neverssl.com)의
문제였고, IP 로 직접 친 `http://1.1.1.1` 은 301 이었으며 DNS 도 정상이었다.
**ICMP 만 봤다면 "룰이 막았다" 와 "데이터패스가 깨졌다" 를 구분하지 못한다.**

`eve.json` 이 최종 근거다. alert 만이 아니라 **drop 이벤트**가 나온다.

```json
{"event_type":"drop","in_iface":"hn0","proto":"ICMP",
 "drop":{"reason":"rules"},
 "alert":{"action":"blocked","signature":"L0LAB TEST ICMP DROP"}}
```

#### 부수적으로 확인된 것

- **Hyper-V 합성 NIC(`hn0`)에서 netmap 인라인이 동작한다.** H5(Cilium eBPF)와
  같은 부류의 미검증 항목이었고, 이제 둘 다 실측되었다
- **관리 경로가 유지된다.** netmap 은 인터페이스를 가져가므로 LAN 으로 들어오는
  SSH 가 끊길 수 있다. 실측에서는 유지됐으나, 전환 전에 **시리얼 콘솔을
  복구 경로로 먼저 확보**하고 진행했다(§8-32)
- `configctl ids reload` 는 손으로 넣은 룰 파일을 **지운다** —
  `installRules.py` 가 config 에 등록되지 않은 파일을 정리한다.
  `rc.d/suricata restart` 를 쓸 것
- suricata 가 include 하는 YAML 은 `%YAML 1.1` + `---` 로 시작해야 한다.
  없으면 `Invalid configuration file` 로 **기동 자체가 실패**한다

#### 남은 것

- **룰셋 미설치.** 검증용 룰 1개만 있다. ET Open 등은 디스크 여유(530 MB)와
  함께 판단해야 한다 — §8-32 의 디스크 확장 실패 참조
- **Zeek 없음.** 이 저장소에 패키지가 없다
- **ADR-031 로그 파이프라인 미연결.** `eve.json` 은 생성되고 있으나 Logstash 로
  보내지 않았다. WSL2 의 k3s 는 Hyper-V VM 에서 직접 보이지 않아 Windows 를
  경유해야 한다(`setup-l0-lab.ps1` 말미의 portproxy 절차)

### 8-34. ADR-031 로그 파이프라인 — Suricata EVE 가 Elasticsearch 까지 간다 (2026-09-04)

§8-33 에서 차단을 확인한 뒤, 그 이벤트가 SIEM 까지 가는지가 다음 항목이었다.
ADR-031 은 `Suricata EVE JSON · Zeek → Logstash → Wazuh Indexer` 를 말하는데
**Logstash 에 Suricata 입력도 EVE 파싱도 없었다.** 문서에만 있던 상태다.

#### 경로

```
suricata --(syslog_eve, facility local5)--> syslog-ng --(tcp4)--> 10.77.0.190:5140
  --netsh portproxy--> 127.0.0.1:5140 --WSL localhostForwarding-->
  kubectl port-forward --> logstash-0:5140 --> Elasticsearch
```

**검증용 경로다.** WSL2 의 k3s 가 Hyper-V VM 에서 직접 보이지 않아 Windows 를
두 번 경유한다. 클라우드 dev 에서는 OPNsense 가 Logstash 로 곧장 보낸다.

호스트 방화벽 프로파일이 `Public` 이라 인바운드가 막혀 있었다. 포트와 출발지
대역을 좁힌 규칙 하나를 추가했다(`L0-Lab Logstash 5140`, 10.77.0.0/24 한정).

#### 결과

| 인덱스 | 내용 |
|---|---|
| `suricata` | EVE 이벤트. alert·ssh 등 |
| `suricata-engine` | suricata 자체 로그 |

정규화된 alert 문서:

```json
{"alert":{"signature":"L0LAB TEST ICMP DROP","action":"blocked"},
 "event.dataset":"suricata.eve","event.kind":"alert","event.action":"blocked",
 "src_ip":"10.77.0.191","dest_ip":"8.8.8.8","proto":"ICMP",
 "observer.type":"ids","event.module":"suricata"}
```

#### ★ syslog 로 보내면 drop 이벤트가 유실된다

가장 중요한 발견이다. OPNsense 의 `suricata.yaml` 템플릿에서 **파일 출력과
syslog 출력의 `types` 목록이 다르다.**

```yaml
# 파일 출력
types: [alert, anomaly, drop, ssh]
# syslog 출력
types: [alert]
```

즉 `event_type: drop`(그리고 `drop.reason`)은 **syslog 경로로 오지 않는다.**
§8-33 에서 인라인 차단의 최종 근거로 삼았던 바로 그 이벤트다.

차단 여부는 `alert.action == "blocked"` 로 판정해야 한다 — 실측으로 alert
이벤트에 그 필드가 실려 온다. 전용 drop 이벤트가 필요하면 **파일을 직접
읽는 수집기**가 있어야 하는데 OPNsense 에는 filebeat 패키지가 없다.

#### 엔진 로그를 버리지 않고 분리했다

`program("suricata")` 필터는 EVE JSON 뿐 아니라 suricata 자체 로그까지 보낸다.
처음에 14건 중 9건이 `_suricata_no_json` 으로 잡혔다.

버리지 않고 `suricata-engine` 인덱스로 분리했다. **§8-33 에서 조용히 실패한
것이 정확히 이 신호였기 때문이다** — `1 rule files specified, but no rules
were loaded!` 가 여기로 온다. 보안 이벤트와 섞으면 탐지 지표가 오염되고,
버리면 "엔진이 실제로 룰을 들고 떴는가" 를 잃는다.

```json
{"event.dataset":"suricata.engine","event.kind":"event",
 "message":"... Threads created -> W: 2 FM: 1 FR: 1   Engine started."}
```

#### 진단에서 한 번 틀렸다

파드 안 설정에 새 필터가 없다고 판단해 "kubelet 의 ConfigMap 캐시" 로
결론지었다. **틀렸다.** 마운트가 `subPath: pipeline.conf` → `pipeline/logstash.conf`
라서 내가 grep 한 `pipeline/pipeline.conf` 는 존재하지 않는 경로였다.
`grep ... || echo 0` 이 그 실패를 "0건" 으로 바꿔 놓아 없는 것처럼 보였다.

#### NetworkPolicy — 로컬에서는 부재가 드러나지 않는다

`allow-logstash-access` 는 filebeat→5044 만 허용한다. 5140 규칙을 추가했다.

그런데 **로컬 검증만으로는 이 규칙이 없어도 통한다.** port-forward 로 들어오면
출발지가 노드가 되기 때문이다. 클라우드에서 L0 가 직접 보낼 때 조용히 막힌다.
대역(`10.77.0.0/24`)은 환경마다 실제 L0 주소로 좁혀야 한다.

#### 곁가지 — Kafka 입력이 죽어 있다

Logstash 로그에 `Bootstrap broker kafka-headless:9092 disconnected` 가 반복된다.
이 변경과 무관한 **기존 문제**이며, `falco-alerts`·`keycloak-events` 토픽이
Logstash 에 들어오지 않고 있다는 뜻이다. 별도로 다뤄야 한다.

#### 남은 것

- **출력이 Elasticsearch 다.** ADR-031 은 Wazuh Indexer 를 말한다. 현재 구현은
  ES 로 보내며, 이 차이는 이 항목의 범위 밖이다
- **Zeek 없음.** 패키지가 없어 별도 경로가 필요하다
- **룰셋 미설치.** 검증용 룰 1개뿐이다(디스크 여유 530 MB)

### 8-35. Kafka 입력이 죽어 있었다 — 결함 세 개가 겹쳐 있었다 (2026-09-04)

§8-34 작업 중 Logstash 로그에서 발견한 것이다.

```
Bootstrap broker kafka-headless:9092 (id: -1) disconnected
Disconnecting from node -1 due to socket connection setup timeout
```

브로커 장애처럼 보이지만 **Kafka 는 멀쩡했다.** KRaft 스냅샷을 정상 기록 중이고
DNS 도 올바른 파드 IP(`kafka-headless/10.0.0.214:9092`)로 풀렸다.

#### ① NetworkPolicy 에 Logstash 가 없었다

`allow-kafka-access` 의 허용 대상은 `component: application`·`akhq`·
`kafka-bridge`·`openreplay` 넷이었다. **Logstash 가 목록에 없다.**

대조군으로 갈렸다.

| 출발지 | kafka-headless:9092 |
|---|---|
| logstash-0 | **timeout (exit 124)** |
| akhq-0 | **OPEN** |

이 레포에서 NetworkPolicy 누락은 거부가 아니라 **타임아웃**으로 나타난다.
그래서 로그만 보면 브로커·네트워크 문제로 읽힌다. 셀렉터를 추가하니
컨슈머 그룹 `logstash-siem` 이 두 토픽에 파티션을 할당받았다.

#### ② 토픽 조건식의 필드 경로가 틀렸다 — 연결돼도 잘못 쌓인다

연결을 고친 뒤 시험 메시지를 넣었더니 **소비는 되는데 엉뚱한 곳으로 갔다.**

```
인덱스        logstash        ← falco-alerts 가 아니다
event.kind    없음
@timestamp    수신 시각       ← Falco 의 time 이 아니다
```

필터가 `[kafka][topic]` 을 보는데, 입력이 `decorate_events => "basic"` 이면
토픽·파티션·오프셋은 **`[@metadata][kafka][topic]`** 에 들어간다. 경로가
틀리면 조건이 항상 거짓이 되어 falco·keycloak 이벤트가 else 분기로 떨어진다.

**오류는 없다.** 인덱스만 다르고 정규화만 빠진 채 조용히 쌓인다. 즉
①만 고쳤다면 "연결됐다" 를 확인하고 끝냈을 것이고, 데이터는 계속
잘못된 자리에 들어갔을 것이다.

고친 뒤 재확인:

```json
{"_index":"falco-alerts","event.kind":"alert","event.module":"falco",
 "rule":"L0LAB Kafka Route Probe2","priority":"Critical",
 "@timestamp":"2026-09-04T05:00:00.000Z"}
```

#### ③ falcosidekick 이 출력을 하나도 켜지 않고 있었다

토픽 오프셋이 0 이라 생산자를 확인하다 나왔다.

```
[INFO] : Enabled Outputs: []
```

원인은 설정 파일 경로다. 이미지 엔트리포인트는 `/app` 에서 `./falcosidekick`
이고 인자가 없으면 **작업 디렉터리의 `./config.yaml`** 을 찾는데, ConfigMap 은
`/etc/falcosidekick/config.yaml` 에 마운트되어 있었다. **설정이 한 번도 읽히지
않았다** — Elasticsearch 출력도 Kafka 출력도 파일 안에 멀쩡히 있었는데.

증상이 거의 없다는 점이 이 결함의 성질이다. 파드는 Running·Ready 이고
`/ping` 도 응답한다. 단서는 기동 로그 한 줄뿐이다.

`args: ["-c", "/etc/falcosidekick/config.yaml"]` 를 주니:

```
[INFO] : Enabled Outputs: [Elasticsearch Kafka]
```

Kafka 로 나가려면 `allow-kafka-access` 에 falcosidekick 셀렉터도 필요하다.
함께 추가했다.

> 중간에 한 번 틀렸다. `kafka` 절이 없는 줄 알고 추가했는데 파일 아래쪽에
> 이미 있었고, 중복으로 `yaml: unmarshal errors: mapping key "kafka" already
> defined` 가 났다. **역설적으로 그 오류가 설정이 이제 읽힌다는 증거였다.**
> 중복을 지우고 기존 절에 주석만 남겼다.

#### 로컬에서 falco-alerts 가 비는 것은 결함이 아니다

세 결함을 다 고쳐도 로컬에서는 이 토픽에 데이터가 흐르지 않는다.
**Falco 가 의도적으로 스케줄되지 않기 때문이다.**

```
falco DaemonSet: desired 0
nodeSelector: oneinchmarket.local/falco-supported=true   (어떤 노드에도 없다)
```

`overlays/local/patches/falco-local.yaml` 에 사유가 있다 — WSL2 커널에서
modern_ebpf 프로브가 `scap_init` 에 실패한다. ADR-025 가 Tetragon 전환을
제안하고 있고 Tetragon 은 실제로 돌고 있다.

따라서 이 항목의 검증은 **Kafka 에 직접 넣은 메시지**로 했다. 파이프라인
자체(연결·라우팅·정규화)는 증명되었고, dev/prod 처럼 Falco 가 도는 환경에서는
그대로 동작한다.

#### 남은 것

- **`keycloak-events` 에도 생산자가 없다.** Keycloak 에 Kafka 이벤트 리스너
  설정이 매니페스트에 없다. Logstash 는 구독만 하고 있다
- **`trivy-reports` 토픽은 소비자가 없다.** Logstash 가 구독하지 않는다
- **falcosidekick 의 Kafka 임계값이 ES 와 다르다** — Kafka 는 error 이상,
  ES 는 warning 이상. 의도된 것인지 확인되지 않았다

### 8-36. Falco 가 WSL2 에서 안 되는 진짜 이유 — sys_exit 프로그램의 attach 거부 (2026-09-04)

`overlays/local/patches/falco-local.yaml` 에 이렇게 적혀 있었다.

> modern_ebpf 프로브가 WSL2 커널에서 요구 조건을 만족하지 못하는 **것으로 보인다**

추정형으로 쓰여 있었고, 검증해 보니 **틀렸다.**

#### 커널은 조건을 만족한다

| 항목 | 값 |
|---|---|
| 커널 | `6.18.33.2-microsoft-standard-WSL2` (요구 5.8+) |
| BTF | `/sys/kernel/btf/vmlinux` 6.6 MB 존재 |
| 설정 | `CONFIG_BPF_SYSCALL`·`DEBUG_INFO_BTF`·`BPF_JIT`·`BPF_EVENTS`·`FTRACE_SYSCALLS`·`HAVE_SYSCALL_TRACEPOINTS` 전부 `y` |

**결정적 반증은 Tetragon 이다.** 같은 커널에서 CO-RE eBPF 로 돌며 BTF 를 읽고
`generic_kprobe`·`fentry`·`lsm`·`tracepoint` 를 전부 등록한다. 즉 "WSL2 라서
eBPF 가 안 된다" 는 성립하지 않는다.

#### 기록이 가리고 있던 첫 실패는 inotify 였다

노드에 레이블을 붙여 실제로 띄워 보니 **첫 오류가 달랐다.**

```
Error: could not initialize inotify handler
```

```
fs.inotify.max_user_instances = 128
현재 사용 중                  ≈ 145
```

한도를 이미 넘긴 상태였다. **Falco 만의 문제가 아니다** — inotify 를 쓰는 다른
워크로드도 조용히 실패할 수 있었다. `/etc/sysctl.d/99-inotify.conf` 로 1024 로
올려 해소했고, 이 조치는 되돌리지 않았다.

#### 원인을 특정했다 — 검증기가 아니라 attach 단계다

inotify 를 넘기니 여기까지 간다.

```
Opening 'syscall' source with modern BPF probe.
An error occurred in an event source, forcing termination...
Error: Initialization issues during scap_init
```

falco 로그로는 더 나오지 않는다. `log_level=debug` 도 소용없다 — libbpf 메시지가
억제된다. 두 가지로 뚫었다.

**① strace 로 실패한 시스템콜을 특정**

```
bpf(BPF_PROG_LOAD, {prog_type=BPF_PROG_TYPE_TRACING,
                    prog_name="sys_exit",
                    expected_attach_type=BPF_TRACE_RAW_TP,
                    attach_btf_id=28947, insn_cnt=247})
    = -1 EINVAL (Invalid argument)
```

같은 오브젝트의 다른 TRACING 프로그램(insn_cnt 93·95·235·391)은 **전부 정상
적재**되고 `BPF_PROG_BIND_MAP` 까지 성공한다. `sys_exit` 하나만 거부된다.

**② `libs_logger` 로 검증기 로그 확보** — falco 에 `-o libs_logger.enabled=true`
가 있다. 이것이 결정적이었다.

```
libbpf: prog 'sys_exit': -- BEGIN PROG LOAD LOG --
processed 606 insns (limit 1000000) max_states_per_insn 4 total_states 58 ...
-- END PROG LOAD LOG --
libbpf: prog 'sys_exit': failed to load: -22
```

**거부 사유가 한 줄도 없다.** 검증기는 통과했다. 프로그램 로직이 아니라
**attach 검증 단계**의 EINVAL 이다.

#### 커널 기능의 부재가 아니다

| 확인 항목 | 결과 |
|---|---|
| tracepoint | `raw_syscalls/sys_enter`=369 · `sys_exit`=368 · `sched_process_exit`=295 · `signal_deliver`=187 모두 존재 |
| tracefs·debugfs | **둘 다 마운트되어 있다**(이벤트 그룹 125개, tracepoint 2446개) |
| CO-RE 재배치 | 정상. 6.2+ 의 `mm_struct___v6_2` 변종까지 맞춰 잡는다 |
| 다른 프로그램 | 전부 적재 성공 |
| 메모리 | 무관(1Gi 로 올려도 동일, 종료 사유가 `Error`) |

> 앞선 조사에서 "tracefs 가 마운트되어 있지 않다" 고 적었던 것은 **틀렸다.**
> `sudo` 없이 `ls` 해서 권한 거부를 부재로 읽었다.

#### 실제 원인 — 버전 간 비호환

```
Falco 0.39.2 / libs 0.18.2     이미지 latest 가 2024-11-21 이후 미갱신
WSL2 커널  6.18.33.2
```

2024년판 프로브가 2026년판 커널의 raw tracepoint attach 규약을 만족하지 못한다.
`sys_exit` 이 tail call 테이블(`syscall_exit_tail_table`, PROG_ARRAY)을 쓰는
프로그램이라는 점이 다른 프로그램과의 차이다.

#### 고칠 수 없다 — 그 이유도 확인했다

- **더 새 Falco 가 없다.** `falcosecurity/falco-no-driver` 의 최신 태그가 0.39.2 다
- **레거시 eBPF 프로브·kmod 는 커널 헤더를 요구하는데 없다.**
  `/lib/modules/$(uname -r)/build` 부재, `linux-headers` 패키지 후보도 없다.
  Microsoft 의 WSL2 커널 소스를 받아 빌드하는 길은 남아 있으나 아래를 보면
  균형이 맞지 않는다

#### 결론 — 못 쓰는 것은 맞지만 막다른 길은 아니다

로컬에서 Falco 는 여전히 뜨지 않는다. 그러나 이유는 "WSL2 의 eBPF 한계" 가
아니고, 그리고 **런타임 탐지가 없는 것도 아니다.** ADR-025 가 제안한 Tetragon 이
이 커널에서 실제로 동작한다. 구현체가 다를 뿐이다.

실측 후 클러스터는 원상 복구했다 — 노드 레이블 제거(`desired 0`), 임시로 넣은
DaemonSet 인자 제거. **inotify 상향만 남겼다**(그것은 Falco 와 무관하게 옳다).

#### 교훈

추정을 단정처럼 남기면 다음 사람이 그 지점을 다시 파지 않는다. 이 항목은
**두 개의 실패가 겹쳐 있었고 기록은 두 번째만 언급**하고 있었다. 첫 번째는
훨씬 사소하고 훨씬 넓게 영향을 주는 것이었다.

두 번째로, 로그가 없다고 원인을 못 찾는 것이 아니다. falco 는 libbpf 메시지를
억제하지만 `-o libs_logger.enabled=true` 가 그것을 열어 준다. 그 한 줄이
"규명 불가" 와 "attach 단계 EINVAL, 검증기는 통과" 를 갈랐다.


### 8-37. filebeat 인덱스 93 GB — 권한 오류 하나가 만든 증폭 루프 (2026-09-04)

§8-34 작업 중 ES 인덱스 목록을 보다 걸린 것이다.

```
.ds-filebeat-9.5.2-* × 5   약 9.7억 건 · 93.6 GB
ES 인덱스 총계             91.4 GB
```

3일치로는 초당 3,750건이다. 로컬 랩에서 나올 수 없다.

#### 추적 — 최근 10분에 804만 건

```
최근 10분 유입 : 8,045,007 건   (≈ 13,400/s)
```

문서 한 건을 열어 보니 출처가 바로 나왔다.

```json
{"log":{"file":{"path":"/var/log/containers/postgresql-0_local_postgresql-....log"}},
 "stream":"stderr",
 "message":"... ERROR:  permission denied for schema spots at character 37"}
```

#### 원인 — 이전 작업의 잔재

```
public         owner=openreplay   acl 정상
spots          owner=postgres     acl 없음
events         owner=postgres     acl 없음
events_common  owner=postgres     acl 없음
```

OpenReplay 를 전용 PG 17 에서 공유 18.6 으로 옮길 때(§8 앞부분) `public` 의
테이블만 재지정하고 **이 세 스키마를 빠뜨렸다.** 테이블 17개 + 인덱스 102개가
`postgres` 소유로 남아 있었다.

증폭한 것은 클라이언트 쪽이다. 실패하던 쿼리는 폴링 워커의 것이다.

```sql
SELECT spot_id, crop, duration FROM spots.tasks
WHERE status = 'pending' ORDER BY added_time FOR UPDATE SKIP LOCKED LIMIT ...
```

권한 거부 → 즉시 재시도 → 초당 1만 건. **백오프가 없다.**

#### 조치 ① 소유권 정정

세 스키마와 그 안의 객체를 `openreplay` 로 넘겼다. 두 가지를 제외했다 —
확장(extension) 소속 객체(`pg_depend deptype='e'`)는 소유자를 바꾸면 확장이
깨지고, identity/serial 시퀀스(`'a'`,`'i'`)는 테이블에 종속되어 직접 바꾸면
`cannot change owner of sequence` 가 난다.

결과가 즉시 나왔다.

| | 분당 filebeat 유입 |
|---|--:|
| 조치 전 | 604,244 |
| 조치 후 | **906** |

**667배** 감소. PostgreSQL 로그도 checkpoint 만 남는 정상 상태로 돌아왔다.

#### 조치 ② 재발 방지 — bootstrap 의 `ensure()`

매니페스트에는 결함이 없었다. OpenReplay 마이그레이션 Job 의 `PGUSER` 는
`openreplay` 로 올바르게 설정되어 있다(base64 확인). **드리프트는 수동 개입의
결과**였다 — 이전 이설 때 `init_schema.sql` 을 superuser 로 적용했다.

그래서 `ensure()` 에 **멱등한 소유권 정규화**를 넣었다. 기존 `GRANT ALL ON
SCHEMA public` 은 public 만 다루므로, 앱이 자체 마이그레이션으로 만든 스키마는
사각지대였다. 이제 그 DB 안의 모든 비시스템 스키마·객체를 앱 롤 소유로 맞춘다.

#### 조치 ③ 보존 정책 — 이게 진짜 구조적 결함이었다

오류가 없었더라도 filebeat 데이터는 **영원히 쌓인다.**

```
ILM 정책 "filebeat" (filebeat 이 스스로 만든 기본값)
  hot    : rollover 30d / 50gb
  delete : ** 없음 **
```

레포의 `oneinchmarket-ilm` 은 hot/warm/delete(30d) 로 제대로 되어 있는데,
**filebeat 은 그것을 쓰지 않고 자기 정책을 쓴다.** 인덱스 템플릿 4종
(logstash·falco-alerts·keycloak-events·trivy-reports)만 우리 정책을 참조한다.

`elasticsearch-ilm-setup` Job 이 `filebeat` 정책도 만들도록 했다
(rollover 1d/10gb + delete 7d). filebeat 은 정책이 이미 있으면 덮어쓰지
않으므로(`setup.ilm.overwrite` 기본 false) 이 값이 유지된다.

적용 후 백킹 인덱스 5개가 모두 `hot`(나이 8.5시간~1.01일)이고 7일 뒤 삭제된다.
**93 GB 를 손으로 지우지 않았다** — 기제를 고쳤으므로 저절로 소멸한다.

#### 이 항목의 성질

세 층이 겹쳐 있었다.

1. **소유권 드리프트** — 이전 작업의 잔재. 조용하지 않았지만 아무도 로그를 보지 않았다
2. **백오프 없는 폴링** — 오류를 초당 1만 건으로 증폭
3. **보존 정책 부재** — 그 결과를 무한히 보관

①만 고치면 증상은 멎지만 ③은 남는다. ③만 고치면 93 GB 가 주기적으로 다시 쌓인다.

### 8-38. LDAP 동기화가 root DN 을 들고 있었다 (2026-09-04)

`keycloak-events` 토픽의 목적을 확인하다 나온 것이다. 원래 의도는 SIEM 이 아니라
**Keycloak 사용자를 Knox·Ranger 로 동기화**하는 것이었고, "LDAP 이 취약해서
Kafka 이벤트를 고려했다" 는 판단이 함께 있었다.

#### 그 판단을 검토했다 — 절반은 맞고 절반은 뒤집힌다

**맞는 절반.** 이 레포의 LDAP 설정은 실제로 취약했다.

```
SYNC_LDAP_URL     = ldap://ds389-headless:3389    평문
SYNC_LDAP_BIND_DN = cn=Directory Manager          389-DS 의 root DN
```

읽기만 하는 폴링 클라이언트가 **디렉터리 서버의 최고 권한**을 들고 있었다.
`ranger-usersync` 파드가 뚫리면 디렉터리를 쓰기 권한까지 통째로 잃는다.

**뒤집히는 절반.** Kafka 는 그 문제의 해답이 아니다.

| | LDAP 경로 | Kafka 경로 |
|---|---|---|
| 암호화 **가능** 여부 | **가능** — DS389 가 3636(LDAPS)을 듣고 있다(실측) | **불가** — `PLAINTEXT://:9092` 리스너뿐 |
| 인증 | bind DN 있음 | **없음** (SASL 미설정) |
| 데이터 잔존 | 질의 시점만 | **토픽에 보존·재생 가능** |
| 접근 범위 | bind DN 의 ACI | 토픽 읽기 권한자 전원 |

게다가 v1 설정이 `KC_ADMIN_EVENTS_DETAILS_ENABLED=true` 였다. 사용자 속성이
이벤트에 실려 토픽에 남고, Logstash 를 타고 Elasticsearch 로 색인된다 —
신원 정보의 검색 가능한 사본이 하나 더 생긴다.

메시 계층도 보호막이 아니다. `local` 네임스페이스에 `istio.io/dataplane-mode`
레이블이 없어 **ambient 에 편입되어 있지 않고** PeerAuthentication 은
`PERMISSIVE` 다. 두 경로 모두 평문으로 흐른다.

**즉 LDAP 이 취약한 것이 아니라 이 LDAP 설정이 취약했다.**

#### 조치 — 읽기 전용 바인드 계정

`ds389-bootstrap` 이 `uid=ranger-sync,ou=people,...` 를 만들고 ACI 로
`read,search,compare` 만 허용한다. `write`·`delete` 는 주지 않는다.

`ranger-usersync` 의 `LDAP_BIND_PASSWORD` 를 `ds389-secret/dm-password` 에서
`sync-password` 로 바꿨다. 키 이름이 다르므로 **없으면 파드가 기동하지 않는다** —
조용히 root 자격으로 되돌아가는 것보다 낫다.

#### 검증한 것

```
쓰기 시도 : exit 50 (LDAP_INSUFFICIENT_ACCESS)   ← 거부됨
읽기      : 2건                                   ← 정상
파드 안 install.properties:
  SYNC_LDAP_BIND_DN = uid=ranger-sync,ou=people,dc=oneinchmarket,dc=co,dc=kr
usersync 기동 로그:
  [I] ranger.usersync.ldap.ldapbindpassword property is verified.
```

최소권한이 가정이 아니라 **실측으로 확인된다.**

#### 검증하지 못한 것

**사용자가 Ranger DB 까지 도달하는지는 확인하지 못했다.** 두 가지 이유이며
둘 다 이 변경 이전부터 있던 상태다.

- DS389 에 스모크 픽스처 2건(`oim-svc`, `ranger-sync`)뿐이라 동기화할 실체가 없다
- Ranger admin API 가 401 을 돌려준다 — `ranger-secret/admin-password` 가 실제
  admin 비밀번호와 맞지 않는다. **별도 항목이다**

즉 이 변경은 **자격을 낮춘 것이고 기능을 바꾸지 않았다.** 회귀는 없으나
"동기화가 원래 되고 있었는지" 는 여전히 미확인이다.

#### 남은 것 — LDAPS

전송 암호화는 아직 평문이다. DS389 는 3636 을 듣고 있으나 두 가지가 걸린다.

```
subject: CN=ds389-0.ds389-headless.local.svc.cluster.local
issuer : CN=ssca.389ds.example.com    ← dscontainer 자체 서명 CA
```

- **신뢰**: 자체 서명 CA 라 usersync(Java)의 트러스트스토어에 넣어야 한다
- **호스트명**: 인증서 CN 이 파드 FQDN 이라 `ds389-headless` 로 접속하면 불일치한다.
  네임스페이스가 CN 에 박혀 있어 오버레이 이식성도 깨진다

레포에 이미 cert-manager 패턴이 있다(`wazuh-certs.yaml` — selfsigned Issuer →
CA → 노드 인증서). 같은 방식으로 SAN 을 갖춘 인증서를 발급하는 것이 옳다.

#### keycloak-events 는 지우지 않는다

용도가 갈린다. **상태 동기화는 원천(디렉터리)이 맡고, 감사는 이벤트가 맡는다.**
Logstash 가 이미 이 토픽을 SIEM 으로 소비하고 있으므로(§8-35) 그대로 둔다.
`argocd/events/` 의 센서는 스텁이고 Argo Events 자체가 설치되어 있지 않다 —
정리 대상이지만 감사 경로와 무관하므로 별도로 판단한다.

### 8-39. ambient 편입 시도 — 되돌리기가 편입보다 위험했다 (2026-09-04)

> ★ 이 항목의 결론은 틀렸다. §8-40 이 방향을 잡고 §8-41 이 원인을 특정한다 —
> 우리 default-deny 가 Istio 의 헬스 프로브와 HBONE 포트를 막고 있었다. mTLS 는 동작하고
> 있었고 막힌 것은 kubelet 헬스 프로브였다.

§8-38 에서 LDAP 전송 암호화를 검토하다 막혔다. 경로마다 TLS 를 붙이는 방식이
각각 벽에 부딪혔다.

- **LDAP** — DS389 의 자동 생성 인증서는 SAN 이 하나이고
  `ds389-0.ds389-headless.local.svc.cluster.local` 로 **네임스페이스가 박혀 있다.**
  base 매니페스트가 담을 수 없다. 이식 가능하게 만들려면 cert-manager 인증서를
  NSS DB 에 임포트해야 하는데, DS389 는 기동이 까다로운 컴포넌트다
- **Kafka** — `PLAINTEXT` 리스너뿐이다. TLS 를 얹으면 OpenReplay·AKHQ·
  kafka-bridge·Logstash 를 전부 함께 고쳐야 한다

그래서 ambient 로 한 번에 덮으려 했다. 근거는 있었다.

```
istiod · ztunnel · istio-cni-node   전부 Running (설치는 되어 있고 편입만 안 됨)
PeerAuthentication                  PERMISSIVE  (양쪽 편입 시에만 mTLS)
hostNetwork 파드                     없음        (ambient 제외 대상 없음)
```

**애플리케이션 설정을 하나도 건드리지 않고** 레이블 한 줄로 LDAP·Kafka·
PostgreSQL·ES 를 함께 덮는다 — 레버리지가 압도적으로 좋아 보였다.

#### 편입 결과 — OpenReplay 9개가 무너졌다

```
Ready 79 → 70
CrashLoopBackOff : http-openreplay, sink-openreplay
Error            : integrations-openreplay
0/1 Running      : api, canvases, db, ender, images, spot
로그             : "i/o timeout"
```

전부 OpenReplay 의 수집 계층이고 Kafka 를 많이 쓰는 것들이다. 반면 같은 시점에
`logstash → kafka:9092` 와 `usersync → ds389:3389` TCP 프로브는 성공했다.
**모든 트래픽이 깨진 것이 아니라 특정 통신 양상이 깨졌다.** 정확한 기제는
규명하지 못했다 — ztunnel 로그·패킷 수준 조사가 필요하다.

#### 더 중요한 발견 — 되돌리기가 더 넓게 흔들었다

레이블을 지우자 상황이 **악화**됐다.

```
편입 후    Ready 70 / 79
되돌린 직후 Ready 43 / 79   ← postgresql·minio·mariadb·keycloak·vault·gitlab·
                              logstash·loki·grafana·knox 까지 readiness 상실
+30초      69 / 79
+60초      76 / 79
+120초     79 / 79          ← 자력 회복
```

데이터플레인이 붙었다 떨어지며 **기존 연결이 끊긴** 것으로 보인다. 대부분
크래시가 아니라 `0/1 Running`(readiness 실패)이었고 재연결로 회복했다.

**"되돌릴 수 있다" 가 "되돌리는 것이 무해하다" 를 뜻하지 않는다.** 이번에는
3분 만에 자력 회복했으나, 그 3분 동안 데이터 계층 전체가 준비 상태를 잃었다.
운영 환경이었다면 그 자체가 장애다.

#### 판단

레이블 한 줄이라는 점이 위험을 과소평가하게 만들었다. 변경의 **크기**와 변경의
**범위**는 다르다 — 이 한 줄은 파드 110개의 데이터플레인을 바꾼다.

다시 시도한다면 네임스페이스 전체가 아니라 **파드 단위로 좁혀** 들어가야 한다.
ambient 는 `istio.io/dataplane-mode` 를 파드 레이블로도 받으므로, OpenReplay 를
제외한 채 LDAP·Kafka 경로의 양끝(usersync·ds389·logstash·kafka)만 편입하는
것이 가능하다. 그러면 실패 반경이 4개 파드로 줄고 되돌리기도 그 범위에 그친다.

#### 그래서 LDAPS 는 아직 미해결이다

§8-38 의 "남은 것" 이 그대로 남는다. 선택지는 셋이고 각각 대가가 있다.

| | 내용 | 대가 |
|---|---|---|
| cert-manager + NSS 임포트 | 정공법·이식 가능 | DS389 부팅 경로를 건드린다 |
| local 한정 CA 고정 | 지금 이 경로만 암호화 | 이식 불가, PVC 재생성에 깨짐 |
| ambient 파드 단위 편입 | 앱 설정 무변경 | 위 실패의 축소판을 다시 겪을 수 있다 |

**root DN 제거(§8-38)는 유지된다.** 전송 암호화만 미해결이며, 두 문제 중
자격 권한 쪽이 더 심각했다는 점은 변하지 않는다.

### 8-40. ambient 재조사 — mTLS 는 되고 있었다. 막힌 것은 헬스 프로브다 (2026-09-04)

§8-39 는 "ambient 편입이 OpenReplay 를 무너뜨렸다" 로 끝났다. **그 결론은
불완전했다.** 파드 단위로 좁혀 다시 들어가 원인을 특정했다.

#### mTLS 는 실제로 동작하고 있었다

네임스페이스 편입 시점의 ztunnel 접속 로그다.

```
src.identity="spiffe://cluster.local/ns/local/sa/gitlab"
dst.addr=10.0.0.49:15008  dst.hbone_addr=10.0.0.49:6379
dst.identity="spiffe://cluster.local/ns/local/sa/redis"
```

SPIFFE 신원이 양쪽에 붙고 HBONE 터널(15008)을 탄다. **원하던 전체 전송 암호화가
그 시점에 이미 성립하고 있었다.** inbound 방향도 13 KB 를 정상 전달한 기록이 있다
(safeline-luigi → safeline-detector:8001).

#### 막힌 것은 kubelet 헬스 프로브였다

파드 단위로 하나씩 편입해 보니 상관관계가 100% 로 갈렸다.

| 파드 | readiness 프로브 | 편입 결과 |
|---|---|---|
| http·sink·integrations·api-openreplay | `httpGet` | **깨짐** |
| ds389 | `tcpSocket` | **깨짐** |
| ranger-usersync | **`exec`** | **정상** |

ds389 가 결정적이었다. 파드 **안에서는** LDAP 이 정상이다.

```
DS389 로그 : slapd started. Listening on All Interfaces port 3389
파드 내부  : ldapsearch localhost:3389 → 2건 정상
kubelet    : Startup probe failed: dial tcp 10.0.0.69:3389: i/o timeout
```

서버는 멀쩡한데 **밖에서 들어오는 프로브만** 실패한다. 그래서 파드가 영원히
Ready 가 되지 못하고, OpenReplay 는 CrashLoop 까지 갔다.

`ranger-usersync` 는 프로브가 `exec`(프로세스 생존)라서 무사했다. 편입 상태로
정상 동작했고, ztunnel 로그가 그 증거다 —
`ranger-usersync → ds389-0:3389` 와 `→ ranger-admin-0:6080` 이 모두 흘렀다.

> 덤으로 §8-38 의 미확인 항목이 풀렸다. usersync → ranger-admin:6080 연결이
> 65초 동안 7424 바이트를 받았다. **동기화는 실제로 돌고 있다.**

#### ADR-043 의 전제는 전부 충족되어 있었다

```
M1  bpf-lb-sock-hostns-only : true    ✓
M2  cni-exclusive           : false   ✓
M3  istio-cni DaemonSet     : Running ✓
```

CNI 체이닝도 정상이다 — `05-cilium.conflist` 안에 `cilium-cni` 와 `istio-cni`
(`ambient_enabled: true`)가 함께 들어 있다.

**즉 ADR-043 이 필수라고 적은 세 가지를 다 지켜도 이 실패는 일어난다.**
ADR-043 은 M1 의 실패 모드로 "조용한 보안 우회"(통신은 되는데 mTLS 만 안 걸림)를
경고하는데, 여기서 관측된 것은 **정반대**다 — mTLS 는 걸리고 헬스 프로브가 막힌다.
ADR-043 에 이 실패 모드를 추가해야 한다.

> 조사 중 "Cilium 이 istio-cni 의 conflist 를 지웠다"고 한 번 결론 냈다가
> 철회했다. `cni-exclusive` 는 `false` 였고 체이닝은 멀쩡했다.

#### 정확한 원인은 규명하지 못했다

ambient 는 kubelet 프로브를 리다이렉션에서 제외하도록 되어 있다(출발지가 노드 IP).
이 클러스터에서 그 제외가 동작하지 않는다. 후보는 Cilium 의 데이터패스가
프로브 트래픽의 출발지 주소를 바꾸는 경우인데 **확인하지 못했다.**

#### 그래서 지금 할 수 있는 것

전체 전송 암호화는 **불가능한 것이 아니라 프로브 문제 하나에 막혀 있다.**

| | 내용 | 대가 |
|---|---|---|
| 프로브 제외 원인 규명 | 정공법 | istio-cni·Cilium 데이터패스 조사 필요 |
| `exec` 프로브로 전환 | 실증됨(usersync) | 워크로드마다 프로브를 다시 써야 한다 |
| 아웃바운드 전용 파드만 편입 | 즉시 가능 | 양쪽 편입이 아니면 mTLS 가 안 된다 |

**되돌리기의 위험(§8-39)은 그대로 유효하다.** 편입·해제 모두 기존 연결을
끊으므로, 다음 시도도 파드 단위로 좁혀서 해야 한다.

### 8-41. ambient 를 막고 있던 것은 우리 NetworkPolicy 두 줄이었다 (2026-09-04)

§8-40 은 "kubelet 헬스 프로브가 막힌다, 원인은 규명하지 못했다" 로 끝났다.
규명했고, 고쳤다. **전체 전송 암호화가 열렸다.**

#### 추적 — 시험 파드 하나로 격리 재현

기존 워크로드를 건드리지 않고 `tcpSocket` 프로브를 가진 nginx 파드 하나를
ambient 로 띄웠다. 그대로 재현됐다.

```
ambient-probe-test  0/1 Running
Readiness probe failed: dial tcp 10.0.0.94:80: i/o timeout
```

파드 netns 의 리다이렉션 규칙을 직접 읽었다(`nsenter -t <pid> -n iptables -S`).

```
-A ISTIO_PRERT -s 169.254.7.127/32 -p tcp -j ACCEPT        ← 인바운드 예외는 이것뿐
-A ISTIO_PRERT ! -d 127.0.0.1/32 -p tcp ! --dport 15008 ... -j REDIRECT --to-ports 15006
```

`169.254.7.127` 은 Istio 가 **프로브 트래픽을 표시하려고 SNAT 하는 링크로컬
주소**다. 호스트 쪽 규칙도 있었고 **실제로 매칭되고 있었다**.

```
-A ISTIO_POSTRT -p tcp -m owner --socket-exists \
   -m set --match-set istio-inpod-probes-v4 dst -j SNAT --to-source 169.254.7.127
   pkts 683  bytes 40980      ← 카운터가 올라간다
```

SNAT 은 되는데 nginx 액세스 로그에는 연결 기록이 없다. 그 사이에서 사라진다.

#### 범인 — Cilium 이 떨어뜨리고 있었다

```
xx drop (Policy denied) ... file bpf_lxc.c:2067
   identity world->6594: 169.254.7.127:41884 -> 10.0.0.94:80 tcp SYN
```

사슬이 완성된다.

1. kubelet 이 파드 IP 로 프로브한다
2. Istio 가 출발지를 `169.254.7.127` 로 SNAT 한다
3. **Cilium 은 그 링크로컬 주소에 대응하는 신원이 없어 `world` 로 분류한다**
4. **우리 `default-deny-ingress` 가 `world → 파드` 를 거부한다**
5. 드롭

**즉 ambient 를 막고 있던 것은 Istio 도 Cilium 도 아니고 우리 정책이었다.**

#### 두 번째 벽 — HBONE 포트도 막혀 있었다

프로브를 뚫고 양쪽을 편입하니 ztunnel 이 다음 문제를 **직접 말해줬다.**

```
error="connection timed out, maybe a NetworkPolicy is blocking
       HBONE port 15008: deadline has elapsed"
```

ambient 의 mTLS 는 파드→파드 직통이 아니라 **양쪽 ztunnel 이 15008 로 맺는
터널** 위를 흐른다. 원래 포트(3389·9092…)를 여는 기존 정책들은 이 포트를
다루지 않는다.

신원 협상은 이미 성립한 상태라 오해하기 쉽다 —
`src.identity=.../sa/ranger-usersync`, `dst.identity=.../sa/ds389` 가 찍히는데
연결만 안 된다. "인증서 문제" 로 읽힌다.

#### 조치 — `default-deny.yaml` 에 정책 두 개

```
allow-istio-health-probes : ipBlock 169.254.7.127/32
allow-istio-hbone         : podSelector {} · TCP 15008
```

둘 다 범위가 좁다. 전자는 클러스터 밖에서 라우팅되지 않는 링크로컬 단일
주소이고, 후자는 ztunnel 만 듣는 포트이며 HBONE 은 mTLS 를 요구하므로 신원
없는 상대는 통과하지 못한다. ambient 를 쓰지 않는 환경에서는 매칭되는
트래픽이 없어 무해하다 — 그래서 base 에 둔다.

#### 결과 — LDAP 이 mTLS 로 흐른다

```
src.identity = spiffe://cluster.local/ns/local/sa/ranger-usersync
dst.identity = spiffe://cluster.local/ns/local/sa/ds389
dst.addr     = 10.0.0.44:15008   hbone_addr = 10.0.0.44:3389
direction    = inbound · outbound 모두 성공, 오류 없음
```

§8-38 이 남긴 "전송 암호화 미해결" 이 해소되었다. **LDAPS 없이** 해결됐다는
점이 중요하다 — DS389 의 NSS DB 를 건드리지 않았고 인증서 수명도 관리하지
않는다. 애플리케이션 설정은 한 줄도 바뀌지 않았다.

`ds389` 와 `ranger-usersync` 파드 템플릿에 `istio.io/dataplane-mode: ambient`
를 넣었다. 클러스터 Ready 79/79.

#### 세 번의 오진을 남겨 둔다

| 시점 | 결론 | 실제 |
|---|---|---|
| §8-39 | "ambient 가 OpenReplay 와 호환되지 않는다" | 아니다 |
| §8-40 | "kubelet 프로브가 막힌다. 원인 불명" | 방향은 맞았다 |
| 조사 중 | "Cilium 이 istio-cni conflist 를 지웠다" | 아니다. 체이닝은 정상이었다 |
| §8-41 | **우리 default-deny 가 프로브와 HBONE 을 막고 있었다** | 확인됨 |

첫 결론에서 멈췄다면 "ambient 는 이 클러스터에서 못 쓴다" 로 남았을 것이다.
**증상을 컴포넌트 탓으로 돌리기 전에 우리 설정을 의심했어야 했다** — 이 레포에서
NetworkPolicy 누락이 타임아웃으로 나타난 것이 오늘만 세 번째다(§8-35 Kafka,
§8-34 Logstash, 그리고 이번).

#### 남은 것

전체 네임스페이스 편입은 아직 하지 않았다. 두 정책이 생겼으니 §8-39 의
실패는 재현되지 않을 가능성이 높지만, **되돌리기가 편입보다 위험했다는 사실은
그대로다.** 확대는 파드 단위로 계속하는 편이 안전하다.

### 8-42. ambient 확대의 한계 — 공유 서버는 클라이언트와 함께 편입해야 한다 (2026-09-04)

§8-41 로 LDAP 경로가 mTLS 로 열렸다. 같은 방식으로 Kafka 경로를 넓히려다
**구조적 제약**을 만났다.

#### kafka·logstash 를 편입했더니

파드는 둘 다 `1/1 Running` 이 되었다(§8-41 의 정책 두 개 덕분에 프로브는
통과한다). **그런데 기능이 깨졌다.**

```
logstash → kafka : error="http status: 401 Unauthorized"
cmmn-api → kafka : "connection closed due to policy rejection:
                    allow policies exist, but none allowed"
컨슈머 그룹       : CONSUMER-ID 가 '-'  (소비자 미접속)
```

파드 상태만 보면 정상이다. **Ready 79/79 였다.** 기능 확인을 하지 않았으면
"성공" 으로 넘어갔을 것이다.

#### 원인 — ztunnel 이 NetworkPolicy 를 L4 인가로 강제한다

서버 파드를 편입하면 그 파드로 들어오는 **모든** 연결이 ztunnel 을 지나고,
ztunnel 이 NetworkPolicy 를 인가 규칙으로 적용한다. 편입되지 않았거나 정책이
허용하지 않는 클라이언트는 거부된다.

LDAP 은 이 문제를 겪지 않았다. **양쪽 끝이 둘뿐**이고 둘 다 편입했기 때문이다.

Kafka 는 다르다. 클라이언트가 OpenReplay 10여 개·AKHQ·kafka-bridge·cmmn-api·
logstash 로 열댓 개다. 그중 하나라도 빠지면 그 클라이언트가 끊긴다.

#### 그래서 확대 규칙이 이렇게 된다

| 대상 | 안전한가 |
|---|---|
| 잎 클라이언트(아웃바운드 전용) | **예** — 하나씩 넣어도 된다 |
| 2자 경로(양끝만 존재) | **예** — 둘을 함께 넣는다 (LDAP 사례) |
| 공유 서버(클라이언트 다수) | **아니오** — 클라이언트 전부와 **동시에** 넣어야 한다 |

Kafka·PostgreSQL·Redis·Elasticsearch 처럼 클라이언트가 많은 것은 결국
**네임스페이스 단위 편입**과 다를 바 없어진다. 그리고 그 경로에는 §8-39 의
"되돌리기가 편입보다 위험하다" 가 그대로 적용된다.

#### 곁가지 — logstash 가 default 서비스어카운트를 쓴다

ztunnel 로그에서 드러났다.

```
src.identity="spiffe://cluster.local/ns/local/sa/default"
```

ambient 에서 **워크로드 신원은 ServiceAccount** 다. `default` 를 쓰면 같은
네임스페이스의 다른 `default` 워크로드와 신원이 구분되지 않는다. mTLS 를
인가에 쓰려면 전용 SA 가 필요하다. 별도 항목으로 남긴다.

#### 결론

전송 암호화를 **전면 적용**하려면 네임스페이스 단위로 가야 하고, 그러려면
§8-39 의 위험을 감수해야 한다. §8-41 의 정책 두 개가 생겼으므로 그때의 실패
원인(프로브·HBONE 차단)은 해소되었으나, **클라이언트 다수를 동시에 전환하는
데서 오는 위험은 남아 있다.**

현재 편입 상태로 유지하는 것은 LDAP 경로(`ds389` · `ranger-usersync`)뿐이다.

### 8-43. Ranger 관리자 자격 — 관리되고 있었다 (2026-09-04)

> ★ 이 항목의 처음 결론("아무도 로그인할 수 없다")은 **틀렸다.** 맨 아래 정정을 볼 것.

§8-38 에서 "동기화가 Ranger 까지 닿는지 확인 못 했다" 고 적은 이유가 이것이었다.
API 가 401 을 돌려준다.

#### 먼저 — 동기화는 되고 있었다

Ranger DB 를 직접 조회해 확인했다.

```
x_portal_user
  1 | admin           | 1
  2 | rangerusersync  | 1
  3 | keyadmin        | 1
  4 | rangertagsync   | 1
  5 | oim-svc         | 1     ← DS389 픽스처
  6 | ranger-sync     | 1     ← DS389 픽스처
```

**`oim-svc` 와 `ranger-sync` 가 들어와 있다.** DS389 → usersync → Ranger 경로가
실제로 동작한다. §8-41 의 ztunnel 로그(usersync → ranger-admin:6080, 7424 바이트)
에 이은 두 번째 증거이고, 이번 것은 결과물 자체다.

#### 401 의 원인 — 자격이 어디에도 없다

```
ranger-secret 의 키           : db-password 하나뿐
ranger-admin 의 env           : POSTGRES_PASSWORD · RANGER_DB_PASSWORD 뿐
install.properties            : rangerAdmin_password=   (빈 값)
기동 로그                     : "Ranger all admins default password has already been changed!!"
기본 자격 시도                : admin:admin → 401,  admin:rangerR0cks! → 401
```

Ranger 는 첫 설치 때 관리자 비밀번호를 기본값에서 바꿨다고 말하는데, **무엇으로
바꿨는지는 레포 어디에도 없다.** 매니페스트가 그 값을 주지 않으므로 설치
스크립트가 만든 값이고, 기록되지 않았다.

#### 이것이 뜻하는 것

- **Ranger UI·API 에 로그인할 수 없다.** 정책을 만들 수도, 조회할 수도 없다
- 동기화된 사용자·그룹을 확인하려면 **DB 를 직접 봐야 한다**(이 항목이 그렇게 했다)
- 자동화(정책 as code, CI 검증)를 붙일 접점이 없다

usersync 는 별도 자격(`rangerusersync`)으로 Ranger 에 붙으므로 **동기화 자체는
영향을 받지 않는다.** 막힌 것은 사람과 도구의 접근이다.

#### 고치려면

`rangerAdmin_password` 를 Secret 에서 주입하고 Ranger 설치를 다시 태워야 한다.
이미 초기화된 인스턴스라 값만 바꿔서는 반영되지 않는다 — `setup.sh` 재실행
또는 `x_portal_user.password` 직접 갱신이 필요하고, 후자는 Ranger 버전별
해시 방식에 의존해 깨지기 쉽다.

**이 항목에서는 고치지 않았다.** Ranger 재구성이 따르는 별건이며, 동기화가
멈추지 않는다는 점에서 급하지 않다. 다만 **정책을 쓸 수 없는 정책 엔진**은
장기적으로 의미가 없으므로 남겨 둔다.

> `ranger-secret` 에 `admin-password` 키가 있을 것으로 보고 조회했다가 401 을
> 받은 것이 §8-38 의 "확인 못 함" 이었다. 키 자체가 없었다.

#### ★ 정정 (2026-09-04) — 결함이 아니었다. 자격은 관리되고 있다

위 결론은 **틀렸다.** 엔트리포인트 `/home/ranger/scripts/ranger.sh` 를 읽고
알았다.

```bash
echo "rangerAdmin_password=${RANGER_DB_PASSWORD}"
echo "rangerTagsync_password=${RANGER_DB_PASSWORD}"
echo "rangerUsersync_password=${RANGER_DB_PASSWORD}"
echo "keyadmin_password=${RANGER_DB_PASSWORD}"
```

**관리자 비밀번호는 `RANGER_DB_PASSWORD`**, 즉 `ranger-secret/db-password` 다.
확인했다.

```
admin : ranger-secret/db-password  ->  200
사용자 목록: admin · rangerusersync · rangertagsync · oim-svc · ranger-sync
```

`oim-svc`·`ranger-sync` 가 API 로도 보인다 — 동기화 확인의 세 번째 증거다.

**로그인 명령**

```bash
kubectl -n local get secret ranger-secret -o jsonpath='{.data.db-password}' | base64 -d
# 사용자명은 admin
```

##### 왜 틀렸는가

`ranger-secret` 에 `admin-password` 라는 키가 있을 것으로 **가정하고** 조회했다.
없으니 빈 문자열이 되었고 401 이 돌아왔다. 거기서 "자격이 관리되지 않는다" 로
건너뛰었다. **키가 없다는 것과 자격이 없다는 것은 다른 이야기인데** 확인하지
않았다. 엔트리포인트를 읽었으면 5분이면 알 일이었다.

##### 그래도 남는 진짜 문제 — 하나의 비밀번호가 다섯 곳에 쓰인다

```
db_password              (PostgreSQL 접속)
rangerAdmin_password     (관리자 UI·API)
rangerTagsync_password
rangerUsersync_password
keyadmin_password
```

전부 같은 값이다. 즉

- **DB 자격이 곧 관리자 자격이다.** PostgreSQL 접속 문자열이 새면 정책 엔진의
  관리자 권한까지 함께 샌다
- **회전이 불가능하다.** 하나를 바꾸려면 다섯을 함께 바꿔야 하고, 그중 일부는
  이미 초기화된 인스턴스라 install.properties 수정만으로는 반영되지 않는다
- 최소권한 관점에서 `keyadmin`(KMS 키 관리)까지 같은 값인 것이 특히 나쁘다

이것은 이미지 엔트리포인트가 정한 것이라 매니페스트로 고칠 수 없다.
`ranger-admin-install.properties` 를 우리 것으로 덮어쓰는(ConfigMap 마운트)
작업이 필요하며, 별도 항목으로 남긴다.

##### `authentication.method=UNIX` 는 별개 사안이다

`ranger-admin-site.xml` 은 `UNIX` 로 되어 있고 unixauth 서비스(5151)는 돌지
않는다(`ranger-admin -> ranger-usersync:5151` 실패). 그럼에도 내부 DB 인증으로
로그인이 되므로 실사용에 지장은 없다. 다만 **설정과 실제 동작이 어긋나 있으며**
LDAP·PAM 으로 옮길 때 이 값이 먼저 정리되어야 한다.

### 8-44. Ranger 자격 분리 — 하나의 비밀번호가 다섯 곳에 쓰이고 있었다 (2026-09-04)

§8-43 정정 과정에서 드러났다. 이미지 엔트리포인트
`/home/ranger/scripts/ranger.sh` 가 이렇게 쓴다.

```bash
echo "db_password=${RANGER_DB_PASSWORD}"
echo "rangerAdmin_password=${RANGER_DB_PASSWORD}"
echo "rangerTagsync_password=${RANGER_DB_PASSWORD}"
echo "rangerUsersync_password=${RANGER_DB_PASSWORD}"
echo "keyadmin_password=${RANGER_DB_PASSWORD}"
```

**다섯이 같은 값이다.**

#### 왜 문제인가

- **DB 자격이 곧 관리자 자격이다.** PostgreSQL 접속 문자열이 새면 정책 엔진의
  관리자 권한까지 함께 샌다. 그런데 DB 자격은 성질상 더 널리 퍼진다 —
  백업 스크립트·마이그레이션 Job·psql 접속에 쓰인다
- **`keyadmin` 이 특히 나쁘다.** Ranger KMS 의 키 관리자다. 암호화 키를
  다루는 계정이 DB 접속 계정과 같은 비밀번호를 쓴다
- **회전이 불가능하다.** 하나를 바꾸려면 다섯을 함께 바꿔야 하고, 이미 초기화된
  인스턴스는 `install.properties` 수정만으로 반영되지 않는다
- **감사 추적이 무의미해진다.** 어느 자격이 쓰였는지 값으로 구분할 수 없다

#### 조치 ① 매니페스트 — 재구축 시 분리된다

`ranger-admin` StatefulSet 에 엔트리포인트 래퍼를 넣었다. `ranger.sh` 의 네 줄을
각각의 환경변수로 바꿔치기한 뒤 원래 엔트리포인트를 `exec` 한다.

```
RANGER_ADMIN_PASSWORD     <- ranger-secret/admin-password
RANGER_TAGSYNC_PASSWORD   <- ranger-secret/tagsync-password
RANGER_USERSYNC_PASSWORD  <- ranger-secret/usersync-password
RANGER_KEYADMIN_PASSWORD  <- ranger-secret/keyadmin-password
```

**★ 치환이 하나라도 실패하면 기동을 멈춘다.** 그냥 넘어가면 자격이 조용히 다시
합쳐진 채로 뜨는데, 그것이 이 변경으로 없애려는 상태 그 자체다. 이미지 태그를
올릴 때 엔트리포인트가 바뀌면 여기서 걸린다.

`ranger-usersync` 의 `RANGER_USERSYNC_PASSWORD` 도 `db-password` 에서
`usersync-password` 로 바꿨다.

#### 조치 ② 실행 중 인스턴스 — 별도 회전이 필요하다

`ranger.sh` 는 `${RANGER_HOME}/.setupDone` 이 있으면 setup 을 건너뛴다.
**따라서 매니페스트 변경만으로는 기존 인스턴스가 바뀌지 않는다.**

회전은 공식 유틸 `changepasswordutil.py` 로 한다. 이 유틸은 현재 비밀번호를
요구하는데 지금은 그것을 알고 있다(§8-43). 순서가 중요하다 —
`rangerusersync` 를 먼저 바꾸면 usersync 가 즉시 끊기므로
**비밀번호 변경 → Deployment 시크릿 키 교체 → 재기동** 으로 간다.

스크립트를 `local/` 밖(`iso/ranger-cred-split.sh`)에 준비해 두었다. 자격 변경은
승인이 필요한 동작이라 이 항목에서는 실행하지 않았다.

#### 남는 한계

이미지 엔트리포인트를 `sed` 로 고치는 방식은 **이미지에 결합된다.** 태그를
올리면 깨질 수 있고, 위의 검증이 그때 기동을 멈춘다(조용히 합쳐지는 것보다는
낫다). 근본 해법은 `ranger-admin-install.properties` 를 우리 ConfigMap 으로
덮어쓰는 것이며, 그때 `authentication_method` 도 함께 정리하면 된다
(§8-43 의 UNIX/unixauth 불일치).

#### 실행 결과 (2026-09-04)

회전을 실행했다. `changepasswordutil.py` 가 네 계정 모두 `Password updated
successfully` 를 반환했고, 분리가 확인된다.

```
admin + admin-password  ->  200
admin + db-password     ->  401        ← 더 이상 통하지 않는다

DB 해시 (앞 8자)
  admin          ca9baf3f
  keyadmin       7ddda9e1
  rangertagsync  3ec42795
  rangerusersync a11009c6              ← 넷이 전부 다르다
```

`ranger-secret` 의 키: `db-password` · `admin-password` · `keyadmin-password` ·
`tagsync-password` · `usersync-password`.

##### ★ 중간에 usersync 를 잠깐 깨뜨렸다 — 거짓 성공 신호

회전 스크립트가 usersync 의 env 를 `kubectl patch --type=merge` 로 바꾸려 했는데
실패했다.

```
The Deployment "ranger-usersync" is invalid:
  spec.template.spec.containers[0].image: Required value
deployment "ranger-usersync" successfully rolled out     ← 바로 다음 줄
```

**전략적 병합 패치로 컨테이너를 이름으로 지목하려면 `image` 를 함께 줘야 한다.**
없으면 컨테이너 정의를 통째로 대체하는 것으로 해석되어 거부된다.

문제는 그 다음 줄이다. `rollout status` 가 **바뀌지 않은** Deployment 를 보고
"successfully rolled out" 을 출력했다. 패치 실패와 롤아웃 성공이 나란히 찍혀
**성공한 것처럼 읽힌다.**

그 사이 `rangerusersync` 의 비밀번호는 이미 바뀌었는데 usersync 는 옛 키를
쓰고 있었다 — 인증이 끊긴 상태였다. 레포 매니페스트로 다시 적용해 해소했다.

**교훈: 패치 결과를 롤아웃 상태로 판정하지 말 것.** 바뀌었어야 할 값을 직접
읽어 확인해야 한다. 이 스크립트도 그렇게 고쳤어야 했다 —
`kubectl apply` 로 매니페스트를 적용하는 편이 애초에 옳다.

### 8-45. 전체 네임스페이스 ambient 편입 — 실패. 그리고 드러난 PostgreSQL 용량 문제 (2026-09-04)

§8-41 로 프로브·HBONE 차단을 해소했고 §8-42 에서 "공유 서버는 클라이언트와 함께
편입해야 한다" 를 확인했다. 전체 편입은 그 조건을 만족한다 — 모두가 동시에
편입되므로. 그래서 시도했다.

#### 판정은 기능으로 했다

§8-42 에서 `Ready 79/79` 인 채로 Kafka 컨슈머가 끊겨 있었다. 그래서 이번에는
편입 전후로 같은 기능 점검을 돌렸다.

| | 편입 전 | 편입 후 |
|---|---|---|
| Kafka 컨슈머 | 접속중 | **끊김** |
| LDAP | OK | OK |
| Ranger API | 200 | **무응답** |
| Elasticsearch | yellow | yellow |
| PostgreSQL | ok | ok |
| 파드 Ready | 79/79 | **63/79** |

OpenReplay 10여 개가 CrashLoopBackOff, `cmmn-api`·`filebeat`·`gitlab` 이 NotReady.
**실패다.** 되돌렸다.

#### 되돌리기 — 이번에는 회복이 깔끔했다

```
+60초   66/79
+120초  67/79
+180초  79/79
```

§8-39 때(43/79까지 하락)보다 나았다. §8-41 의 정책 두 개가 있어 프로브가 막히지
않은 덕으로 보인다.

#### 그런데 두 파드가 남았다 — 원인은 ambient 가 아니었다

```
ender-openreplay / http-openreplay : CrashLoopBackOff
  pgConn.Ping() error: FATAL: remaining connection slots are reserved
    for roles with the SUPERUSER attribute (SQLSTATE 53300)
```

PostgreSQL 연결이 고갈되어 있었다.

```
106 / 100        ← superuser 예약 슬롯까지 잠식
idle 97건
openreplay 27 · hive 24 · gitlab 24 · dependencytrack 10 · ranger 6
가장 오래된 유휴 연결 31분
```

**`max_connections` 가 기본값 100 이었다.** 어디에도 설정한 적이 없다. 소비자
다섯이 각자 커넥션 풀을 들고 유휴 연결을 반납하지 않으므로 합이 한도를 넘는다.

3분을 기다려도 회복되지 않았다 — 풀은 유휴 연결을 스스로 놓지 않는다. 10분 이상
유휴인 연결 76건을 끊자 42/100 으로 떨어졌고 파드가 곧바로 살아났다(79/79).

##### 이것은 ambient 와 무관한 기존 결함이다

방아쇠가 대량 재기동이었을 뿐이다. **노드 재부팅으로도 같은 일이 난다.**
평상시에는 드러나지 않아 오늘까지 남아 있었다.

`postgresql-statefulset.yaml` 에 `max_connections=300` 을 넣었다(현재 소비 합
약 91 의 3배). **지금 적용하지는 않았다** — PostgreSQL 재시작은 방금 회복한
클러스터를 다시 흔든다. 다음 재기동에 반영된다.

#### 전체 편입에 대한 결론

세 번 시도했고 세 번 다 실패했다(§8-39 · §8-42 · 이번). 매번 다른 이유였고
매번 하나씩 해소했다 — 프로브 차단, HBONE 차단, 그리고 이번의 미상.

**남은 실패 원인은 규명하지 못했다.** OpenReplay 가 반복해서 무너지는 것으로
보아 그 워크로드군에 ztunnel 과 맞지 않는 통신 양상이 있다. 다음에 판다면
OpenReplay 파드 하나만 편입해 ztunnel 로그를 보는 것부터 시작해야 한다.

**현재 편입 상태로 유지하는 것은 LDAP 경로(`ds389` · `ranger-usersync`)뿐이고,
그 경로는 mTLS 로 흐른다(§8-41).** 전면 적용은 미해결로 남는다.

### 8-46. ambient 전면 편입의 진짜 원인 — AuthorizationPolicy 였다 (2026-09-04)

§8-45 에서 "남은 원인 미상" 으로 남긴 것을 규명했다.

#### 먼저 두 가설을 배제했다

**① OpenReplay 가 ambient 와 비호환?** 아니다. `ender-openreplay` 하나만 편입하니
`1/1 Running` 으로 정상 동작했다(`"Ender service started"`, 오류 없음).

**② PostgreSQL 연결 고갈?** 아니다. `max_connections` 를 300 으로 올리고
`67/300` 여유가 충분한 상태에서 재시도했는데 **동일하게 실패**했다.

개별 편입은 되고 전체 편입은 안 된다. 차이는 **상대편도 편입되는가** 하나다.
한쪽만 편입되면 PERMISSIVE 라 평문으로 흐르고, 양쪽이 편입되면 HBONE 을 탄다.
문제는 그 HBONE 경로에 있었다.

#### ztunnel 이 답을 말한다

```
src.identity="spiffe://cluster.local/ns/local/sa/chalice-openreplay"
dst.hbone_addr=10.0.0.233:5432  dst.identity=".../sa/postgresql"
error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

파드 쪽 증상은 이렇게 나온다.

```
can't init postgres connection: ... read: connection reset by peer
```

#### 원인 — ztunnel 은 NetworkPolicy 가 아니라 AuthorizationPolicy 를 본다

`allow-postgresql-access`(Kubernetes NetworkPolicy)에는
`app.kubernetes.io/instance: openreplay` 가 **들어 있다.** 파드 라벨도 맞는다.
그래서 Cilium 은 이 트래픽을 허용하고, 오늘도 정상 동작한다.

그런데 ztunnel 이 강제하는 것은 **Istio AuthorizationPolicy** 다.

```
allow-database-access   selector={app.kubernetes.io/component: database}  ALLOW
  5432 :  keycloak · hive-metastore · apicurio · gitlab
  3306 :  admin · cmmn-api
  27017:  admin · cmmn-api
  6379 :  keycloak · admin · cmmn-api
```

**OpenReplay 의 ServiceAccount 가 없다.** Istio 의 ALLOW 의미론은 이렇다 —
어떤 워크로드를 선택하는 ALLOW 정책이 하나라도 존재하면, **그 정책에 매칭되지
않는 모든 요청은 거부된다.** `postgresql` 은 `component: database` 라 선택되므로
목록에 없는 OpenReplay 는 전부 막힌다.

#### 같은 기제가 §8-42 의 Kafka 401 도 설명한다

```
allow-messaging-access  selector={name: kafka}  ALLOW
  9092/9093 : akhq · apicurio · logstash · admin · cmmn-api · argo-events-sa
```

`logstash` 가 목록에 있는데도 401 이었다. 이유는 §8-42 에서 이미 관측했다 —
**logstash 는 `sa/default` 로 돈다.**

```
src.identity="spiffe://cluster.local/ns/local/sa/default"
```

정책은 `cluster.local/ns/*/sa/logstash` 를 허용하는데 실제 신원이 `sa/default`
라 매칭되지 않는다. **ambient 에서 워크로드 신원은 ServiceAccount 다.**

#### 그리고 LDAP 이 성공한 이유도 설명된다

`ds389`(component: governance)를 선택하는 AuthorizationPolicy 가 **없다.**
선택하는 ALLOW 정책이 없으면 거부 로직이 발동하지 않는다. §8-41 에서 LDAP 만
성공한 것은 그 경로가 운 좋게 정책 사각지대에 있었기 때문이다.

#### 정리 — 이 정책들은 한 번도 실제로 강제된 적이 없다

`service-mesh/` 의 AuthorizationPolicy 5종은 ambient 가 비활성인 채로 작성되어
**실 트래픽으로 검증된 적이 없다.** 그래서 실제 통신과 어긋나 있다. ambient 를
켜는 순간 그 격차가 전부 거부로 나타난다.

#### 고치려면

| 대상 | 필요한 것 |
|---|---|
| `allow-database-access` | OpenReplay 서비스어카운트 다수를 5432 에 추가. Redis(6379)·ClickHouse 경로도 함께 |
| `allow-messaging-access` | logstash 에 **전용 ServiceAccount** 부여(현재 `default`). OpenReplay 도 추가 |
| `allow-observability-access` | ES 소비자 재확인 |
| 공통 | `default` SA 로 도는 워크로드 색출 — 신원이 구분되지 않아 정책을 쓸 수 없다 |

**작업 순서가 중요하다.** 정책을 먼저 맞추고 그 다음에 편입해야 한다. 반대로 하면
오늘처럼 15개 파드가 동시에 무너진다.

#### 부수 소득 — PostgreSQL max_connections

원인 추적 중 별개 결함을 찾아 고쳤다(§8-45). `max_connections` 가 기본값 100
이었고 실제로 고갈되어 있었다. 300 으로 올려 적용했다(`67/300` 확인).
ambient 와 무관하며 노드 재부팅으로도 터졌을 문제다.

### 8-47. 네임스페이스 전면 ambient 편입 — 성공. 원인은 principal 의 중간 `*` 였다

§8-46 이 "AuthorizationPolicy 를 실제 통신에 맞춰야 한다"로 끝났다. 그 작업을
하다 **정책이 처음부터 단 한 줄도 매칭된 적이 없었다**는 것을 발견했다.

#### 결정적 증거

`sa/cmmn-api` 는 Kafka 정책에 분명히 있는 이름인데도 거부됐다:

```
src.identity="spiffe://cluster.local/ns/local/sa/cmmn-api"
dst.hbone_addr=10.0.0.238:9092  dst.workload="kafka-0"
error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

정책에 있는 신원이 정책에 의해 거부된다 — 이름이 아니라 **매칭 규칙**이 문제였다.

#### 원인

Istio 의 문자열 필드는 **완전 일치 · 접두(`abc*`) · 접미(`*abc`) · 존재(`*`)**
네 가지만 지원한다. **중간 `*` 는 와일드카드가 아니라 리터럴이다.**

이 파일은 26곳 전부가 `cluster.local/ns/*/sa/<name>` 이었다. 네임스페이스 자리의
`*` 가 리터럴이므로 실제 신원 `cluster.local/ns/local/sa/cmmn-api` 와 결코 같지
않다. 즉 **allow-database-access · allow-messaging-access ·
allow-observability-access · allow-datalakehouse-access 네 정책이 생성된 이래로
한 번도 아무것도 허용한 적이 없다.**

드러나지 않았던 이유는 하나다 — 네임스페이스가 ambient 에 편입되어 있지 않아
ztunnel 이 정책을 강제할 기회가 없었다. **편입하는 순간 네 정책이 동시에
"전면 거부"로 바뀐다.** §8-39·§8-40·§8-45 에서 편입할 때마다 15개 안팎의 파드가
무너진 것이 전부 이것이었다. 그때마다 OpenReplay·프로브·NetworkPolicy 를
의심했는데 전부 빗나간 것이었다.

수정: 접미 매칭 `*/sa/<name>` 으로 바꿨다. base 는 네임스페이스를 모르므로
(오버레이가 각자 정한다) 하드코딩할 수 없다. 대가는 신뢰 도메인·네임스페이스
제약이 사라지는 것이고, 실질 통제는 ServiceAccount 이름이 된다. 네임스페이스
경계는 Kubernetes NetworkPolicy 가 계속 잡는다.

#### 함께 고친 것

| 항목 | 내용 |
|---|---|
| 소비자 누락 | ztunnel 거부 로그를 집계해 `allow-*` NetworkPolicy 와 대조했다. 5432 에 ranger-admin·glitchtip·dependency-track·defectdojo·safeline, 6379 에 gitlab·glitchtip·defectdojo, 9092 에 kafka-bridge, MinIO 에 hive-server·spark-connect·spark-history 를 추가했다 |
| `default` SA 4건 | logstash·elasticsearch·kibana·falcosidekick 이 전부 `default` 로 돌았다. ambient 에서 SA 는 곧 신원이라 넷이 구분되지 않는다 — 하나에게 권한을 주면 넷 모두에게 준다. 각자 전용 SA 를 만들어 배선했다 |
| ECK 오퍼레이터 | `elastic-operator`(elastic-system)가 ES 9200 을 관리하는데 메시 밖이라 **신원이 아예 없었다**. principal 규칙은 어느 것도 매칭되지 않는다. `elastic-system` 도 ambient 에 편입하고 `*/ns/elastic-system/sa/elastic-operator` 를 허용했다 |
| ClickHouse | OpenReplay 전용 8123·9000 규칙을 추가했다 |

#### 결과

```
Ready 79/79
Kafka(logstash SA -> 9092)          OK      # §8-42 의 401 이 사라졌다
LDAP(ranger-usersync -> ds389:3389) OK
Ranger admin API(6080)              OK
PostgreSQL(5432)                    OK
Elasticsearch(9200)                 OK
ns local / elastic-system           ambient
ztunnel 정책 거부 (최근 90초)        0 건
HBONE 15008 인바운드 (최근 90초)     252 건   # 전 구간 mTLS
```

#### 교훈

- **강제되지 않는 정책은 검증되지 않는다.** 이 정책은 몇 달 동안 "있었고"
  렌더링·스키마 검증을 전부 통과했다. ztunnel 이 켜지기 전까지는 틀렸다는 신호가
  나올 수 없었다. 정책 파일은 존재가 아니라 **거부 로그가 0 인지**로 확인해야 한다.
- **거부 로그를 집계해서 읽을 것.** 한 건씩 보면 매번 다른 원인처럼 보인다.
  `src.identity -> dst:port` 로 묶어 세니 20줄로 전부 드러났다.
- ★ 방향이 반대였다. §8-39~§8-45 는 "편입했더니 무엇이 깨졌나"를 물었다.
  옳은 질문은 "**편입하면 무엇이 강제되기 시작하나**"였다.


### 8-48. Ranger 인증 — UNIX 는 처음부터 도달 불가능한 곳을 가리키고 있었다

CLAUDE.md 의 미결 항목이었다. 두 가지가 얽혀 있었다.

#### 1. `authentication_method=UNIX` 가 아무데도 가리키지 않았다

이미지의 `ranger-admin-install.properties` 기본값이 UNIX 다. UNIX 방식은 Ranger
admin 이 `UnixAuthenticationService`(포트 5151)에 인증을 위임하는 것이다. 그런데

- 그 프로세스는 **ranger-usersync 파드**에서 돈다(usersync 의 liveness 프로브가
  바로 그 프로세스를 확인한다).
- `ranger-admin-site.xml` 에 `ranger.unixauth.*` 가 **하나도 없다.** 기본값이므로
  admin 은 자기 파드의 `localhost:5151` 로 붙으려 한다 — 거기엔 아무것도 없다.
- 애초에 `ranger-usersync` 에는 **Service 객체가 없다.** 도달할 방법이 없다.

즉 LDAP 에서 동기화된 사용자는 로그인할 수 없다. 실측으로 확인했다 —
`oim-svc`(DS389 에서 동기화된 사용자) 로그인은 401 이다. **내장 `admin` 만
되는 이유는 Ranger 가 내부 사용자에 대해 DB 로 폴백하기 때문이고, 그래서 이
결함이 지금까지 드러나지 않았다.** "관리자가 들어가지니 인증은 된다"고
읽었던 것이다.

사용자를 DS389 에서 가져오면서 인증은 다른 데 맡길 이유가 없다.
`authentication_method=LDAP` 으로 바꾸고 `xa_ldap_*` 를
`ranger-usersync-configmap` 의 `SYNC_LDAP_*` 와 짝을 맞췄다. 둘이 어긋나면
"동기화는 되는데 로그인은 안 되는" 상태로 되돌아간다.

#### 2. 이미지 템플릿을 매니페스트로 통제할 수 없었다

`authentication_method` 는 이미지에 구워진 `ranger-admin-install.properties`
안에 있다. 엔트리포인트(`ranger.sh`)가 그것을 복사해 쓰고 setup 이 끝나면
지운다. 매니페스트에서 손댈 방법이 없었다 — 그래서 지금까지 `ranger.sh` 자체를
sed 로 고치는 결합이 남아 있었다.

`ranger-admin-config` ConfigMap 으로 그 템플릿을 통째로 대체했다. 엔트리포인트는
LDAP bind 비밀번호만 치환해 `${RANGER_SCRIPTS}/ranger-admin-install.properties`
로 쓴다 — usersync 가 이미 쓰던 방식과 같다. 치환이 적용되지 않으면 기동을
멈춘다(이미지 기본값 UNIX 로 조용히 돌아가는 것을 막는다).

> ★ ranger-admin 에는 **PVC 가 없다.** `/opt/ranger` 는 컨테이너 임시 계층이라
> `.setupDone` 도 함께 사라지고 **재시작마다 setup 이 다시 돈다.** §8-44 에서
> "이미 초기화된 인스턴스에는 효과가 없다"고 적었던 전제가 이 배포에는
> 해당하지 않는다. 설정 변경이 재시작만으로 반영된다.

#### 3. 부수 발견 — 로그인 실패가 누적되면 계정이 영구히 잠긴다

검증하느라 틀린 비밀번호를 반복했더니 `admin` 이 잠겼다. 특징이 고약하다:

- 증상은 그냥 **401** 이다. 응답으로는 잠금인지 비밀번호 오류인지 알 수 없다.
- **파드를 재시작해도 풀리지 않는다.** 인메모리 카운터가 아니라 `x_auth_sess`
  의 연속 실패 기록에서 파생된다(admin 은 222건이 쌓여 있었다).
- `x_portal_user.status` 는 `1`(정상) 그대로다. 사용자 테이블만 봐서는 알 수 없다.
- 단서는 로그 한 줄뿐이다: `Login Unsuccessful:admin | ... | User account is locked`
- **끄는 설정이 없다.** jar 안에 관련 property 문자열이 존재하지 않는다.

푸는 방법은 ranger DB 에서 그 사용자의 실패 기록(`auth_status` 2·4)을 지우는
것뿐이다. 지우자마자 200 이 됐다.

★ 운영상 함의 — Ranger 로그인을 두드리는 자동화(헬스체크·모니터링)를 두면
**관리자가 잠긴다.** 이 배포의 readiness 프로브가 `/login.jsp`(인증 불필요)를
쓰는 것은 다행이었다.

#### 결과

```
authentication_method               LDAP
admin (내장)                        200
keyadmin (내장)                     200   # LDAP 실패 시 내부 DB 폴백이 동작한다
ranger-sync (LDAP, 올바른 비밀번호)  200
ranger-sync (LDAP, 틀린 비밀번호)    401
Ready 79/79 · ztunnel 정책 거부 0건
```

`oim-svc` 는 여전히 로그인할 수 없다 — `ds389-bootstrap` 이 `userPassword` 를
주지 않는 동기화 전용 픽스처이기 때문이다. 의도된 것이고, 인증 경로 검증에는
비밀번호가 있는 `ranger-sync` 를 썼다.

#### 남은 것

- `ranger-admin` 도 ambient 에 편입했다(§8-47 의 전제). DS389 로 가는 LDAP
  바인드가 평문처럼 보이지만 ztunnel 이 mTLS 로 감싼다.
- Keycloak 을 IdP 로 세우면 이 자리는 다시 검토 대상이다(ADR 후보).


### 8-49. OpenReplay "root 18건" 은 사실이 아니었다 — 위반 0 건으로 해소

ADR-069 의 승격 조건이었다. 기록에는 *"OpenReplay 17개 워크로드 + 마이그레이션
Job 이 전부 root 로 뜬다. prod 는 Kyverno `disallow-root` 가 Enforce 라 그대로는
거부된다. 예외 목록에 3자 앱 18건을 넣으면 정책의 실효 범위가 크게 줄어든다"*
라고 되어 있었다. **결정을 내리기 전에 전제를 확인했더니 전제가 틀렸다.**

#### 실측

| 대상 | 실제 uid | Kyverno 가 걸었던 이유 |
|---|---|---|
| Deployment 16개 | **1001** (매니페스트에 `runAsUser: 1001` 32곳) | `runAsNonRoot` **미선언** |
| `frontend-openreplay` | **65532** (distroless. `crictl inspecti` 로 이미지 USER 확인) | `securityContext: null` |
| `databases-migrate` Job | **root** | securityContext 자체가 없음 |

즉 **root 로 뜬 것은 18건이 아니라 1건**이다. 나머지 17개는 이미 비-root 로
돌고 있었고 선언만 없었다. `disallow-root` 는 실행 uid 가 아니라
`runAsNonRoot=true` 선언을 본다 — 그 차이가 "3자 앱 18건 예외"라는 큰 결정으로
번역되어 있었다.

#### 조치

17개 Deployment 에 선언을 채우고 나머지 하드닝을 함께 넣었다:

```
파드:      runAsNonRoot: true · seccompProfile: RuntimeDefault
컨테이너:  runAsNonRoot: true · allowPrivilegeEscalation: false
           capabilities: drop: ["ALL"]
```

마이그레이션 Job 은 init 컨테이너(`git`)가 hostPath
`/openreplay/storage/nfs` 에 `chown 1001:1001` 을 건다. hostPath 는 kubelet 이
root 소유로 만들고 **fsGroup 이 적용되지 않으므로** 이것만은 특권이 필요하다.
root 대신 **`CAP_CHOWN` 만으로 충분한지 일회성 파드로 실측했다:**

```
runAsUser: 1001 · capabilities: {drop: [ALL], add: [CHOWN]}
-> CHOWN OK   (디렉터리는 이미 1001:1001 이라 사실상 no-op 이기도 하다)
```

그래서 Job 도 `runAsNonRoot: true` + `runAsUser: 1001` 로 두고 `git` 에만
`CHOWN` 을 더했다. **Job 은 재실행하지 않았다** — 34시간 전 `Complete` 이고
스키마 마이그레이션이라 재실행은 별개의 위험이다. 매니페스트만 고쳤고
다음 재생성 때 적용된다.

#### 결과

```
kubectl apply -> Deployment 17개 configured
Ready 79/79 (60초 내 전원 복귀)
Kyverno fail (openreplay 리소스)  : 0 건
disallow-root-user 클러스터 전체  : 2 건  (openreplay 아님)
```

전에는 `disallow-root-user` 만으로 18건이 잡혔다.

#### 교훈

★ **"결정하기 전에 전제를 재보라."** 이 항목은 몇 주 동안 "정책이냐 예외
18건이냐"라는 아키텍처 선택으로 남아 있었다. 실제로는 `runAsNonRoot: true`
한 줄씩을 넣는 작업이었고, 선택지 자체가 존재하지 않았다. 기록된 전제가
검증된 전제는 아니다 — §8-47 의 "강제되지 않는 정책은 검증되지 않는다" 와
같은 부류다.

★ Kyverno 의 `disallow-root` 는 **실행 uid 가 아니라 선언**을 본다. 비-root 로
도는 워크로드도 선언이 없으면 잡힌다. 반대로 선언만 있고 이미지가 root 를
강제하면 kubelet 이 기동을 거부한다(그쪽이 옳은 동작이다).


### 8-50. L0 랩 — 디스크 확장 · ET Open 36,818 규칙 · 끊겨 있던 전송 경로

CLAUDE.md 의 미결 항목 세 개(ET Open · Zeek · 디스크)를 처리했다.

#### 1. 디스크 — 블로커였다

nano 이미지의 루트는 2.8 GB 이고 82% 가 차 있어 **여유가 482 MB** 였다.
ET Open 을 넣을 수 없는 상태였다는 기록이 맞았다.

가상 디스크는 이미 16 GB 다. 파티션과 파일시스템만 따라가지 않았을 뿐이라
게스트 안에서만 늘리면 됐다 — `Resize-VHD` 도, VM 정지도 필요 없었다.

```
gpart resize -i 1 da0             # 3.0G -> 16G
growfs -y /dev/ufs/OPNsense_Nano
mount -u -o rw /
-> 15G, 12G avail (482M -> 12G)
```

★ `growfs /dev/da0a` 는 `Operation not permitted` 로 거부된다.
`kern.geom.debugflags=16` 을 켜도 같다. 루트가 **레이블**로 마운트되어 있어
GEOM 배타 쓰기 권한이 그 provider 에 걸려 있기 때문이고, **레이블 경로로
호출해야 통과한다.** 이 차이를 모르면 "온라인 확장이 안 되는구나" 로 잘못
결론내고 VM 을 내리게 된다.

#### 2. ET Open — 46종 중 23종

chat·games·p2p·inappropriate·info 등은 침입 탐지 검증과 무관한 소음이고
Suricata RSS 가 규칙 수에 비례한다. 보안 관련 23종만 켰다.

```
룰셋 23종 · 규칙 36,818개 · 디스크 62 MB · Suricata RSS 약 1.2 GB / 6 GB
```

★ **`configctl ids update` 가 "OK" 를 출력하고 아무것도 받지 않았다.**
config.xml 을 직접 고쳤기 때문에 OPNsense 의 설정 반영 경로를 타지 않았고,
`rule-updater.config` 가 `# autogenerated, do not edit.` 한 줄 그대로였다.
`configctl template reload OPNsense/IDS` 를 넣어야 템플릿이 다시 생성된다.
**성공 출력이 성공을 뜻하지 않는 사례가 또 나왔다** — §8-47 과 같은 부류다.

#### 3. 동작 확인 — HOME_NET 안에서는 걸리지 않는다

sqlmap·Nikto User-Agent 로 HTTP 를 쐈는데 알림이 0 이었다. 규칙이 안 실린 게
아니라 **방향이 맞지 않았다.** ET Open 규칙의 16,564개가
`$HOME_NET any -> $EXTERNAL_NET any` 인데, 호스트(10.77.0.190)에서
방화벽(10.77.0.1)으로 가는 트래픽은 HOME_NET 안이다.

목적지가 `any` 인 DNS 규칙으로 라우팅을 건드리지 않고 검증했다:

```
nslookup sqlmapff.com 10.77.0.1
-> ET MALWARE Possible Winnti-related DNS Lookup   10.77.0.190 -> 10.77.0.1
```

로그의 ET flowbit 경고(`Checked in 2052143 and 0 other sigs`)도 적재의 증거다.

#### 4. 전송 경로가 14시간 끊겨 있었다

알림이 방화벽에는 쌓이는데 Elasticsearch 의 `suricata` 인덱스 최신 문서가
**전날 21:50** 이었다. 경로는

```
Suricata EVE -> syslog(10.77.0.190:5140) -> netsh portproxy
             -> WSL localhostForwarding -> kubectl port-forward -> logstash:5140
```

이고, 맨 끝의 `kubectl port-forward` 가 죽어 있었다. **오늘 logstash 파드를
두 번 재생성한 것이 원인이다**(§8-47 의 전용 SA 작업). 방화벽 쪽에는 아무
오류도 나지 않는다 — eve.json 은 정상이고 인덱스만 조용히 멈춘다.

★ 확인은 **인덱스의 최신 문서 시각**으로 해야 한다. 건수만 보면
과거 데이터 20건 때문에 "들어오고 있다"로 읽힌다. 실제로 처음에 그렇게
읽을 뻔했다.

포워드를 다시 띄우고 재검증했다:

```
"@timestamp":"2026-09-04T12:13:00.015Z"
"signature":"ET MALWARE Possible Winnti-related DNS Lookup"
"src_ip":"10.77.0.190"
```

**ADR-031 경로가 끝까지 살아 있다.**

#### 5. Zeek — 패키지가 없다

`pkg search zeek` 0건, 플러그인 210종 중에도 없다. `os-ntopng` 이 인접하나
다른 물건이다. 선택지는 (a) 도입하지 않는다 (b) L0-Target(Ubuntu)에서 돌리고
트래픽을 미러링한다 (c) ntopng 로 대체한다. **미결정 — 사용자 판단이 필요하다.**
Suricata EVE 가 이미 flow·http·dns·tls 를 내므로 랩 목적에서는 (a) 가
합리적으로 보이나, 랩 문서의 제목이 "Suricata · Zeek" 인 만큼 명시적으로
정리하는 편이 낫다.

#### 부수 — 시리얼 콘솔의 한계

여러 줄 heredoc 을 입력 파일로 밀어 넣었더니 **중간에서 바이트가 유실되어**
셸이 heredoc 을 연 채로 멈췄다. 이후 작업은 SSH/scp 로 전환했다(호스트가
`vEthernet (L0-LAN)` 으로 10.77.0.190 에 있어 10.77.0.1 에 직접 붙는다).
시리얼은 짧은 확인용으로만 쓸 것. 아울러 OPNsense 의 root 셸은 **csh** 라
`"...$|..."` 가 `Illegal variable name` 으로 죽는다.


### 8-51. Zeek 3안을 전부 구현했다 — 세 경로가 동시에 돈다

§8-50 에서 "Zeek 패키지가 없다"로 끝내고 3안을 제시했는데, **겹치더라도 셋 다
돌려 비교하기로 결정했다.** 랩의 목적이 비교이므로 중복 자체가 산출물이다.

| 안 | 무엇 | 어디 | 결과 |
|---|---|---|---|
| 1 | Suricata EVE 프로토콜 로그 | OPNsense | `suricata` 인덱스 |
| 2 | Zeek | L0-Target + Hyper-V 포트 미러링 | `zeek` 인덱스 |
| 3 | ntopng | OPNsense | 자체 UI(3000) · Redis |

#### 1안 — 켜는 것만으로는 밖으로 나가지 않았다

EVE http/tls 를 켜니 `eve.json` 에는 곧바로 들어왔다. 그런데 Elasticsearch 에는
여전히 `alert` 만 왔다.

원인: 생성된 `suricata.yaml` 에 eve-log 출력이 **둘**이다.

```
1) 파일(eve.json)  : alert · anomaly · http · tls · drop · ssh
2) syslog          : alert 만          <- Logstash 로 가는 것은 이쪽
```

**GUI 에는 2)의 types 를 바꾸는 항목이 없다.** `conf.d/eve-syslog.yaml` 로
`outputs` 를 통째로 대체해 해결했다.

★ `include` 는 리스트를 병합하지 않고 **대체**한다. 일부만 적을 수 없어
outputs 전체를 옮겨야 했다. 버전을 올리면 원본과 어긋날 수 있는 부채다.

★ 첫 시도는 **Suricata 가 아예 기동하지 않았다** — 파일이 `%YAML 1.1` + `---`
로 시작하지 않아서다. `installed_rules.yaml` 과 같은 제약인데, 이번에도
`configctl ids restart` 는 조용히 넘어가고 `service suricata status` 만
"not running" 이었다.

#### 2안 — Gen2 라 무중단으로 됐다

L0-Target 이 Gen2 여서 NIC 핫애드가 됐다(OPNsense 는 Gen1 이라 안 된다).
VM 을 내리지 않고 미러 NIC 을 붙였다.

```
Set-VMNetworkAdapter -VMName L0-OPNsense -Name LAN    -PortMirroring Source
Set-VMNetworkAdapter -VMName L0-Target   -Name MIRROR -PortMirroring Destination
```

**먼저 미러가 실제로 패킷을 주는지 tcpdump 로 확인하고** Zeek 를 깔았다 —
안 되는 상태에서 설치부터 하면 원인이 둘로 늘어난다. 40패킷이 잡혔다.

Zeek 8.2.2 (OBS `security:zeek`). 메타패키지 `zeek` 은 `zeek-btest-data`·
`zeek-spicy-dev` 를 끌어오는데 그 둘이 미러 리다이렉트 해석 실패로 죽었다 —
`zeek-core` + `zeekctl` 로 충분하다.

전송은 직접 만든 `zeek-ship.py` 다. Filebeat 를 쓰지 않은 이유는 저장소를 하나
더 붙여야 하는 것과, **Zeek JSON 에는 어느 로그인지가 들어 있지 않다**는 점이다
(conn/dns/http 가 같은 모양이다). 파일명을 아는 쪽에서 `zeek_log` 를 넣는다.
로그 회전 시 inode 변경을 감지해 다시 연다 — 그러지 않으면 조용히 멈춘다.

★ **포트포워딩만으로는 안 됐다.** 5141 은 `netsh portproxy` 를 넣었는데도
`timed out` 이었다. 5140 에는 방화벽 규칙이 있었고 5141 에는 없었다.
호스트 방화벽 규칙까지 넣어야 경로가 열린다.

#### 3안 — 모델을 손으로 만들면 안 된다

ntopng 은 Redis 없이는 기동하지 않는다(`ntopng requires redis server`).
`os-redis` 를 함께 깔았다.

★★ `config.xml` 에 `<redis><general><enabled>1` 을 손으로 넣었더니 템플릿
렌더가 죽었다:

```
error generating template OPNsense/Redis :
  'collections.OrderedDict object' has no attribute 'slowlog'
```

모델에 필드가 많아 하나라도 빠지면 이렇게 된다. `run_migrations.php` 도
노드를 만들어 주지 않는다 — **OPNsense 는 모델을 저장할 때** 기본값으로
노드를 만든다. GUI 가 하는 일을 그대로 하는 PHP 스크립트
(`enable-redis.php`: 모델 인스턴스 → 검증 → serializeToConfig → save)로
해결했다. **헤드리스 OPNsense 조작의 일반 해법이다.**

#### 실측 비교 (같은 트래픽)

```
suricata   dns 3306 · flow 1523 · tls 806 · http 96 · ssh 51 · alert 9
zeek       conn 242 · dns 148 · ssl 109 · weird 25 · ntp 12 · http 7
Ready 79/79
```

건수 차이는 우열이 아니다. Suricata 는 인라인(netmap)으로 모든 패킷을 보고
Zeek 는 미러를 통해 본다. Zeek 의 `conn` 이 Suricata 의 `flow` 에 대응하고,
Zeek 는 `weird`(프로토콜 이상)처럼 Suricata 에 없는 로그를 낸다.
**둘을 함께 두는 값어치는 이 차이를 보는 데 있다** — 그것이 겹치더라도 셋 다
돌리기로 한 이유다.

#### 자원

```
OPNsense  6 GB : Suricata 1.2 GB + ntopng + redis, 여유 3.5 GB
L0-Target 2 GB -> 4 GB(동적 최대). Zeek + 전송기.
디스크    OPNsense 12 G 여유 · Target 19 G 여유
```

#### 이번에도 반복된 것

★ **"켰다"와 "도달한다"는 다르다.** 1안은 설정을 켜고도 밖으로 나가지 않았고,
2안은 포트포워딩을 넣고도 방화벽에서 막혔다. §8-50 의 port-forward 와 같은
부류이고, 이 랩에서만 세 번째다. **경로는 끝단에서 확인해야 한다.**


### 8-52. §8-47 이 ECK 관리를 끊어 놓았다 — 네임스페이스를 넘는 HBONE

`default` SA 로 도는 워크로드를 정리하다 `elasticsearch-es-default-0` 이
아직 `default` 인 것을 발견했다. §8-47 에서 CR 에 `serviceAccountName` 을
넣었는데 **파드는 3일 전 것 그대로**였다. 오류는 없었다.

#### 사슬

1. **ECK 가 파드를 롤링하지 않았다.** `phase=ApplyingChanges` 로 멈춰 있었다.
2. 이유는 클러스터가 **yellow** 였기 때문이다. ECK 는 green 이 아니면
   롤링하지 않는다.
3. yellow 인 이유는 **단일 노드인데 인덱스가 복제본 1** 을 요구해서다.
   배정될 노드가 없으니 영원히 풀리지 않는다(unassigned 12개).
4. 복제본을 0 으로 내려 green 을 만들었는데도 롤링하지 않았다.
   CR 조건을 보니 **`ElasticsearchIsReachable=False`** 였다:
   ```
   elasticsearch client failed for
     https://elasticsearch-es-default-0.elasticsearch-es-default.local:9200/...
     context deadline exceeded
   ```
5. **타임아웃이다 — 거부가 아니다.** ztunnel 정책 거부 로그는 0 건이었다.
   즉 Istio 가 아니라 Kubernetes NetworkPolicy 다.
6. `allow-elasticsearch-access` 에는 `elastic-system` namespaceSelector 가
   **이미 있었다.** 9200 은 열려 있었다.
7. 진짜 원인은 `allow-istio-hbone` 이었다:
   ```yaml
   ingress:
     - from:
         - podSelector: {}     # ← 같은 네임스페이스만
       ports: [{ port: 15008 }]
   ```
   **ambient 에 편입되면 통신은 목적지 포트가 아니라 ztunnel 사이의 HBONE
   터널(15008)로 흐른다.** 9200 을 아무리 열어도 15008 이 막히면 못 간다.

#### 내가 만든 결함이다

§8-47 에서 "ECK 오퍼레이터는 메시 밖이라 신원이 없다"는 것을 발견하고
`elastic-system` 을 ambient 에 편입했다. 그 순간 오퍼레이터의 통신이
평문 9200 에서 HBONE 15008 로 바뀌었고, 그 포트는 네임스페이스를 넘지
못하게 되어 있었다. **문제를 고치면서 다른 것을 끊었고, 양쪽 다 조용했다.**

같은 이유로 `argo-events -> Kafka` 도 막혀 있었을 것이다 —
AuthorizationPolicy 는 허용하고 있으므로 정책만 보면 알 수 없다.

수정: `allow-istio-hbone` 에 `namespaceSelector: {}` 를 더했다.
15008 을 넓게 여는 것이 안전한 이유는 **그 포트가 메시의 전송 계층이고
실제 인가는 ztunnel 이 AuthorizationPolicy 로 하기** 때문이다. mTLS 로
신원을 확인한 뒤 정책을 적용하므로 여기서 좁히는 것은 보안을 더하지 않고
메시만 망가뜨린다.

고치자 즉시 `ElasticsearchIsReachable=True` 가 되고 ECK 가 파드를 롤링해
**SA 가 `elasticsearch` 로 바뀌었다** — §8-47 이 그제서야 완결됐다.

#### 복제본은 매니페스트로 고정했다

`elasticsearch-ilm.yaml` 이 `number_of_replicas: 1` 을 박아 두고 있었다.
`ES_REPLICAS` 환경변수로 빼고 local 오버레이가 `"0"` 으로 덮는다
(`patches/es-replicas-local.yaml`). dev/prod 는 3노드라 1 이 맞다.

★ `index_patterns: ["*"]` 인 최저 우선순위 catch-all 로 한 번에 덮으려
했으나 **ES 가 거부한다** — 같은 우선순위의 기존 템플릿과 패턴이 겹치면
`illegal_argument_exception` 이다. 실제로 쓰는 이름만 명시했다
(`suricata*`·`zeek*`. L0 랩 인덱스는 Logstash 가 즉석에서 만들어 템플릿이
없었고, 그래서 ES 기본값인 복제본 1 이 붙고 있었다).

#### 부트스트랩 Job 두 개도 `default` 였다

| Job | 어디로 | 조치 |
|---|---|---|
| `elasticsearch-ilm-setup` | ES 9200 | 전용 SA + AuthorizationPolicy 에 추가 |
| `databases-migrate`(OpenReplay) | PostgreSQL·ClickHouse | `db-migrate-openreplay` SA |

★ **Job 은 평소에 돌지 않아 편입 시점에 드러나지 않는다.** ILM Job 은
재실행하고 나서야 9200 이 막힌 것이 보였다. `databases-migrate` 는 아직
Complete 상태라 지금은 멀쩡하고, **클러스터를 다시 세울 때 터진다.**
이름을 `-openreplay` 로 끝내 기존 접미 규칙 `*-openreplay` 에 그대로
매칭되게 했다.

★ ILM Job 의 스크립트는 `set -eu` 에 `curl -sf` 다. HTTP 오류 하나면
스크립트 전체가 죽고, 파드는 backoff 한도를 넘기면 **삭제되어 로그가
남지 않는다.** 원인을 보려면 같은 SA·이미지로 프로브 파드를 띄워야 했다.

#### 결과

```
ES health=green · unassigned 0
ECK phase=Ready · ElasticsearchIsReachable=True
elasticsearch-es-default-0 SA = elasticsearch     (default 였다)
템플릿 복제본  logstash 0 · suricata 0 · zeek 0
L0 파이프라인  suricata·zeek 모두 최신 문서 갱신 중
Ready 79/79 · ztunnel 정책 거부 2건(재시작 경합, 같은 파드의 정상 연결 160건)
```

#### 교훈

★ **편입은 통신 경로를 바꾼다.** 목적지 포트를 열어 두었다고 안심할 수
없다 — ambient 에서는 실제 트래픽이 15008 로 간다. 그리고 그 차단은
**거부가 아니라 타임아웃**으로 나타나므로 정책을 의심하기 어렵다.

★ **"고쳤다"의 범위를 좁게 잡을 것.** §8-47 은 Istio 쪽만 보고 끝냈고
Cilium 쪽 전제를 함께 옮기지 않았다. 두 계층이 같은 통신을 각자 통제하는
구조에서는 한쪽만 고치면 반드시 이런 일이 난다 — 이 문서에서 세 번째다.


### 8-53. 외부 진입점을 세우고 API 과금 계량을 계약으로 고정했다

요건: **외부 고객에게 인보이스를 발행한다.** 외부 트래픽 수용은 나중이라고
했으나, 검토해 보니 **게이트웨이가 과금의 전제 부품**이라 순서가 뒤집혔다.

#### 왜 게이트웨이가 먼저였나

API 호출을 세려면 L7 프록시가 요청 경로에 있어야 한다. 그런데 이 클러스터에는
계량 지점이 **하나도 없었다**:

- `ztunnel` 은 L4 다. 바이트·커넥션만 보이고 요청 단위가 보이지 않는다.
- `waypoint` 는 파드가 떠 있으나 `istio.io/use-waypoint` 워크로드가 **0개**다.
  배포만 되고 아무 트래픽도 지나지 않는다.
- Ingress 12개가 있으나 전부 OpenReplay 것이고 `ingressClassName: openreplay`
  인데 **그런 IngressClass 도 컨트롤러도 없다.** 주소도 `<none>` 이다.
  (CLAUDE.md 의 "Ingress 객체 0개" 도, "Gateway API CRD 가 설치되지 않아" 도
  둘 다 낡은 서술이었다 — CRD 5종과 GatewayClass 3종이 이미 있다.)

그리고 계량 지점을 나중에 바꾸면 이벤트 스키마와 **이미 청구한 이력**이 함께
흔들린다. 청구는 소급 재해석이 불가능한 데이터다.

#### 세운 것

```
Gateway(istio) + NodePort 30727/31938 + cert-manager TLS
  HTTPRoute api        api.oneinchmarket.local -> cmmn-api:8080
  HTTPRoute redirect   80 -> 443 (301)
Telemetry api-usage -> meshConfig extensionProvider(api-usage-json)
```

★ `networking.istio.io/service-type: NodePort` 가 필수다. k3s 에서 servicelb 를
껐으므로 LoadBalancer 로 두면 Service 가 영원히 Pending 이고 도달할 방법이 없다.

검증:

```
Programmed=True · 인증서 Ready · SAN 5개
HTTPS  /actuator/health -> 200 {"status":"UP"}
HTTP   -> 301 https://...
호스트 불일치 -> 404
```

#### 계약을 먼저 고정했다

```
contracts/schemas/api-usage-event.json   CloudEvents 1.0 페이로드
contracts/asyncapi/api-usage.yaml        채널 계약
```

`contracts/` 는 ADR-067 이 계약 우선을 규정해 두고도 **비어 있었다.** 과금이
첫 입주자가 됐다.

청구 정확성에 직결되는 세 가지를 계약에 박았다.

1. **멱등성** — Kafka 는 at-least-once 다. `id`(Envoy `x-request-id`)로 중복을
   제거하지 않으면 **고객에게 과다 청구한다.**
2. **관측 시각** — `time` 이 청구 주기 귀속을 정한다. 수집 시각이 아니다.
3. **결과와 무관하게 전부 낸다** — `status` 를 실어 미터가 고르게 한다. 5xx
   청구는 방어할 수 없고, 4xx 청구 여부는 **요금제가 정할 문제이지 계량기가
   정할 문제가 아니다.**

#### 함정 둘

★ **`logFormat.labels` 를 쓰면 안 된다.** 값이 전부 문자열이 되어 `status` 가
`"200"` 으로 나가고 스키마를 깬다. `text` 에 원시 JSON 을 넣어야 정수가 정수로
나간다. 계약이 정수를 요구하는데 계량기가 문자열을 내면 파서가 조용히 어긋난다.

★ **meshConfig 는 ConfigMap 안의 YAML 문자열**이라 `kubectl patch` 로 문자열
조작을 하면 깨진다. 파싱해서 병합하는 스크립트를 따로 뒀다
(`local/configure-istio-usage-logging.sh`). 작성 중 `python3 - <<PY <<<"$cur"`
로 stdin 리다이렉션을 둘 두어 **YAML 이 파이썬 스크립트로 읽히는** 실수를 한 번
했다 — 뒤엣것이 이긴다.

#### 실측 — 계약대로 나온다

```json
{"specversion":"1.0","id":"f8b9880b-e6e8-4f40-b13e-39b44547d604",
 "source":"//gateway.oneinchmarket.local/istio",
 "type":"io.oneinchmarket.api.request.v1","subject":"acme-corp",
 "time":"2026-09-04T18:18:16.724Z","datacontenttype":"application/json",
 "data":{"route":"local.api.0","method":"GET","status":200,
         "duration_ms":3,"request_bytes":0,"response_bytes":49}}
```

스키마 검증 **3/3 통과**, 멱등성 키 **3/3 유일**.

#### 아직 안 된 것 — 이대로는 과금에 쓸 수 없다

★★ **`subject` 를 클라이언트가 보내는 헤더에서 그대로 읽는다.** Keycloak JWT 의
테넌트 클레임을 게이트웨이가 검증해 내려주는 배선이 없다. 지금은 아무나
`X-OIM-Tenant: 남의회사` 를 보내면 그 회사에 청구된다. **이것을 고치기 전에는
계량 결과를 인보이스에 쓰면 안 된다**(ADR-071 미결).

- 액세스 로그 → Kafka `api-usage` 다리도 아직 없다(형식이 확정됐으므로 이제
  만들 수 있다).
- 계량 백엔드 미정(ADR-072). OpenMeter 가 유력하나 **차트를 찾지 못해 배포
  규모를 검증하지 못했다.** ADR-069 가 OpenReplay 에 요구한 규율을 여기에도
  적용해 보류했다. 노드 메모리 requests 가 **88%** 인 것도 이유다.
- ClickHouse 범위(ADR-070)와 충돌하므로 개정 여부를 함께 정해야 한다(ADR-073).


### 8-54. 과금 신원 배선 — 클라이언트가 보내는 테넌트를 더 이상 믿지 않는다

§8-53 이 남긴 미결이다. 계량은 되는데 `subject`(청구 대상)를 클라이언트가
보내는 `X-OIM-Tenant` 헤더에서 그대로 읽고 있었다. 아무나
`X-OIM-Tenant: 남의회사` 를 보내면 그 회사에 청구되는 상태였다.

#### 세운 것

```
Keycloak realm oneinchmarket  +  클라이언트 acme-corp
   -> 하드코딩 클레임 매퍼로 tenant=acme-corp 를 토큰에 박는다
RequestAuthentication(api-jwt)
   -> JWT 검증 + outputClaimToHeaders 로 tenant 를 x-oim-tenant 에 **덮어쓴다**
AuthorizationPolicy(api-require-jwt)
   -> 토큰 없는 요청 차단
```

realm 부트스트랩이 레포에 아예 없어 `master` 하나뿐이었다. master 는 Keycloak
자체의 관리 realm 이라 거기에 고객 클라이언트를 넣으면 관리 권한 경계와 과금
대상 경계가 섞인다. 별도 realm 을 만들었다.

테넌트는 **클라이언트에 박힌 하드코딩 클레임**이다. 사용자 속성이 아니다 —
API 과금은 client_credentials(기계 대 기계)라 사람이 없고, 담당자가 바뀌어도
청구 주체는 유지되어야 한다(계약의 `subject` 정의와 같은 이유).

#### 검증 — 네 경우

| | 요청 | 결과 |
|---|---|---|
| ① | 토큰 없음 | **403** |
| ② | 토큰 없이 헤더만 위조 | **403** |
| ③ | 정상 토큰 | **200** |
| ④ | 정상 토큰 + 위조 헤더 `victim-corp` | **200, 기록된 subject = `acme-corp`** |

④ 가 이 작업의 전부다. 클라이언트가 보낸 값이 **클레임에서 나온 값으로
대체**되므로 위조가 통하지 않는다.

#### 두 번 물렸다 — 둘 다 "유효한 토큰이 전부 401"

증상이 같아서 원인을 구분하기 어려웠다. **게이트웨이 로그에는 단서가 없고
istiod 로그에만 남는다.**

**첫째, 단축 서비스명.** `jwksUri` 를 `keycloak-headless:8080` 으로 썼는데
`dial tcp: lookup keycloak-head...` 로 실패했다.
**JWKS 를 가져오는 주체가 게이트웨이가 아니라 `istio-system` 의 istiod** 라서
`local` 네임스페이스의 단축명이 풀리지 않는다. FQDN 이어야 한다.
`issuer` 는 토큰의 `iss` 와 맞춰야 하므로 단축명 그대로 두고 `jwksUri` 만 고친다 —
두 필드의 값이 서로 달라도 되는 이유다.

**둘째, NetworkPolicy.** FQDN 으로 고쳐도 `context deadline exceeded` 였다.
Keycloak 에는 ingress 허용 규칙이 **하나도 없었다.** 그런데도 클러스터 안에서는
잘 붙었다 — 양쪽이 ambient 라 트래픽이 HBONE(15008)로 흐르고 그 포트는
`allow-istio-hbone` 이 허용하기 때문이다. **istio-system 은 메시 밖이라 평문
8080 으로 오고 그것만 막혔다.** Gotcha 13 과 같은 계열이고, 이 문서에서 네 번째다.

★ 정책을 고친 뒤에도 401 이 계속됐다. **istiod 가 JWKS 실패를 캐시하고 곧바로
재시도하지 않는다.** 재시작해야 다시 가져온다. "정책은 고쳤는데 여전히 안 된다"
로 보이므로 컨트롤 플레인 재시작을 확인 절차에 넣어야 한다.

#### 남은 것

- 액세스 로그 → Kafka `api-usage` 다리(형식·신원이 확정됐으므로 이제 만들 수 있다)
- 계량 백엔드 결정(ADR-072) — OpenMeter 규모 미검증, ADR-070 개정 여부
- 고객마다 클라이언트를 만드는 절차. 지금은 스모크 테넌트 하나뿐이다
- `accessTokenLifespan` 300초. 토큰 갱신 실패가 곧 과금 누락이 되므로 클라이언트
  쪽 재시도 정책이 필요하다

## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [APP-INTEGRATION.md](./APP-INTEGRATION.md) — **애플리케이션 연동 가이드.** 앱 개발 시 여기부터 볼 것
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
