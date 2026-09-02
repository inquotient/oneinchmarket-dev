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
| 7 | security-full — SafeLine · Kubescape · DT · DefectDojo · Caldera | ~25 | **zram 실측 지점** |

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
## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
