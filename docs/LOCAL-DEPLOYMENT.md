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
| 2 | Loki · Tempo · OTel(agent·gateway) | ~12 | 미착수 |
| 3 | governance — DS389 · LAM · Solr · Ranger 2종 · Knox | ~25 | 미착수 |
| 4 | security-min — Tetragon · Trivy Operator · Policy Reporter · Vault · Wazuh 2종 | ~20 | 미착수 |
| 5 | lakehouse-v1 — ZK · Hadoop 4종 · HBase 2종 · Hive Server | ~35 | **설계 선행 필요** |
| 6 | GlitchTip · Jenkins · Kafka Bridge · Apicurio Studio 4종 | ~20 | 미착수 |
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

#### ★ 다음 단계 전에 풀어야 할 제약 — CPU 가 메모리보다 먼저 막힌다

1단계 완료 시점:

```
requests   메모리 46% (21.4/45 GiB)   CPU 66% (12.7/19)
limits     메모리 70%                  CPU 123% (오버커밋)
```

**남은 ~130종을 올리면 CPU requests 에서 스케줄이 먼저 실패한다.** 메모리 예산(zram 포함)은 여유가 있으나 CPU 는 아니다.

조치:
1. `.wslconfig` 의 `processors=20` → **24** (호스트 전량)
2. `local/kubelet-config.yaml` 의 `systemReserved.cpu`·`kubeReserved.cpu` 를 500m → 250m
3. 신규 서비스의 `requests.cpu` 를 50~100m 로 억제

#### 5단계는 설계가 선행되어야 한다

- **TODO-33** — Hive warehouse 를 HDFS 로 되돌릴지, S3A 를 유지하고 HDFS 를 별도 용도로 둘지, Trino 에 두 카탈로그를 병행할지 미결
- **Kerberos 채택 여부** — 현재 `hadoop.security.authentication = simple`. Hadoop 네이티브 CLI 접근 요구가 없으면 불필요(§8-3 관련 논의)
- **hbase:2.6.3 로컬 빌드** — `v1/hbase/Dockerfile` 기반. 레지스트리 경로 필요(TODO-37)

#### 3단계 착수 전 반영할 버전 조사 결과

| 구성요소 | v1 기재 | 실제 | 비고 |
|---|---|---|---|
| Ranger | `apache/ranger:2.7.0` | **2.9.0** | 2세대 뒤처짐. 스키마 마이그레이션 동반 |
| ranger-usersync | `eclipse-temurin:8u452...` | **17-jdk** | JDK 8 은 EOL. Ranger 2.9 는 11+ 요구 |
| Knox | `knox-gateway:2.1.0` **(로컬 빌드)** | **`apache/knox:2.1.0` 공식 이미지 존재** | **로컬 빌드 불필요.** TODO-37 축소, `DEPLOYMENT.md §6-4` 의 Oracle Ampere 논거도 약화 |
| Solr | `apache/solr:9.10.0-slim` | **존재하지 않음** → `solr:10.0.0-slim` | `apache/solr` 저장소에 태그가 없다. `library/solr` 가 맞다 |
| DS389 | `389ds/dirsrv:latest` | 3.1 | |
| LAM | `ldapaccountmanager/lam:latest` | 8.3 | |

Knox 릴리스는 **2.1.0 이 최신**이다. Docker Hub 의 `3.0` 은 RC(`3.0.0-RC1`·`RC2`)이므로 채택하지 않는다.

`postgres-bootstrap` 에 **`ranger` DB·롤 추가**가 3단계의 선행 작업이다(문서에 이미 `(+복원 시 ranger)` 로 표기되어 있다).

## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
