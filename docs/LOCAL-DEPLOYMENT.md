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
| ~~**W3**~~ | ~~W2 조치 후에도 Falco 동일 실패~~ | ~~modern_ebpf 프로브가 WSL2 커널에서 기동 불가~~ | **소멸(§8-64, 2026-09-05).** 커널 탓이 아니라 이미지가 2024년판(`falco-no-driver` 0.39.2)이었다. 유지되는 저장소의 0.44.1 에서 modern_ebpf 가 정상 동작한다. **WSL2 고유 블로커는 이제 2건이다** |

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
| WSL2 고유 | ~~3~~ → **2** | 마운트 전파 · debugfs (~~Falco~~ — §8-64 에서 소멸) |
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

> **★ 이 절의 결론은 §8-64 에서 뒤집혔다(2026-09-05).** 원인 규명(attach 단계
> EINVAL, 버전 간 비호환)은 옳았으나 **"더 새 Falco 가 없다" 가 틀렸다** —
> `falcosecurity/falco-no-driver` 는 버려진 저장소이고 유지되는 쪽
> (`falcosecurity/falco`)에 0.44.1 이 있다. 그것으로 올리니 Falco 가 돈다.
> 아래는 그 시점의 기록으로 남긴다.


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


### 8-55. Kafka 다리 — Envoy ALS 를 버리고 stdout 경로로 완성했다

§8-54 다음 단계로 게이트웨이 액세스 로그를 Kafka `api-usage` 토픽에 넣으려
했다. **구성은 전부 섰으나 이벤트가 도달하지 않는다. 원인을 규명하지 못했다.**

#### 만든 것 (전부 개별 검증됨)

```
Istio meshConfig  extensionProvider api-usage-otel (envoyOtelAls -> 4319)  ✅
Telemetry         api-usage 가 두 제공자를 쓴다(stdout + OTLP)              ✅
otel-gateway      otlp/usage(4319) 수신기 · kafka/usage 내보내기 · logs/usage ✅
Kafka             api-usage 토픽 생성                                       ✅
AuthorizationPolicy / NetworkPolicy  otel-gateway·kafka-topics 신원 추가     ✅
```

- 게이트웨이 Envoy 의 config_dump 에 `envoy.access_loggers.open_telemetry` 가
  7건 있고 `cluster_name: outbound|4319||otel-gateway.local.svc.cluster.local`
  로 정확히 잡혀 있다.
- ztunnel 로그에 게이트웨이 → otel-gateway:4319 연결이 **25초 지속**되며
  `bytes_sent=1023 bytes_recv=732` 로 데이터가 오갔다.
- 수집기는 4319 를 포함해 gRPC 서버 2개를 열고 정상 기동했다. 오류 로그가 없다.

#### 그런데 흐르지 않는다

수집기 내부 지표가 명확하다.

```
otelcol_receiver_accepted_log_records{receiver="otlp"}       23692
otelcol_receiver_accepted_log_records{receiver="otlp/usage"}  (항목 자체가 없다)
```

`otlp/usage` 수신기는 **레코드를 한 건도 받은 적이 없다.** 토픽도 비어 있다.
Envoy 통계에도 `access_logs.*` 나 otel-gateway 클러스터 항목이 나타나지 않는다.

#### 도중에 고친 결함 세 가지 (이것들은 실제 결함이었다)

1. **파이프라인이 `service.telemetry` 아래로 들어갔다.** awk 로 삽입할 때
   `metrics:` 를 처음 만나는 곳이 `telemetry` 였다.
   `'service.telemetry' has invalid keys: logs/usage` 로 수집기가 기동하지 않는다.
2. **Kafka exporter 스키마가 바뀌었다.** 최신 contrib 수집기는 `topic`·`encoding`
   을 **신호별 블록**(`logs:`) 아래로 옮겼다. 최상위에 두면
   `'kafkaexporter.Config' has invalid keys: encoding, topic` 로 죽는다.
3. **`kafka-topics` Job 이 `default` SA 로 돌아** ztunnel 이 Kafka 접근을
   거부했다(30건/5분). **부트스트랩 Job 세 번째 사례다**(§8-52 의 ILM·
   마이그레이션에 이어). 평소에 돌지 않아 편입 시점에 드러나지 않고,
   재실행할 때 비로소 막힌다.

#### 중간에 미완으로 남겼던 이유 (기록)

★ 이 시점에 "완료" 로 적을 뻔했다. 구성이 서 있고 오류가 없고 연결까지 보여
**성공처럼 보였다.** §8-47·§8-50·§8-52 에서 반복해 적은 "성공 출력이 성공을
뜻하지 않는다" 의 또 다른 사례였고, **판정을 수집기 지표와 토픽 내용으로 한
덕에** 함정을 피했다. 아래가 그 다음에 실제로 규명한 내용이다.


#### 결말 — Envoy ALS 는 포기하고 stdout 경로로 완성했다

##### 원인 규명 (합성 OTLP 로 두 후보를 갈랐다)

수집기 4319 에 **HTTP 프로토콜을 임시로 열어** 합성 CloudEvents 를 직접 넣었다.

```
otelcol_receiver_accepted_log_records{receiver="otlp/usage",transport="http"} 1
otelcol_exporter_sent_log_records{exporter="kafka/usage"} 1
-> 토픽에 도착
```

**수집기 -> Kafka 는 멀쩡했다.** 문제는 Envoy 쪽으로 확정됐다.

Envoy 디버그 로깅을 켜니 결정적 단서가 나왔다.

```
router.cc:527  cluster 'outbound|4319||otel-gateway...' match for URL
               '/opentelemetry.proto.collector...'
router.cc:1384 upstream reset: reset reason: protocol error
```

- 클러스터 정의·엔드포인트 healthy·`cx_total::2`·`rq_error::2`
- ztunnel 구간은 무오류(`connection complete`)
- 게이트웨이를 ambient 에서 빼도, 수집기를 빼도 동일

즉 **Istio 1.24.2 의 `envoyOtelAls` 와 수집기 0.160 의 OTLP gRPC 수신기가
HTTP/2 수준에서 맞지 않는다.** 설정은 전부 정확했다(config_dump 확인).

##### 그래서 이미 검증된 경로를 썼다

게이트웨이는 **stdout 으로 계약 JSON 을 이미 정확히 내고 있었다.** otel-agent 가
호스트 로그를 마운트하고 있으므로, **게이트웨이 로그만 겨냥한 전용 filelog
수신기**를 붙였다.

```
filelog/usage  include: /var/log/pods/local_ingress-istio-*/istio-proxy/*.log
               -> logs/usage 파이프라인 -> kafka/usage -> api-usage 토픽
```

일반 `filelog` 와 **수신기 자체를 분리**했다. 같은 수신기에 필터를 걸어 가르면
필터가 조용히 어긋날 때 청구 데이터가 오염된다. include 글롭이 범위를 정하므로
어긋날 여지가 없다.

##### 여기서 또 세 번 물렸다

1. **`expr` 이스케이프.** `body not matches "^\{\"specversion\""` 는
   `invalid char escape` 로 **수집기가 기동하지 않는다.** expr 은 자체
   이스케이프 규칙이 있다. 특수문자 없는 최소 패턴(`"specversion"`)이면 충분하다.
2. **`container` 연산자 실패.** `Failed to process entry` 가 나면서 CRI 접두가
   그대로 남아 Kafka 메시지가
   `2026-09-05T... stdout F {"specversion"...}` 로 들어갔다. 형식이 고정되어
   있으므로 `regex_parser` 로 직접 뗐다.
3. **★ `raw` 인코딩이 문자열 본문을 JSON 으로 한 번 더 감쌌다.**
   토픽의 실제 첫 바이트가 `"` 였다(`od -c` 로 확인). 계약은 순수 JSON 객체를
   요구하므로 소비자가 두 번 파싱해야 하는 상태였다. `encoding: text` 는 이
   버전에 없다(`unrecognized logs encoding "text"`).
   **본문을 `json_parser` 로 맵으로 만들면** `raw` 가 그대로 직렬화한다.

##### 최종 검증

```
토픽 메시지 첫 바이트            {        (순수 JSON 객체)
계약 스키마 검증                 8/8 통과
멱등성 키(x-request-id) 유일     8/8
subject                          전부 acme-corp
   ★ 요청에는 X-OIM-Tenant: victim-corp 를 실었다.
     JWT 클레임에서 나온 값이 이겼다(§8-54).
```

**ADR-071 의 계량 경로가 끝까지 살아 있다.**

##### 남은 것

- 파티션 키를 `subject` 로 두는 것(계약 명시). 현재는 기본 분배다 —
  한 테넌트의 이벤트 순서가 보장되지 않는다.
- 계량 백엔드 결정(ADR-072). 여전히 OpenMeter 규모를 검증하지 못했다.
- 로그 회전 시 유실 여부. `storage: file_storage` 로 오프셋을 남기지만
  실측하지 않았다.


### 8-56. 과금 파이프라인 마무리 — 파티션 키·백엔드 규모·유실 검증

§8-55 가 남긴 셋을 처리했다. **둘은 해소, 하나는 미충족으로 확정**했다.

#### 1. 파티션 키 — 미충족으로 확정했다 (설정을 남기지 않는다)

계약이 "파티션 키는 `subject`(테넌트)" 를 규정한다. 구현을 시도했다.

- 리소스 속성 `tenant` 를 붙이는 데는 성공했다. **debug exporter 로
  `Resource attributes: -> tenant: Str(acme-corp)` 를 직접 확인**했다.
  (stanza 연산자의 필드 표기는 OTTL 과 달라 `resource["tenant"]` 가 아니라
  `resource.tenant` 다. 전자는 오류 없이 조용히 빗나간다.)
- 그런데 `partition_logs_by_resource_attributes: true` 를 켜도 **메시지 key 가
  계속 `null`** 이었다. `logs:` 블록 아래에 두면 `invalid keys` 로 기동 실패라
  최상위가 맞고, 최상위에서 `raw`·`otlp_json` 어느 인코딩으로도 키가 생기지
  않았다.

★ **효과 없는 설정을 남기지 않았다.** 켜 두면 다음 사람이 "파티션은 되고 있다"
로 읽는다 — 이 레포에서 반복된 실패 방식이다. `false` 로 두고 사유를 매니페스트와
계약(`contracts/asyncapi/api-usage.yaml`) 양쪽에 적었다.

과금 정확성은 이것에 의존하지 않는다 — 멱등성 키(`id`)가 중복을 막고 관측
시각(`time`)이 청구 주기를 정한다. 순서가 필요한 집계 방식을 택할 때 다시 본다.

#### 2. ★ 인코딩 실험이 과금 토픽을 오염시켰다

키를 붙이려고 `encoding` 을 `otlp_json` 으로 잠깐 바꿔 시험했다. 되돌린 뒤
계약 검증을 돌리니 **29건 중 2건이 실패**했다 — OTLP 봉투가 씌워진 메시지가
토픽에 그대로 남아 있었다.

```
{"resourceLogs":[{"resource":{"attributes":[{"key":"tenant",...
```

랩이라 토픽을 재생성하고 끝냈지만(청구 이력 없음), **운영에서는 이럴 수 없다.**
남기는 교훈 둘:

- **과금 토픽에 대고 실험하지 말 것.** 별도 토픽에서 검증하고 옮긴다.
- **소비자는 계약을 만족하지 않는 메시지를 청구하지 말고 격리해야 한다.**
  계약이 이미 `subject` 가 `-` 인 이벤트에 대해 같은 요구를 하고 있는데,
  스키마 불일치도 같은 취급이 필요하다.

#### 3. 백엔드 규모 — 실측 완료 (보류 해제)

차트를 찾아 렌더했다(`oci://ghcr.io/openmeterio/helm-charts/openmeter`,
`1.0.0-beta.232`). §8-55 에서 "찾지 못해 검증하지 못했다" 고 적은 것을 해소했다.

| | 기본값 | 기존 인프라 재사용 |
|---|---|---|
| Deployment | 7 | **6** |
| StatefulSet | 4 | **0** |
| CronJob | 3 | 3 |
| 렌더 | 3,666줄 | **825줄** |

★ 기본값으로 넣으면 **Kafka·PostgreSQL·Redis 를 자기 것으로 또 세운다**
(bitnami subchart). 셋 다 이미 있으므로 꺼야 한다.

★ ClickHouse 는 Altinity 오퍼레이터 + `ClickHouseInstallation` CR 로 오므로
기존 `clickhouse-0`(OpenReplay)과 **별개 인스턴스**가 된다 — ADR-070 개정
문제와 직결된다(ADR-073 에 선택지 3안을 적었다).

**판단**: 규모는 수용 가능하나 노드 메모리 requests 가 88% 라 올리기 전에
여유 확보가 선행되어야 한다.

#### 4. 유실 검증 — 통과

에이전트 재시작을 사이에 끼우고 요청 10건을 보냈다.

```
재시작 전 5건 · 재시작 중/후 5건 -> 토픽 증가 정확히 10건
```

`storage: file_storage` 로 남긴 오프셋이 실제로 동작한다. **로그 회전 자체는
아직 시험하지 못했다**(파일이 회전할 만큼 트래픽이 쌓이지 않았다) — 재시작
내성만 확인한 것이다.

#### 현재 상태

```
계약 검증        5/5 통과 (깨끗한 토픽 기준)
멱등성 키        5/5 유일
subject          전부 클레임 값(위조 헤더를 실어도)
파티션 키        null — 미충족, 사유 기록
```


### 8-57. ADR-073 배선 확인 · 회전 시험은 방법이 틀렸다

#### 1. OpenMeter 를 기존 인프라에 물릴 수 있다 (ADR-073 미확인 해소)

§8-56 에서 "차트의 ClickHouse 를 끄고 접속 설정을 밖에서 덮어야 하는데 그
배선은 아직 확인하지 않았다" 고 남긴 것을 실측했다.

차트의 `config:` 는 **자유 형식**이고 렌더된 ConfigMap 이 그대로 OpenMeter
설정이 된다. 주소는 그냥 값이다.

```yaml
aggregation:
  clickhouse:
    address: clickhouse-headless:9000    # 기존 인스턴스
ingest:
  kafka:
    broker: kafka-headless:9092
```

번들된 Kafka·PostgreSQL·Redis·ClickHouse·**Svix** 는 차트 문서가 스스로
**"Not recommended for production environments"** 라고 적어 둔 개발 편의용이다.
(Svix 는 웹훅 서버다 — §8-56 에서 세지 못했다.)

| | 기본값 | 인프라 재사용 | + Svix 끔 |
|---|---|---|---|
| Deployment | 7 | 6 | **5** |
| StatefulSet | 4 | 0 | **0** |
| CronJob | 3 | 3 | 3 |
| 렌더 | 3,666줄 | 825줄 | **583줄** |

**ⓐ(ClickHouse 인스턴스 2개)를 택할 이유가 없다.** ⓑ 로 가면 새로 세우는 것은
OpenMeter 자체 워크로드 8개뿐이고 ADR-070 을 "용도 2개" 로 개정하면 된다.
남은 결정은 ⓑ vs ⓒ(직접 만든다)이고 사용자 판단이 필요하다.

#### 2. ★ 로그 회전 시험 — 내 방법이 틀렸다 (결함이 아니었다)

`mv 0.log 0.log.1 && touch 0.log` 로 회전을 흉내내고 요청 7건을 보냈더니
**3건만 도달**했다. 처음에는 "회전 시 4건 유실" 로 읽었다.

확인해 보니 **새 `0.log` 가 0바이트**였다. Envoy 는 열린 fd(이제 `0.log.1`)에
계속 쓰고 있었다 — **프로세스의 fd 는 `mv` 를 따라가지 않는다.** 실제 kubelet
회전은 컨테이너 런타임이 파일 전환까지 처리하므로 이것과 다르다.

즉 **유실은 파이프라인 결함이 아니라 시험 방법의 결함이다.** 4건은 애초에
새 파일에 쓰이지 않았다.

★ 이것을 "유실 4건" 으로 적었다면 있지도 않은 결함을 문서에 남길 뻔했다.
**측정값이 이상하면 측정 방법부터 의심할 것.**

제대로 하려면 컨테이너 로그를 실제로 회전시켜야 한다(`containerLogMaxSize`
를 낮추고 그만큼 트래픽을 흘리거나, kubelet 회전을 유발). **아직 하지 않았다 —
회전 내성은 미검증으로 남는다.**

#### 3. 부수 확인 — 파드 교체는 견딘다

복구하느라 게이트웨이 파드를 재시작했다. 로그 디렉터리 이름이 바뀌는데
(`local_ingress-istio-<새해시>_<새uid>`) **글롭이 따라잡았다.**

```
계약 검증 23/23 · 멱등성 키 23/23 유일 · subject 전부 클레임 값
```

파드 교체와 에이전트 재시작(§8-56)은 견딘다. 남은 미검증은 **파일 회전** 하나다.


### 8-58. OpenMeter 도입 — ClickHouse 를 공유한다 (ADR-070 개정)

사용자가 ADR-073 의 ⓑ(기존 ClickHouse 공유)를 택했다. 배포하고 수집→집계까지
확인했다.

#### 결과

```
Deployment 5 + CronJob 3 전부 Running
수집 API  POST /api/v1/events -> 204
ClickHouse openmeter.om_events -> 1건 적재
미터 조회  api_requests_total -> value: 1
ClickHouse 테이블  openreplay 1 · openmeter 1   (공유 성립, 서로 침범 없음)
Ready 85/87 · ztunnel 거부 0건
```

#### 어떻게 넣었나

`local/render-openmeter.sh` + `local/openmeter-values.yaml` 로 렌더해
`kubernetes/overlays/local/openmeter/openmeter.yaml` 을 커밋한다. OpenReplay·
Tetragon 과 같은 방식이다 — **Helm 을 배포가 아니라 생성 도구로만 쓴다**
(ADR-003 유지).

후처리(`render-openmeter.py`)가 차트에 없는 것을 넣는다: 규약 라벨,
securityContext, 그리고 **비밀번호 치환 initContainer**.

#### ★ 자격 처리 — 차트에 넣을 자리가 없었다

차트에는 `extraEnv` 도 secret 마운트도 없고, **환경변수 오버라이드도 먹지
않는다.** 네 가지 표기법을 실측했다:

```
OPENMETER_AGGREGATION_CLICKHOUSE_PASSWORD     무시
OPENMETER_AGGREGATION__CLICKHOUSE__PASSWORD   무시
AGGREGATION_CLICKHOUSE_PASSWORD               무시
AGGREGATION__CLICKHOUSE__PASSWORD             무시
```

설정 파일이 유일한 경로인데 그것은 ConfigMap 이다. **평문 비밀번호를 ConfigMap
에 두지 않기 위해** ranger-usersync 와 같은 패턴을 썼다 — 자리표시자를 넣은
설정을 ConfigMap 에 두고, initContainer 가 Secret 에서 읽어 emptyDir 로 치환해
내보내며, 본 컨테이너는 그것을 읽는다. 치환이 남으면 **기동을 멈춘다.**

#### 세 번 막혔고 세 번 다 다른 원인이었다

| 증상 | 원인 |
|---|---|
| `code: 516 default: Authentication failed` | ClickHouse 의 **`default` 사용자가 이 인스턴스에 없다**(system.users 에 openreplay 뿐). 로컬 `clickhouse-client` 가 자격 없이 붙는 것에 속기 쉽다 — 원격은 실제 사용자가 필요하다. 전용 `openmeter` 사용자를 만들고 `openmeter.*` 로만 권한을 줬다 |
| `failed to initialize database` | **PostgreSQL 이 필요하다.** §8-56 에서 "postgres/redis 참조는 전부 Svix" 로 읽은 것은 **렌더된 매니페스트 텍스트만 본 것**이고 런타임 요구는 별개였다. 전용 롤·DB 를 만들었다 |
| sink-worker 가 `127.0.0.1:29092` 로 붙어 CrashLoop | **`ingest.kafka.broker`(단수)와 `sink.kafka.brokers`(복수)가 다른 키다.** ingest 만 설정하면 sink 는 기본값으로 간다. 오류는 sink-worker 로그에만 나온다 |
| 수집 API 500 `NOAUTH Authentication required` | dedupe 용 **Redis 에 비밀번호가 걸려 있다.** 중복 제거 단계라 이벤트가 아예 들어가지 못한다 |

★ 마지막 것을 고칠 때 **`sed -i '80a\...'` 로 넣은 줄이 셸 스크립트 2행에
들어가** 명령이 깨졌다. 렌더 결과에 `password` 줄이 통째로 사라졌는데도
initContainer 는 `완료` 를 출력했다 — 또 하나의 "성공 출력이 성공이 아닌"
사례다. 배포된 ConfigMap 과 파드 안의 파일을 **둘 다** 확인해서야 알았다.

#### 자격 분리

| 자격 | 범위 |
|---|---|
| ClickHouse `openmeter` | `GRANT ALL ON openmeter.*` — OpenReplay 데이터에 닿지 못한다 |
| PostgreSQL `openmeter` | 자기 DB 소유자 |
| Redis | 기존 공유 자격(전용 분리는 하지 않았다 — Redis 는 ACL 을 쓰지 않는다) |

#### 아직 안 된 것

★★ **`api-usage` 토픽과 OpenMeter 사이에 다리가 없다.** OpenMeter 는 자기
토픽을 스스로 만들고 **HTTP API 로만** 수집한다. 지금 계량 이벤트는
`api-usage` 에 쌓이고 OpenMeter 는 그것을 읽지 않는다. 위 검증은 API 에 직접
넣어서 한 것이다. 다리가 ADR-072 의 다음 증분이다.

- ADR-070 을 "ClickHouse 용도 2개" 로 개정해야 한다(문서 반영은 이 커밋에서).
- 요금제·구독 설정은 아직 없다. 미터 2종만 정의했다.


### 8-59. 다리 완성 — 게이트웨이에서 인보이스 근거까지 한 줄로 이어졌다

§8-58 이 남긴 마지막 구간이다. `api-usage` 토픽과 OpenMeter 사이에 다리를 놓았다.

#### 새 컴포넌트를 만들지 않았다

OpenMeter 는 HTTP API 로만 수집한다. 컨슈머를 새로 쓰는 대신 **이미 Kafka 를
소비하는 Logstash** 를 썼다 — 이 플랫폼에서 Kafka→X 다리는 원래 그것의 역할이다.

```
kafka(api-usage) ──▶ logstash ──▶ POST openmeter-api/api/v1/events
```

★ 기존 kafka 입력에 토픽만 더하지 않고 **입력을 분리했다.** 그쪽은
`codec => json` 이라 이벤트가 파싱되어 Logstash 필드(@timestamp·@version·tags)가
섞인다. OpenMeter 는 CloudEvents 를 그대로 받아야 하므로 `codec => plain` 으로
원문을 `message` 에 담아 보낸다. Suricata 입력을 따로 둔 것과 같은 이유다.

★ `group_id` 도 분리했다. SIEM 소비자와 오프셋을 공유하면 한쪽의 재처리가
다른 쪽의 유실이 된다.

★ 이 분기는 **Elasticsearch 로 가지 않는다.** 계량 이벤트는 OpenMeter 가 집계
원천이고, ES 에 또 넣으면 같은 사실이 두 저장소에 남아 어느 쪽이 청구 근거인지
모호해진다.

#### 한 번 막혔다 — Content-Type

```
400  header Content-Type has unexpected value "text/plain"
```

`format => "message"` 가 Content-Type 을 `text/plain` 으로 강제한다.
**`headers` 로 넣어도 덮인다** — 전용 `content_type` 설정을 써야 한다.

진단이 빨랐던 이유는 구간마다 확인할 지표가 있었기 때문이다:

```
① api-usage 토픽        29건        (게이트웨이→토픽 정상)
② 컨슈머 그룹 LAG        0          (logstash 가 소비함)
③ logstash 로그          400 응답    ← 여기
```

#### 최종 검증 — 전 구간

```
게이트웨이로 요청 6건 (X-OIM-Tenant: victim-corp 위조 헤더 포함)
  ↓
ClickHouse openmeter.om_events   1 → 7   (정확히 6 증가)
미터 api_requests_total          value: 7
subject                          acme-corp 7건 — 전부 클레임 값
id 유일성                        7 / 7
```

**위조 헤더를 실었는데도 청구 대상은 JWT 클레임에서 나온 값이다**(§8-54).
게이트웨이에서 인보이스 근거까지 한 줄로 이어졌다.

```
브라우저/클라이언트
  → Istio Gateway (JWT 검증 · tenant 클레임을 헤더로 덮어씀)
  → Envoy 액세스 로그 (계약 형식 CloudEvents)
  → otel-agent filelog → Kafka api-usage
  → Logstash 다리 → OpenMeter 수집 API
  → Redis 중복 제거 → ClickHouse openmeter.om_events
  → 미터 집계
```

#### 아직 없는 것

- **요금제·구독·가격**. 미터 2종만 정의했고 무엇을 얼마에 팔지는 없다.
  인보이스를 실제로 발행하려면 그것이 필요하다.
- 다리의 유실 특성. Logstash 는 재시도하지만 **영구 실패 시 이벤트를 버린다** —
  dead-letter 경로가 없다. 과금에서는 그것이 매출 누락이다.
- `subject` 가 `-` 인 이벤트(테넌트 없는 요청)를 격리하는 규칙. 계약이 요구하는데
  아직 다리에 없다 — 지금은 OpenMeter 로 그대로 넘어간다.


### 8-60. 테스트 데이터로 과금 경로를 검증했다 — 결함 둘을 찾아 고쳤다

단일 테넌트·소량으로는 과금의 핵심(귀속·중복제거·상태 구분)을 확인할 수 없다.
**두 번째 테넌트를 만들고 의도적으로 다른 부하를 흘렸다.**

#### 검증한 것

| 항목 | 기대 | 실측 |
|---|---|---|
| 테넌트 귀속 | acme 20 · globex 4 | **일치** |
| 상태코드 분리 | acme 200×17 · 404×3 | **일치** |
| 위조 헤더 | 클레임 값이 이긴다 | `X-OIM-Tenant: freeloader` → `-` |
| **중복 제거** | 같은 `id` 3회 → 1건 | **1건** (Redis dedupe 동작) |
| 테넌트별 미터 | acme 20 · globex 4 | **일치** |

★ 중복 제거가 실제로 동작하는 것을 확인한 것이 이 시험의 가장 큰 소득이다.
Kafka 는 at-least-once 이고, 이것이 없으면 **고객에게 과다 청구한다.**
같은 `id` 를 세 번 보내 세 번 다 `204` 를 받았지만 저장은 1건이다.

#### ★ 결함 ① — 미터의 JSONPath 기준점이 틀렸다 (조용한 실패)

`groupBy=status` 가 `{"status":""}` 로 나왔다. 처음에는 `status` 가 정수라
그런 줄 알았으나 **`route`(문자열)도 빈 값**이었다.

원인: **JSONPath 의 기준점은 이벤트 전체가 아니라 `data` 내부다.**
`$.data.route` 로 쓰면 아무것도 매칭되지 않는다 — `$.route` 가 맞다.

★ 오류가 나지 않는다. 집계가 조용히 뭉개질 뿐이다. 그 상태로 인보이스를
발행하면 **모든 요청이 한 덩어리로 청구되어 5xx 를 제외할 수 없다.**

고친 뒤:

```
groupBy=status →  {"status":"200"} value 23
                  {"status":"404"} value 5
```

★ 미터 정의는 **PostgreSQL 에 저장**되어 설정만 바꿔서는 갱신되지 않는다.
그리고 OpenMeter 는 불일치를 발견하면 **기동을 거부한다**:

```
failed to create config meters in database:
meter api_requests_total in database is not equal to the meter in config:
group by mismatch
```

조용히 덮지 않는 것은 옳은 설계다. DB 행을 지우고 재기동해야 한다.

#### ★ 결함 ② — 테넌트 없는 이벤트가 OpenMeter 로 넘어갔다

토큰 없는 요청 2건이 `subject: -` 로 OpenMeter 에 저장됐다. 위조 헤더는
게이트웨이가 덮어 `freeloader` 로 청구되지는 않았으나(그 부분은 옳게
동작했다), **계약이 요구하는 "격리" 가 구현되어 있지 않았다**(§8-59 에서
남은 것으로 적었던 항목이 실측으로 확인됐다).

Logstash 다리에 분기를 넣었다. `-` 인 이벤트는 OpenMeter 로 보내지 않고
**Elasticsearch 의 `api-usage-quarantine` 인덱스에 남긴다** — 실재하지 않는
고객이므로 청구하면 안 되고, 왜 테넌트가 없었는지 추적해야 하므로 버려도
안 된다.

검증:

```
토큰 없는 요청 4건
  → OpenMeter 의 subject='-'  2 → 2  (증가 0)
  → api-usage-quarantine       4건, tags: ["no_tenant"]
```

★ 구현 중 함정 하나 — `mutate` 의 `add_field` 는 기존 필드에 **배열로
덧붙는다.** 파이프라인 표시를 바꾸려면 `replace` 를 써야 한다.

#### 남은 것

- **요금제·구독·가격이 없다.** 미터로 "얼마나 썼는지" 는 나오지만 "얼마인지"
  는 없다. 인보이스 발행에는 그것이 필요하다.
- 다리의 dead-letter 경로. Logstash 는 재시도 후 영구 실패 시 이벤트를 버린다.
- `from` 파라미터를 준 미터 질의가 빈 결과를 냈다. 창 경계 문제로 보이나
  확인하지 않았다 — 인보이스는 기간 질의를 쓰므로 짚어야 한다.


### 8-61. 다리의 dead-letter — 실패를 분기 가능한 사건으로 만들었다

§8-59·§8-60 이 남긴 항목이다. **전달 실패 시 이벤트가 조용히 사라지고 있었다.**

#### 왜 출력 플러그인으로는 안 되는가

`http` **출력**은 재시도 후 영구 실패하면 이벤트를 버리고 로그 한 줄만 남긴다.
파이프라인에 실패를 돌려주지 않으므로 **분기할 수 없다.** 과금에서 그것은
매출 누락이고, 더 나쁜 것은 **얼마를 잃었는지 알 수 없다**는 점이다.

`http` **필터**로 바꿨다. 필터는 요청 결과를 이벤트에 남기므로 실패가
분기 가능한 사건이 된다.

```
kafka(api-usage)
  → http 필터로 POST
      성공 → drop        (ES 에 또 넣지 않는다 — 청구 근거가 둘이 되면 안 된다)
      실패 → api-usage-dlq 인덱스
      테넌트 없음 → api-usage-quarantine 인덱스
```

★ 원본 Kafka 토픽이 남아 있으므로 이벤트 자체가 소실되는 것은 아니다.
진짜 위험은 **오프셋이 전진해 다시 읽히지 않는 것**이고, DLQ 인덱스가
"무엇을 못 넣었는가" 의 기록이 된다.

#### 플러그인 옵션에서 두 번 막혔다

```
Unknown setting 'target_response_code' for http
Unknown setting 'retryable_codes' for http
```

- `target_response_code` 는 이 버전에 없다.
- `retryable_codes` 는 **출력 플러그인 전용**이다. 필터에 쓰면 기동하지 않는다.

★ 둘 다 **기동 자체가 실패**한다 — 조용히 무시되지 않는다. 그 편이 낫다.
분기 근거는 `tag_on_request_failure` 로 붙는 태그다. 이 플러그인은
**연결 실패와 비-2xx 응답 둘 다** 그 태그를 붙인다.

#### 검증 — 성공·실패·재처리 셋 다

```
① 성공 경로   요청 5건 → ClickHouse 34→39 (정확히 5)
              DLQ 인덱스 없음 (성공은 drop)

② 실패 경로   openmeter-api 를 replicas=0 으로 내리고 요청 4건
              → ClickHouse 39→39 (증가 0)
              → api-usage-dlq 4건

③ 재처리      DLQ 문서의 원문(message)을 그대로 재전송
              → 204, ClickHouse 39→40 (정확히 1)
```

★ ③ 이 핵심이다. DLQ 가 **재처리 가능한 원문**을 담고 있지 않으면 그것은
기록일 뿐 복구 수단이 아니다. `message` 필드에 CloudEvents 원문이 그대로
있어 다시 넣으면 그대로 적재된다.

#### 남은 것

- **재처리가 수동이다.** DLQ 를 읽어 다시 넣는 자동 경로가 없다. 지금은
  "무엇을 못 넣었는지 알 수 있다" 까지다.
- DLQ 가 쌓이는 것을 알리는 경보가 없다. 인덱스를 들여다봐야 안다.
- 중복 재처리는 안전하다 — OpenMeter 의 `id` 기반 중복 제거가 잡는다(§8-60).


### 8-62. DLQ 재처리 자동화 — Job 이 경보를 겸한다. 그리고 `from` 은 결함이 아니었다

#### 1. ★ `from` 질의는 정상이었다 — 내가 빈 구간을 조회했다

§8-60 에서 "`from` 을 준 미터 질의가 빈 결과를 냈다. 확인하지 않았다" 로
남겼던 항목이다. 확인하니 **결함이 아니다.**

```
from 없이                          value 34
from=2026-09-01 (과거)             value 34
from+to (하루 구간)                value 34
from+to+windowSize=DAY             value 34
```

당시 `from=06:35` 를 줬는데 그 시점 이후 이벤트가 실제로 없었다. 인보이스가
쓰는 기간 질의(`from`+`to`+`windowSize`)는 정확히 동작한다.

★ 미확인 항목을 "결함일 수 있다" 로 남겨 둔 것은 옳았고, 확인해 보니
아니었다는 것도 그대로 적는다.

#### 2. 재처리 자동화 — 그리고 경보를 겸하게 했다

`openmeter-dlq-replay` CronJob(15분 주기). DLQ 인덱스를 읽어 OpenMeter 에
다시 넣고, 성공한 문서는 지운다.

★ **이 클러스터에는 경보 수단이 없다.** alertmanager 도, elasticsearch
exporter 도, Prometheus 경보 규칙도 없다(실측). 없는 것을 있는 척하지 않고
**재처리 후에도 남은 건수가 임계를 넘으면 Job 을 실패시킨다.** Job 실패는
`kubectl get job` 과 Ready 카운트에 드러나므로 지금 이 환경에서 가장 확실한
신호다. 경보 스택이 생기면 제대로 된 규칙으로 옮길 것.

★ 중복 재처리는 안전하다 — OpenMeter 가 `id` 로 중복을 제거한다. 그래서
"성공했는지 확실하지 않으면 다시 보낸다" 가 옳다. **유실은 매출 누락이지만
중복은 잡히기 때문이다.** 실측에서 4건을 재처리했는데 ClickHouse 는 3건만
늘었다 — 1건은 §8-61 시험 때 이미 들어간 것이라 중복 제거가 걸렀다.

#### 3. ★ 경보를 "코드로 확인됨" 으로 넘기지 않았다

처음에는 임계 로직을 짜 두고 넘어갈 뻔했다. 실제로 장애를 만들어 돌려 보니
**Job 은 실패했지만 내가 의도한 경로가 아니었다** — `ConnectionResetError` 가
그대로 올라가 스크립트가 죽었다.

기능상 경보는 울렸지만 부작용이 있었다:
- 이미 재처리한 건의 **삭제를 못 해** 다음 실행에서 또 보낸다(중복 제거가
  잡으므로 안전하지만 지저분하다)
- 임계 판정 메시지가 남지 않아 **왜 실패했는지 로그에 없다**

`call()` 이 `HTTPError` 만 잡고 있었다. 연결 오류(reset·timeout·DNS)를 잡아
실패로 처리하도록 고쳤다.

#### 검증 — 실패·성공 양쪽

```
① OpenMeter replicas=0 상태로 재처리
   succeeded=[] failed=[1]        ← 경보 동작
② 복구 후 재처리
   succeeded=[1] failed=[]
   [dlq-replay] DLQ 3건 · 재처리 성공 3 · 실패 0
```

#### 남은 것

- 경보가 Job 실패에 의존한다. 누군가 `kubectl get job` 을 보거나 Ready
  카운트를 지켜봐야 한다 — **밀어내는 경보가 아니다.**
- 요금제·구독·가격은 여전히 없다. 계량은 끝났고 **가격이 없다.**

### 8-63. Alertmanager 도입 — 경보를 밀어내는 경로가 생겼다

§8-62 의 "남은 것" 첫 줄이 그대로 이번 작업의 시작이다. 그때의 경보는
Job 이 `exit 1` 하는 것뿐이었고, **누군가 `kubectl get job` 을 봐야만**
알 수 있었다. 당기는 경보는 아무도 당기지 않으면 없는 것과 같다.

#### 있는 줄 알았던 것들이 없었다

먼저 조사부터 했다. 결과:

| 구성요소 | 상태 |
|---|---|
| kube-state-metrics | **없음** — Job·Pod·Deployment 의 상태 지표 자체가 없었다 |
| Alertmanager | **없음** |
| Prometheus alerting rule | **0건** — `rule_files` 조차 없었다 |
| Slack webhook | 값이 비어 있다(Falcosidekick 과 같은 상태, §8-35) |

즉 Prometheus 는 **지표를 모으기만 하고 판단은 하지 않고 있었다.**
대시보드는 있었으나 아무도 보지 않으면 조용하다.

#### 경로 설계 — 빈 receiver 를 두지 않는다

```
kube-state-metrics ─▶ Prometheus ─▶ 규칙 ─▶ Alertmanager ─▶ webhook
                                                              │
                                              Logstash(http:5142)
                                                              │
                                                   Elasticsearch `alerts`
```

Slack·SMTP 가 없는 상태에서 흔히 하는 선택은 receiver 를 비워 두는
것이다. **그러면 경보가 조용히 사라진다** — Alertmanager 는 성공적으로
"아무 데도" 보내고 오류를 내지 않는다. 이 레포에서 같은 함정을 이미 두 번
겪었다(Falcosidekick `Enabled Outputs: []` §8-35, Envoy ALS 수신 0건
§8-55). 그래서 **이미 있는 것으로 받는다** — Logstash 는 이미 돌고 있고
Elasticsearch·Kibana 도 있다. 나중에 Slack 이 생기면 receiver 를 하나
더하면 되고, 그 사이에도 경보는 남는다.

규칙 5개는 **실제로 겪은 실패 유형**에서 골랐다:

| 규칙 | 근거 |
|---|---|
| `BillingDLQReplayFailing` | §8-62 — 재처리 실패는 **미청구**로 직결된다 |
| `BillingComponentDown` | §8-58 — OpenMeter 가 죽으면 이벤트가 쌓이기만 한다 |
| `PodCrashLooping` | §8-58 sink-worker, §8-59 등 반복 |
| `JobFailed` | §8-52·§8-55 — 부트스트랩 Job 은 평소에 돌지 않아 늦게 드러난다 |
| `AlertmanagerDown` | 경보 체계 자신이 죽는 경우. 이것만은 Prometheus 가 직접 본다 |

#### 검증 — 합성 하나, 진짜 하나

경로가 있다는 것과 경보가 도착한다는 것은 다르다. 두 단계로 봤다.

**① 합성 경보로 배달 경로를 본다.** Alertmanager 의 `/api/v2/alerts` 에
직접 넣었다. `group_wait: 30s` 뒤 `alerts` 인덱스가 **생성 시각
07:57:02 로 새로 생겼다**(주입 07:56:30). 배달은 된다.

그런데 문서를 열어 보니 셋이 잘못돼 있었다:

- `event.original` 에 **split 이전의 alerts 배열 전체**가 문서마다 통째로
  들어갔다. keyword 길이 한도를 넘겨 `_ignored` 에 걸려 있었다 —
  **저장은 되고 검색은 안 되는 필드**다.
- `@timestamp` 가 **수신 시각**이었다. Alertmanager 는 `group_wait`·
  `group_interval`·`repeat_interval: 4h` 만큼 늦춰 보내고 같은 경보를
  4시간마다 **다시** 보낸다. 수신 시각을 쓰면 재전송분이 전부 "새 경보"로
  보여 발생 시점을 잃는다. `[alerts][startsAt]` 로 바꿨다.
- `alertname`·`severity` 가 `alerts.labels.*` 아래 묻혀 있어 **경보 종류별
  집계가 안 됐다.** 최상위로 올렸다.

고친 뒤 두 번째 합성 경보:

```
"@timestamp"   : "2026-09-05T08:03:07.000Z"   ← startsAt(수신은 08:03:57)
"alertname"    : "SyntheticFieldCheck"
"severity"     : "critical"
"alert_status" : "firing"
"event"        : { "kind": "alert", "module": "alertmanager" }
```

`event.original`·`message` 는 사라졌고 `_ignored` 도 없다.

**② 진짜 경보를 기다린다.** 규칙을 올리자마자 `JobFailed` 가 곧바로
`pending` 이 됐다 — 만들어 낸 상황이 아니라 **§8-62 의 장애 시험 때 실제로
죽은 Job 3개**가 아직 남아 있었다(`BackoffLimitExceeded`, 03:00~03:30 UTC —
OpenMeter 를 0으로 내렸던 그 시각이다). `for: 15m` 을 채우고 발화했고,
`group_wait` 뒤 Elasticsearch 에 3건이 들어왔다:

```
alertname     alert_status  job_name
JobFailed     firing        openmeter-subscription-sync-29809620
JobFailed     firing        openmeter-billing-advance-invoices-29809650
JobFailed     firing        openmeter-billing-collect-invoices-29809650
```

`split` 을 넣은 이유가 여기서 드러난다 — webhook 페이로드는 3건을 한
배열로 보낸다. 쪼개지 않으면 "몇 건이 울렸나"를 셀 수 없다. 종류별 집계가
된다:

```
JobFailed 3 · SyntheticFieldCheck 2 · SyntheticPathCheck 1
```

Job 3개를 지우자 90초 안에 `JobFailed` 가 Prometheus 에서 사라졌다. 그러나 **해소 문서는 그때 오지 않았다** — `group_interval: 5m` 만큼 늦는다. 5분 뒤에 3건이 들어왔고 그제서야 firing 3 · resolved 3 으로 맞았다. 경보가 사라졌다고 곧바로 확인하면 “해소가 안 돌아간다” 로 오판한다.

#### 곁다리로 클러스터가 green 이 됐다

`alerts` 인덱스를 만들자마자 **yellow** 였다. Gotcha 14 와 정확히 같은
함정이다 — Logstash 가 고정 이름으로 즉석 생성하는 인덱스는 템플릿이
없어 ES 기본값인 **복제본 1** 이 붙고, 단일 노드에는 배정될 곳이 없다.
그리고 yellow 면 **ECK 가 파드를 롤링하지 않는다.**

`alerts`·`api-usage-dlq`·`api-usage-quarantine` 셋을
`elasticsearch-ilm-setup` 에 넣었다. 템플릿은 **생성 시점에만** 적용되므로
이미 만들어진 인덱스에는 `_settings` 를 한 번 더 밀어 넣는다.

```
"status" : "green",  "unassigned_shards" : 0
```

즉 §8-61·§8-62 에서 만든 DLQ·격리 인덱스 둘도 그동안 조용히 클러스터를
yellow 로 묶고 있었다. 경보를 붙이려다 발견했다.

#### 남은 것

- **경보 수신처가 Elasticsearch 뿐이다.** 사람에게 밀어내려면 Slack 이나
  메일이 필요하다. receiver 를 더하는 자리는 만들어 두었다.
- 규칙 5개는 최소 집합이다. 디스크·메모리·Kafka consumer lag 은 아직 없다.
- 요금제·구독·가격은 여전히 없다. **계량은 끝났고 가격이 없다.**

### 8-64. Falco 가 살아났다 — §8-36 의 결론이 **틀린 저장소를 본 것**이었다

§8-36 은 원인 규명까지 훌륭했다. `sys_exit` 프로그램의 raw tracepoint attach 가
EINVAL 로 거부되고 검증기는 통과한다는 것까지 특정했고, 커널 탓이 아니라
**버전 간 비호환**이라고 바르게 결론지었다. 그런데 마지막 한 줄이 틀렸다.

> **더 새 Falco 가 없다.** `falcosecurity/falco-no-driver` 의 최신 태그가 0.39.2 다

`falco-no-driver` 의 최신이 0.39.2 인 것은 **맞다.** 다만 그 저장소가 버려진
것이다.

```
falcosecurity/falco-no-driver   0.39.2      2024-11-21   ← 여기서 멈춤
falcosecurity/falco             0.44.1      2026-06-11   ← 유지되는 쪽
                                master      2026-09-04
```

**"최신 태그가 없다" 를 확인할 때 그 저장소가 아직 살아 있는지를 함께 봐야
한다.** 2년째 갱신이 없다는 사실 자체가 이미 신호였는데, 그것을 "Falco 가
멈췄다" 로 읽고 "저장소가 옮겨갔다" 를 의심하지 않았다.

#### 0.44.1 로 올리니 attach 실패가 사라졌다

§8-36 이 특정한 EINVAL 은 한 번도 나오지 않았다. 대신 **0.41 이후의 구조
변경** 둘이 차례로 걸렸다.

| 증상 | 원인 |
|---|---|
| `Plugin requirement not satisfied, must load one of: container (>= 0.4.0)` | 0.41 부터 컨테이너 메타데이터가 **플러그인**으로 분리됐다. `.so` 는 이미지 안에 있으나 `load_plugins`·`plugins` 를 써야 한다 |
| `property could not be validated: 'grpc'` | `grpc` 절이 스키마에서 빠졌다 |

옛 인자 `-o container_engines.cri.sockets[]=...` 도 없어졌다 — 엔진 설정이
플러그인 `init_config` 로 옮겨갔다.

#### 그리고 **Falco 가 돌지 않아 숨어 있던 결함 셋**이 한꺼번에 드러났다

이것이 이번 작업에서 가장 값진 부분이다. 경보를 만드는 쪽이 죽어 있으면
경보를 **받는** 쪽의 고장은 아무 증상도 내지 않는다.

**① falcosidekick → Elasticsearch 가 401 이었다.**

```
unable to authenticate user [elastic] for REST request [/falco-alerts-.../_doc]
```

`elastic` 사용자의 권위 있는 소유자는 **ECK**(`elasticsearch-es-elastic-user`)인데
falcosidekick 만 수기 `elasticsearch-secret` 을 보고 있었다. 확인해 보니 소비자가
갈라져 있었다:

```
ECK 것을 본다   logstash · filebeat · grafana · ilm-setup · dlq-replay   → 200
수기 것을 본다  falcosidekick · trivy-cronjob · rotate-elasticsearch      → 401
```

trivy 는 **주 1회**만 돌아 훨씬 늦게 드러났을 자리다. 둘 다 ECK 쪽으로 옮겼다.

**② 그 드리프트를 만든 것은 `rotate-elasticsearch` 였다.** 이 CronJob 은
ES API 로 비밀번호를 바꾸고 **수기 시크릿만** 패치한다. ECK 시크릿은 손대지
않는다. 게다가 ⓐ ECK 가 그 사용자의 소유자라 바꿔도 되돌려지고
ⓑ `curlimages/curl` 이미지에 `kubectl` 이 없어 3단계가 실행조차 안 된다.
지금은 **실행돼도 실패해서** 피해가 없다. 고치려면 "ECK 관리 사용자를 회전할
것인가, 전용 사용자를 둘 것인가" 를 먼저 정해야 해 §9-4 로 넘겼다.

**③ falcosidekick → Kafka 가 거부되고 있었다.**

```
Kafka - read tcp 10.0.0.203:...->10.0.0.238:9092: read: connection reset by peer
```

`messaging-netpol`(NetworkPolicy)에는 falcosidekick 이 있는데
`allow-messaging-access`(AuthorizationPolicy)에는 **없었다.** 두 계층이 어긋나면
타임아웃이 아니라 **connection reset** 이다 — 정책 파일 머리말이 경고하는 바로
그 형태다. §8-35 는 설정 미적재가 원인이라 이 지점까지 도달하지 못했다.

#### 컨테이너 메타데이터가 전부 `<NA>` 였다 — 소켓 둘이 어긋나 있었다

경보는 뜨는데 `container=<NA> image=<NA> pod=<NA> ns=<NA>` 였다. **오류는
나지 않는다.**

```
/run/containerd/containerd.sock       k8s.io 컨테이너   1 개  ← 매니페스트가 물던 것
/run/k3s/containerd/containerd.sock   k8s.io 컨테이너 422 개  ← k3s 의 진짜 소켓
```

고치고도 여전히 `<NA>` 였다. 로그가 답을 줬다:

```
container: * enabled container runtime socket at '/host/run/k3s/containerd/containerd.sock'
```

플러그인이 `host_root`(기본 `/host`)를 **앞에 붙인다.** 매니페스트는
`/host/proc`·`/host/dev`·`/host/boot` 는 규약대로 두고 **소켓만** `/host` 밖에
두고 있었다. 마운트 지점을 옮기니 채워졌다.

```
container=zookeeper image=docker.io/library/zookeeper pod=zookeeper-0 ns=local
```

#### 살려 놓고 보니 오탐이 대부분이었다

5분에 388건. 그대로 두면 하루 11만 건이고, §8-37 에서 filebeat 가 ES 를
93 GB 로 부풀린 전례가 있다. 그러나 더 큰 문제는 용량이 아니라 **진짜 경보가
묻힌다**는 것이다.

| 규칙 | 건수 | 실체 | 조치 |
|---|---:|---|---|
| Terminal shell in container | 260 | kubelet 의 readiness·liveness 프로브 | `proc.tty != 0` — "터미널" 쉘이면 tty 가 있어야 한다. 기존의 `proc.pname` 제외 목록으로는 안 잡힌다(프로브의 부모는 런타임 shim 이다) |
| Unexpected outbound connection | 150 | **IPv6 루프백** `::1` | 기존 제외가 `fd.snet` 의 IPv4 사설 대역뿐이었다 |
| 〃 (2차 관측) | 46 | Trivy 스캐너의 취약점 DB 내려받기 | 설계상 정상이라 제외. **의도한 사각지대다** — trivy 이미지로 위장한 egress 는 안 걸린다 |

```
388건/5분  →  59건/5분  →  3건/3분
```

탐지가 죽은 것이 아님을 확인했다. 일부러 ServiceAccount 토큰을 읽자 즉시 잡혔다:

```
Read sensitive Kubernetes files | K8s Secret 파일 접근
  (file=/var/run/secrets/kubernetes.io/serviceaccount/token ...)
```

#### 정리

`overlays/local/patches/falco-local.yaml` 을 지웠다. 노드 레이블 없이 스케줄된다.
Tetragon 은 그대로 둔다 — ADR-025 는 전환을 제안했으나 지금 둘은 **대체재가
아니라 병행**이다.

#### 교훈

§8-36 의 교훈("추정을 단정처럼 남기지 말 것")이 한 겹 더 필요하다.
**부정형 결론("~가 없다")은 조사 범위가 곧 결론의 범위다.** §8-36 은
`falco-no-driver` 안에서는 완벽하게 옳았고, 그 밖을 보지 않았다는 것만 적히지
않았다. 없다고 적을 때는 **어디를 봤는지**를 함께 적어야 다음 사람이 그 경계를
다시 볼 수 있다.

그리고 **죽어 있는 구성요소는 그 하류 전체를 검증되지 않은 상태로 만든다.**
Falco 하나를 살리자 401·정책 누락·소켓 오설정 셋이 한꺼번에 나왔다. 셋 다
"설정은 있으나 한 번도 실행된 적이 없는" 코드였다.

### 8-65. Knox 는 Ready 인데 아무것도 프록시하지 않는다 (2026-09-06)

"Knox 를 통해 붙는 법" 을 적으려다 확인한 것이다. **붙을 수 없다.**
파드는 `1/1 Running` 이고 8443 이 열려 있으나 **모든 요청이 401** 이다.

```
/                                      404
/gateway/homepage/home                 301
/gateway/admin/api/v1/topologies       401
/gateway/sandbox/webhdfs/v1/?op=...    401
```

#### 원인 셋 — 전부 실측했다

**① 토폴로지가 이 클러스터를 가리키지 않는다.**
`knox/` 디렉터리에 ConfigMap 이 없어 **이미지 기본 토폴로지**로 돈다.
`sandbox.xml` 이 가리키는 곳:

```
hdfs://localhost:8020 · http://localhost:50070/webhdfs
rpc://localhost:8050   · http://localhost:11000/oozie
```

Hortonworks Sandbox 데모 주소다. 이 클러스터의 `hadoop-namenode:9870` ·
`hive-server:10000` · `ranger-admin:6080` 어느 것도 아니다.

**② 인증 원천이 없다.** 기본 토폴로지는 `ShiroProvider` + `KnoxLdapRealm` 로
**데모 LDAP** 을 본다(`conf/users.ldif` 에 guest·admin·sam·tom). 그런데
**그 데모 LDAP 프로세스가 돌지 않는다**(`ps` 로 0건). 엔트리포인트가 게이트웨이만
띄운다. 그래서 어떤 계정으로도 401 이다.

**③ 레포의 DS389·Keycloak 과 연결돼 있지 않다.** 이 클러스터에는 LDAP(DS389,
3389)도 OIDC(Keycloak)도 있는데 Knox 는 둘 다 모른다.

#### 왜 지금까지 안 드러났나 — probe 가 `tcpSocket` 이다

```yaml
readinessProbe:
  tcpSocket: {port: https}
```

**포트가 열려 있으면 통과한다.** 프록시가 되는지는 보지 않는다. 그래서
`1/1 Running` 으로 4일을 돌았다. §8-64 의 Falco·falcosidekick 과 같은
부류다 — **설정은 있으나 한 번도 실행된 적이 없어 아무 증상도 내지 않는다.**

#### 쓰려면 무엇이 필요한가

| | 할 일 |
|:-:|---|
| 1 | **토폴로지 ConfigMap 신설** — 이 클러스터를 가리키는 `oim.xml`. WebHDFS(`hadoop-namenode:9870`) · HiveServer2(`hive-server:10000`) · Ranger(`ranger-admin:6080`) · Solr(`solr-headless:8983`) |
| 2 | **인증 원천 결정** — ⓐ DS389 LDAP(3389)에 `KnoxLdapRealm` 을 붙이거나 ⓑ **Keycloak OIDC + KnoxSSO**(pac4j). 레포가 Keycloak 을 인증 원천으로 두고 있으므로 ⓑ 가 정합적이다 |
| 3 | **readiness probe 를 실제 요청으로** — `tcpSocket` 대신 `httpGet: /gateway/homepage/home`. 그래야 "뜬 척" 이 안 된다 |
| 4 | prod 이미지 다이제스트 핀 — 매니페스트 주석이 이미 지적하고 있다(`apache/knox:3.0` 은 가변 태그) |

**지금은 §9 로 넘긴다.** Knox 가 프록시할 대상(HDFS·Hive)이 `lakehouse-local`
전용이고, §19-5 ③ 의 프로파일 분리에서 **빼기로 한 묶음**이라 순서가 맞지 않는다.

### 8-66. Knox 로 HDFS·Hive 를 뚫었다 — HBase 와 Ranger 는 남았다 (2026-09-06)

§8-65 에서 "Knox 가 아무것도 프록시하지 않는다" 를 확인했으니 그 다음이다.

#### 결과

| 대상 | 상태 | 근거 |
|---|---|---|
| **HDFS(WebHDFS)** | ✅ **된다** | Knox 경유 `200` + 실제 디렉터리 목록(hbase·tmp·user·warehouse). 인증 없으면 401 |
| **Hive** | ✅ **된다** | Knox 경유 **JDBC** 로 `show databases` → `default`·`oim_hdfs`·`oim_s3` |
| **HBase** | ✅ **된다** | REST(Stargate)를 새로 배포. Knox 경유 `200` + 클러스터 버전 `2.6.6` |
| **Ranger 권한 제어** | ❌ **작동하지 않는다** | 플러그인 부재 + **Ranger 에 등록된 서비스 0개**(API 확인) |

#### 한 일

**① 토폴로지 신설** — `knox-topology-configmap.yaml`. 인증은 DS389 를 직접
본다(`KnoxLdapRealm` + `userDnTemplate`). **바인드 계정이 필요 없어** 매니페스트에
비밀번호가 들어가지 않는다. 인증 동작을 네 갈래로 확인했다:

```
인증 없음        401
틀린 비밀번호     401
없는 사용자      401
올바른 LDAP 자격  200  {"FileStatuses":... hbase, tmp, user, warehouse}
```

**② HiveServer2 를 HTTP transport 로** — Knox 의 HIVE 서비스는 binary 를
지원하지 않는다. `transport.mode=http` · `thrift.http.port=10001` ·
`thrift.http.path=cliservice` 로 바꿨다. **10000 을 쓰는 소비자가 하나도 없어**
안전했다(Trino·Spark 는 HiveServer2 가 아니라 메타스토어 9083 을 직접 본다).

**③ readiness probe 를 옮겼다** — 이것이 함정이었다. probe 가 `thrift`(10000)를
보는데 HTTP 모드로 바꾸면 **그 포트가 더 이상 열리지 않는다.** 파드가 영원히
`0/1` 이고 liveness 가 계속 죽인다. 포트를 `http-thrift`(10001)로 옮겨 해소했다.

**④ Knox 의 probe 도 바꿨다** — `tcpSocket` → `httpGet /gateway/homepage/home`.
§8-65 의 "포트만 열려 있으면 Ready" 를 없앤다. **`/gateway/oim/...` 를 찌르지
않은 이유**는 그 경로가 인증을 요구해 401 이고 **kubelet 의 httpGet 은 2xx·3xx
만 성공**으로 보기 때문이다 — 401 을 기대하는 probe 는 영원히 Ready 가 안 된다.

**⑤ NetworkPolicy 두 곳에 Knox 를 넣었다** — `allow-hadoop-namenode-access` 와
`allow-hive-server-access`(포트 10001 도 함께). 없으면 Knox 가 502 를 준다.

#### ★ 남은 것 1 — Knox 의 TLS 신원

이미지는 기동마다 자체 서명 인증서를 만들고 **SAN 에 파드 이름과 localhost 만**
넣는다.

```
Certificate for <knox-headless> doesn't match any of the subject
alternative names: [knox-6b66c4c4b5-lf7rw, localhost]
```

파드 이름은 재기동마다 바뀌므로 클라이언트가 고정할 수도 없다. cert-manager 로
`knox-tls` 인증서를 발급하고(`gateway-ca` 재사용) `KNOX_CERT`/`KNOX_KEY` 를
주었으나 **해결되지 않았다.**

> **★ `KNOX_CERT`/`KNOX_KEY` 는 게이트웨이 TLS 신원이 아니다.** entrypoint 를
> 읽어 보니 그 둘로 만든 PKCS12 를 **`keystore.jks` 에 별칭 `keystore` 로**
> 넣는다 — 그것은 **서명용**(JWT·KnoxSSO)이다. 게이트웨이 TLS 는
> `gateway.jks` 의 별칭 `gateway-identity` 에서 온다. 그래서 인증서를 주어도
> 서빙되는 것은 여전히 `CN=localhost, OU=Test, O=Hadoop` 이다.
> `knox-deployment.yaml` 주석이 "KNOX_CERT·KNOX_KEY 로 바꾼다" 고 적어 둔 것은
> **추정이었고 틀렸다.**

**해결했다** — `gateway.jks` 를 `gateway-identity` 별칭으로 미리 만드는
initContainer 를 넣었다. Knox 는 이미 있는 keystore 를 그대로 쓴다.

```
전  subject=CN = localhost, OU = Test, O = Hadoop
    SAN: knox-6b66c4c4b5-lf7rw, localhost
후  subject=CN = knox-headless
    SAN: knox-headless, knox-headless.local.svc,
         knox-headless.local.svc.cluster.local, knox, localhost
```

그 뒤 Hive JDBC 가 Knox 를 통과한다:

```
jdbc:hive2://knox-headless:8443/default;ssl=true;transportMode=http;
            httpPath=gateway/oim/hive
  → default · oim_hdfs · oim_s3   (3 rows)
```

#### ★ 남은 것 2 — Ranger 가 권한을 제어하지 않는다

요구된 확인의 답이다. **제어하지 않는다.**

```
ranger-.*-plugin · ranger.plugin · xasecure  →  레포 전체에서 0건

Ranger Admin API 확인:
  /service/public/v2/api/service      →  **등록된 서비스 0개**
  /service/public/v2/api/servicedef   →  정의는 22종 있다
      (hdfs · hive · hbase · kafka · knox · solr · trino · yarn · …)
```

정의가 22종 있다는 것은 **붙일 준비는 돼 있다**는 뜻이다. 그러나 리포지토리가
하나도 등록돼 있지 않고 플러그인 하트비트도 없다 — 즉 Ranger 는 아직
**정책을 만들 대상조차 모른다.**

Ranger Admin 은 돌고 정책 UI 도 뜨지만, **정책을 강제하는 주체는 각 서비스에
들어가는 플러그인**이다(HDFS NameNode·HiveServer2·HBase Master). 그것이 없으면
Ranger 는 **정책을 저장만 하는 데이터베이스**다. 지금 HDFS 접근을 막는 것은
POSIX 퍼미션뿐이고 Hive·HBase 는 사실상 무제한이다.

플러그인 설치는 각 서비스 이미지에 jar 를 넣고 `ranger-*-security.xml`·
`ranger-*-audit.xml` 을 배포한 뒤 서비스를 재기동하는 일이다. `docker/` 에
로컬 빌드 이미지가 있어 불가능하지는 않으나 **작은 작업이 아니다.**

#### HBase — REST 서버를 새로 배포했다

Knox 의 `WEBHBASE` 는 **HBase REST(Stargate)** 를 요구한다. 16010 은 마스터 UI,
16000 은 RPC 라 쓸 수 없다. `hbase-rest` Deployment 를 새로 만들었다(무상태라
StatefulSet 이 아니다).

**★ 함정 — `-p 8085` 만 주면 기동하지 못한다.** `hbase.rest.port` 기본값은
8080 이고 **`hbase.rest.info.port` 기본값이 8085** 라, 두 리스너가 같은 포트를
잡는다:

```
java.io.IOException: Failed to bind to /0.0.0.0:8085
Caused by: java.net.BindException: Address already in use
```

`--infoport 8086` 을 함께 줘야 한다.

파드 자리는 **상한을 110 → 200 으로 올려** 확보했다(`local/kubelet-config.yaml`).
이 작업 중 실제로 `hive-server-0` 이 `Too many pods` 로 9분 Pending 이었고,
올린 뒤 그동안 눌려 있던 trivy 스캔 파드들도 함께 떴다.

### 8-67. Ranger HDFS 플러그인 — 인가가 실제로 걸리게 만든다 (2026-09-06)

§8-66 의 결론은 **"Ranger 는 권한을 제어하지 않는다"** 였다. 정책을 강제하는
주체는 Admin 이 아니라 각 서비스에 들어가는 **플러그인**인데 그것이 레포
어디에도 없었다(`ranger-*-plugin`·`xasecure` 전체 0건). 이 절은 그 문장을
거짓으로 만드는 작업이다. **아직 끝나지 않았다** — 마지막 절을 볼 것.

#### 플러그인을 넣는다

이미지(`apache/hadoop:3.4.3`)에 플러그인이 없다. 이미지를 다시 굽는 대신
initContainer 가 `ranger-2.9.0-hdfs-plugin.tar.gz` 를 받아 공유 emptyDir 에
푼다. NameNode 쪽 `hdfs-site.xml` 에 인가자를 꽂는다:

```xml
<name>dfs.namenode.inode.attributes.provider.class</name>
<value>org.apache.ranger.authorization.hadoop.RangerHdfsAuthorizer</value>
```

**★ 함정 1 — 클래스패스.** Java 의 `dir/*` 는 **하위 디렉터리를 포함하지
않는다.** 구현체 23개가 `ranger-hdfs-plugin-impl/` 안에 있으므로
`/ranger/*` 만으로는 `ClassNotFoundException` 이다. 둘 다 적어야 한다:

```yaml
- {name: HADOOP_CLASSPATH, value: "/ranger/*:/ranger/ranger-hdfs-plugin-impl/*"}
```

**★ 함정 2 — Ranger 2.9 에는 log4j 감사 목적지가 없다.** 관례대로
`xasecure.audit.destination.log4j=true` 를 켰더니 NameNode 가 **70분간
CrashLoop** 했다:

```
ERROR AuditProviderFactory:394 - Failed to instantiate audit destination
  org.apache.ranger.audit.destination.Log4JAuditDestination
java.lang.ClassNotFoundException
```

tarball 의 jar 23개를 전수 검색해도 그 클래스가 없다. 2.9 는 감사를
`ranger-audit-dest-hdfs`·`ranger-audit-dest-solr` 로 쪼갰고 log4j 목적지는
빠졌다. **없는 감사 목적지를 켜면 스토리지 전체가 내려간다** — 인가 기능의
부수 설정 하나가 HDFS 를 죽이고, HBase master·REST 까지 함께 무너졌다.
감사는 전부 끄고(`xasecure.audit.is.enabled=false`) 인가 확인에 집중했다.
감사 저장소를 세우는 것은 별개 작업이다.

그러자 NameNode 가 떴고 플러그인도 붙었다:

```
INFO FSNamesystem:1056 - Using INode attribute provider:
  org.apache.ranger.authorization.hadoop.RangerHdfsAuthorizer
INFO RangerBasePlugin:317 - Created PolicyRefresher Thread(PolicyRefresher(serviceName=oim-hdfs)-69)
```

#### 그런데 정책을 한 건도 받지 못한다 — 그리고 원인은 자격이 아니었다

```
WARN RangerAdminRESTClient:183 - Error getting policies. secureMode=false,
  response={"httpStatusCode":400,"statusCode":400,"msgDesc":"Unauthenticated access not allowed"}
```

메시지가 "Unauthenticated" 라 자격 문제로 읽힌다. 그래서 전용 사용자
`hdfsplugin` 을 만들고 자격을 붙이려 했는데, **그 전에 대조군을 넣은 것이
결정적이었다.**

| 호출자 | 경로 | 결과 |
|---|---|---|
| `admin` (올바른 자격) | `/service/xusers/users/userName/...` | **200** |
| `admin` (올바른 자격) | `/service/plugins/policies/download/oim-hdfs` | **400** |
| `hdfsplugin` (올바른 자격) | `/service/xusers/users/userName/...` | **200** |
| `hdfsplugin` (올바른 자격) | `/service/plugins/policies/download/oim-hdfs` | **400** |
| 자격 없음 | `/service/plugins/policies/download/oim-hdfs` | **400** |

**올바른 관리자 자격으로도 같은 400 이다.** 자격을 아무리 잘 넣어도 통과할 수
없는 경로라는 뜻이다. 근거를 바이트코드에서 확인했다:

```xml
<!-- security-applicationContext.xml -->
<security:http pattern="/service/plugins/policies/download/*" security="none"/>
```

```
// RangerBizUtil.failUnauthenticatedDownloadIfNotAllowed()
ContextUtil.getCurrentUserSession() 가 null 이고
allowUnauthenticatedDownloadAccessInSecureEnvironment 가 false 면 → 무조건 throw
```

경로가 `security="none"` 이라 **Spring Security 자체가 돌지 않는다.** 그래서
basic auth 를 보내도 `UserSession` 이 만들어지지 않고, 그 null 을 검사하는
위 메서드가 항상 던진다. 원래 이 자리는 **Kerberos SPNEGO** 가 막게 되어
있고 이 클러스터는 비-Kerberos 다. 남는 스위치는 하나뿐이다:

```
ranger.admin.allow.unauthenticated.download.access = true
```

`ranger-admin-site.xml` 은 setup 이 매 기동마다 다시 만들지만
`ranger-admin-default-site.xml` 은 이미지의 정적 파일이라 건드리지 않는다.
그래서 STS 의 기동 래퍼가 후자를 awk 로 고치고, **고쳐지지 않으면 기동하지
않는다**(값이 false 인 채로 뜨면 플러그인이 정책을 0건 받고, 그 상태의
플러그인은 **모든 접근을 거부**한다 — 조용히 뜨면 안 되는 종류의 실패다).

**★ 이 스위치가 여는 범위와 열지 않는 범위.**
여는 것은 **읽기 전용 다운로드 3종**뿐이다(`policies/download`·
`tags/download`·`roles/download`). 정책 생성·수정·삭제와 관리 API 는 그대로
인증을 요구한다. 열리는 것은 "정책 전문을 읽을 수 있다" 이지 "정책을 바꿀 수
있다" 가 아니다.

**★ 그래서 지금 무엇이 막고 있나 — 정직하게 말하면 거의 없다.**
`allow-ranger-admin-access` 가 6080 을 제한하지만, local 이 ambient 라 실제
트래픽은 15008(HBONE)로 흐르고 그 포트는 넓게 열려 있다(Gotcha 13). 게다가
**`ranger-admin` 을 선택하는 AuthorizationPolicy 가 없다.** 즉 메시 안의 아무
워크로드나 정책 전문을 읽을 수 있다. 여기에 ALLOW 정책을 다는 것은 별개
작업이며 **간단하지 않다** — 달면 신원이 없는 `kubectl port-forward` 경로가
함께 끊겨 Ranger UI 접근(`local/ACCESS.md`)이 죽는다. ECK 오퍼레이터가 같은
방식으로 무너졌던 Gotcha 10 과 정확히 같은 함정이다. §9 에 남긴다.

**★ 고칠 파일은 `conf/` 가 아니라 `conf.dist/` 다.** 첫 시도는 `conf/` 를
겨냥했는데 그 디렉터리는 **setup.sh 가 conf.dist 를 복사해야 생긴다.** 훅은
setup 보다 먼저 도니 파일이 아직 없다:

```
/bin/bash: .../conf/ranger-admin-default-site.xml.new: No such file or directory
[ranger-admin] 정책 다운로드 허용 적용 실패.
```

가드가 제 일을 해서 **기동을 거부했다.** 값이 false 인 채 떠 버렸다면 플러그인이
정책을 0건 받고 그 상태로 조용히 돌았을 것이다.

#### 그리고 더 큰 것이 나왔다 — 이미지가 매 기동마다 admin 을 잠그고 있었다

파드를 새로 만든 뒤 admin 자격이 **401** 이 됐다. 내 호출 때문이 아니었다 —
Ranger **자신의 부트스트랩**도 같은 401 을 내고 있었다:

```
An exception occured: GET service/public/v2/api/service/name/dev_hdfs failed:
  expected_status=200, status=401, message=Authentication Failed
  ... dev_yarn, dev_hive, dev_hbase, dev_kafka, dev_knox, dev_kms, dev_trino, dev_ozone
```

`x_auth_sess` 가 원인을 그대로 보여 준다(`auth_status` 2=비번틀림, 4=잠김):

```
admin|4|... 20:30:12
admin|4|... 20:27:06   ← 2 가 연달아 쌓인 직후 4 로 바뀐다
admin|2|... 20:27:06
```

범인은 이미지의 `create-ranger-services.py` **5번째 줄**이다:

```python
ranger_client = RangerClient('http://localhost:6080', ('admin', 'rangerR0cks!'))
```

관리자 비밀번호가 **하드코딩**돼 있다. 우리는 §8-44 에서 자격을 분리해 실제
비밀번호를 쓰므로 서비스 등록 9건이 전부 실패하고, 그 연속 실패가
**admin 을 영구히 잠근다.**

**★ 그리고 이것은 1회성이 아니다.** `.setupDone` 이 PVC 에 없으므로 setup 은
**파드를 새로 만들 때마다** 돈다 — 즉 `ranger-admin` 을 재기동할 때마다
관리자가 다시 잠겨 왔다. 잠금은 DB 에 남아 파드를 다시 띄워도 풀리지 않고
(Gotcha 11), 증상은 그냥 401 이라 비밀번호가 틀렸다고 오해하게 된다.
만드는 것도 `dev_hdfs`·`dev_knox` 같은 데모 서비스에 `hdfs/hdfs` 따위 자격이라
이 클러스터에 쓸모가 없다. **기동 래퍼에서 통째로 껐다**(끄지 못하면 기동하지
않는다). 이미 걸린 잠금은 §8-48 대로 `x_auth_sess` 의 2·4 행을 지워 풀었다.

#### 인가가 실제로 걸린다 — 양방향으로 증명했다

`/rangertest` 아래 두 디렉터리를 만들고 **POSIX 권한은 고정한 채 Ranger 정책만**
걸었다. 시험 주체는 `oimtest`, 대조군은 정책이 하나도 없는 `oimother` 다.

| 경로 | POSIX | Ranger 정책 | `oimtest` | `oimother`(대조군) |
|---|---|---|---|---|
| `/rangertest/open` | `777` = 누구나 허용 | **DENY** | **거부** | 허용 |
| `/rangertest/closed` | `700` = 소유자만 | **ALLOW** | **허용** | 거부 |

두 칸이 **정책만으로 뒤집혔다.** 거부의 성격도 다르다 — Ranger 거부는 예외
클래스가 Ranger 다:

```
cat: org.apache.ranger.authorization.hadoop.exceptions.RangerAccessControlException:
     Permission denied: user=oimtest, access=EXECUTE, inode="/rangertest/open/f.txt"
```

POSIX 거부는 inode 의 소유자·모드를 찍는다:

```
cat: Permission denied: user=oimother, access=EXECUTE,
     inode="/rangertest/closed":hadoop:supergroup:drwx------
```

대조군이 예전 그대로라는 것이 중요하다 — 바뀐 것은 "Ranger 가 판단하기
시작했다" 이지 "전부 잠겼다" 가 아니다.

**이로써 §8-66 의 "Ranger 는 권한을 제어하지 않는다" 는 HDFS 에 한해 거짓이
되었다.** 시험 자산(`/rangertest`, 사용자 `oimtest`, 정책 2건)은 재확인용으로
남겨 둔다 — 지우면 다음에 같은 것을 처음부터 다시 만들어야 한다.

#### HBase — 같은 절차로 통했다. 강제 지점만 다르다

HDFS 는 NameNode 의 INode attribute provider 였지만 HBase 는 **코프로세서**다.
`hbase.coprocessor.master.classes`·`region.classes`·`regionserver.classes` 셋에
`RangerAuthorizationCoprocessor` 를 걸고 jar 를 **master 와 regionserver 양쪽**에
넣었다. 한쪽만 넣으면 그쪽 프로세스가 기동하지 못한다.

**★ HBase 에는 POSIX 폴백이 없다.** HDFS 는 `xasecure.add-hadoop-authorization=true`
덕분에 정책 0건이어도 기존 접근이 살아 있었지만, HBase 는 켜는 순간 **정책이
유일한 판단자**가 된다. 다행히 Ranger 가 서비스 등록 시 만드는 기본 정책
`all - table, column-family, column` 이 `hbase` 사용자에게 전권을 주고 컨테이너
사용자가 `hbase` 라 기존 접근이 끊기지 않았다 — **운이 좋았던 것이지 설계된
것이 아니다.** 다른 사용자로 도는 워크로드가 있었다면 그 순간 끊겼다.

증명은 HDFS 와 같은 모양이다:

| 주체 | 정책 | `scan 'rangertest'` |
|---|---|---|
| `oimtest` | 없음 → **ALLOW 추가** | 거부 → **허용** |
| `oimother`(대조군) | 없음 | 거부 그대로 |

```
org.apache.hadoop.hbase.security.AccessDeniedException:
  Insufficient permissions for user 'oimtest', action: scannerOpen,
  tableName:rangertest, family:cf.
```

정책을 넣고 30초(폴링 주기) 뒤 `Switched policy engine to [4]` 가 찍히며 같은
명령이 통과했다.

참고로 기동 중 `ClassNotFoundException: org.graalvm.polyglot.HostAccess` 가
보이는데 **WARN 이고 무해하다** — Ranger 가 스크립트 조건 평가용 엔진을 여러 개
시도하다 GraalVM 이 없어 다음 것으로 넘어가는 것이다. 그 뒤 정책 엔진은
정상적으로 전환된다.

#### Hive 는 막혔다 — Ranger 2.9 플러그인이 Hive 4 와 바이너리 비호환이다

같은 절차를 Hive 에도 적용했다. 플러그인은 적재되고 **정책까지 내려받았다**
(`Switched policy engine to [11]`). 그런데 그 직후 HiveServer2 가 기동에
실패한다:

```
WARN server.HiveServer2: Error starting HiveServer2 on attempt 1, will retry in 60000ms
java.lang.NoSuchFieldError: PREEXECHOOKS
  at org.apache.ranger.authorization.hive.authorizer.RangerHiveAuthorizerBase
       .applyAuthorizationConfigPolicy(RangerHiveAuthorizerBase.java:103)
       ~[ranger-hive-plugin-2.9.0.jar:2.9.0]
```

`NoSuchFieldError` 는 설정 오류가 아니라 **바이너리 비호환**이다 — 컴파일 시점에
있던 필드가 런타임 클래스에 없다는 뜻이다. Hive 4 가 `HiveConf.ConfVars` 의
상수 이름을 바꿨고, Ranger 2.9 의 hive 플러그인은 Hive 3 API 로 빌드돼 있다.
`archive.apache.org` 의 Ranger 배포판은 **2.9.0 이 최신**이므로 더 새 플러그인도
없다.

**★ 이 증상은 진단하기 어렵다.** HiveServer2 는 예외를 stdout 에 내지 않고
`/tmp/hive/hive.log` 에만 쓴다. `kubectl logs` 에는 `Hive Session ID = ...` 만
반복해서 찍히고, 파드는 startupProbe 예산(400초)을 넘겨 조용히 kill 된다.
**로그가 비어 보이면 파일 로그를 볼 것.**

되돌렸다 — hive-site.xml 의 인가 설정, 플러그인 initContainer, 클래스패스,
ConfigMap 을 전부 원복하고 Ranger 의 `oim-hive` 리포지토리도 지웠다.
**강제하는 플러그인이 없는 리포지토리는 "Hive 가 통제되고 있다" 는 착각만
남긴다** — 이 레포가 반복해서 겪은 "설정은 있으나 아무것도 하지 않는" 부류다.
선택지는 둘뿐이다: Hive 를 3.1.x 로 내리거나, Ranger 가 Hive 4 를 지원하는
판을 낼 때까지 기다리는 것. 둘 다 이 작업의 범위를 넘는다.

#### 결산

| 대상 | Knox 프록시 | Ranger 강제 | 증명 |
|---|:---:|:---:|---|
| HDFS | ○ (§8-66) | **○** | 양방향(DENY·ALLOW) + 대조군 |
| HBase | ○ (§8-66) | **○** | ALLOW 전환 + 대조군 |
| Hive | ○ (§8-66) | ✕ | 플러그인 비호환 — 위 참조 |

§8-66 의 "Ranger 는 권한을 제어하지 않는다" 는 **HDFS·HBase 에 대해 거짓이
되었고 Hive 에 대해서는 여전히 참이다.**

> **★ 나중 정정 —** 위 문장의 Hive 부분은 **§8-70 에서 거짓이 되었다.**
> 아래 "Ranger 2.9 ↔ Hive 4 비호환" 도 **릴리스에 한해서만** 맞다. 수정은
> upstream master 에 있었고, 그것을 2.9.0 으로 백포트해 해결했다.
> 지금은 HDFS·HBase·Hive 셋 다 Ranger 가 제어한다.

#### 남은 일

- ~~**Hive** — Ranger 2.9 ↔ Hive 4.0.1 비호환~~ → **§8-70 에서 해결**
  (`docker/ranger-hive-plugin` 백포트).
- **감사(audit)가 꺼져 있다.** 누가 무엇을 거부당했는지 남지 않는다. 지금은
  거부가 클라이언트 예외로만 드러난다. 목적지(Solr 또는 HDFS)를 세우는 것은
  별개 작업이다.
- **`ranger-admin` 을 선택하는 AuthorizationPolicy 가 없다** — 메시 안에서는
  정책 전문을 누구나 읽을 수 있다. 위의 경고 참조. §9 에 남긴다.
- **HBase 기본 정책 의존.** 지금 기존 접근이 사는 이유는 컨테이너 사용자가
  마침 `hbase` 라서다. 워크로드 사용자가 바뀌면 즉시 끊긴다.
- 시험 자산은 재확인용으로 남겨 둔다 — HDFS `/rangertest`(정책 2건),
  HBase 테이블 `rangertest`(정책 1건), Ranger 사용자 `oimtest`.

### 8-68. 버전 천장은 Ranger 플러그인의 ABI 가 정한다 (2026-09-06)

"Hadoop·HBase·Hive 가 최신이 아니다" 에서 출발해 올려 보다가, 이 스택의
버전 상한을 무엇이 정하는지가 드러났다. **최신인지가 아니라 Ranger
플러그인이 무엇으로 빌드됐는지**다.

`apache-ranger-2.9.0` 의 최상위 pom:

| Ranger 2.9.0 이 빌드된 버전 | 우리 배포 | 결과 |
|---|---|---|
| `hadoop.version` **3.4.2** | 3.4.3 | 같은 마이너 → **동작** |
| `hbase.version` **2.6.0** | 2.6.6 | 같은 마이너 → **동작** |
| `hive.version` **3.1.3** | 4.0.1 | 메이저 차이 → **깨짐**(§8-67) |

즉 Hadoop·HBase 는 우연이 아니라 **정확히 천장에 맞춰져 있었다.**
`overlays/prod/kustomization.yaml` 의 `apache/hadoop` 옆 주석
("3.5 는 새 마이너다. Hive/HBase 클라이언트와 같은 계열을 유지한다")은
이제 추측이 아니라 측정된 근거를 갖는다.

#### Hadoop 3.5.0 을 올려 봤다 — Jersey 세대가 갈렸다

3.5.0 은 **Jersey 1.19.4 를 걷어내고 `org.glassfish.jersey` 2.46 으로
이관**했다. Ranger 2.9 의 `RangerAdminRESTClient` 는 `com.sun.jersey`(Jersey 1)
를 쓰므로 NameNode 가 기동하지 못한다:

```
java.lang.NoClassDefFoundError: com/sun/jersey/api/client/ClientHandlerException
  at RangerAdminRESTClient.init(RangerAdminRESTClient.java:772)
  ... at FSNamesystem.startCommonServices(...)
```

`INodeAttributeProvider` 자체는 멀쩡했다 — 인가자는 생성됐고 `start()` 까지
갔다. **ABI 가 아니라 의존성 문제였다.**

**★ 시도 1 — Jersey 1 을 통째로 보충: 실패.** `jersey-client`·`jersey-core`
와 함께 `jsr311-api`(JAX-RS 1.1 API)까지 넣었더니:

```
LinkageError: ClassCastException: attempting to cast
  jakarta.ws.rs-api-2.1.6.jar!/javax/ws/rs/ext/RuntimeDelegate.class
  to jsr311-api-1.1.1.jar!/javax/ws/rs/ext/RuntimeDelegate.class
```

플러그인 클래스로더가 `javax.*` 는 부모에 위임하므로 격리되지 않는다.
**빠진 것은 API 가 아니라 구현이었다** — 3.5.0 은 `jakarta.ws.rs-api-2.1.6`
으로 `javax.ws.rs` 를 이미 제공한다.

**★ 시도 2 — 구현 2개만 보충: 절반만 성공, 그래서 더 위험.**
NameNode 는 정상 기동한다. 그런데 정책 갱신이 실패한다:

```
com.sun.jersey.spi.inject.Errors$ErrorMessagesException
  at com.sun.jersey.api.client.Client.create(Client.java:683)
  at RangerRESTClient.buildClient(...)
```

결과는 **정책 버전 -1**. 그리고 `xasecure.add-hadoop-authorization=true` 의
POSIX 폴백 때문에 HDFS 는 아무 문제 없이 돈다 — 즉 **인가만 조용히
사라진다.** 파드는 `1/1 Running`, 오류 배너도 없다. 실측으로 이 상태에서
§8-67 의 DENY 정책이 적용되지 않았다(`/rangertest/open` 이 다시 읽혔다).

> **판정 기준을 파드 상태에 두지 말 것.** 이 플러그인이 살아 있다는 증거는
> 로그의 `Switched policy engine to [N]` 한 줄뿐이다.

**★ 함정 — 되돌릴 때 보충 블록을 같이 걷어내야 한다.** 이미지만 3.4.3 으로
되돌리고 jersey 보충을 남겨 두면, 3.4.3 은 Jersey 1 을 이미 갖고 있으므로
같은 클래스가 두 클래스로더에 걸쳐 **똑같은 -1 상태**가 된다. 실제로 그렇게
한 번 더 빠졌다.

#### 그러면 Ranger 2.9 가 Jersey 2 를 쓰게 할 수 있나

**설정으로는 불가능하다.** Jersey 1 의 `com.sun.jersey.api.client.Client` 와
Jersey 2 의 `javax.ws.rs.client.Client` 는 **다른 API** 다. jar 를 갈아끼우는
관계가 아니다.

**재빌드로는 가능해 보인다.** 그리고 그것은 upstream 이 이미 한 일이다 —
master(`3.0.0-SNAPSHOT`)의 `RangerRESTClient` 는 이미
`javax.ws.rs.client.*` · `org.glassfish.jersey.client.ClientConfig` 를 쓴다.
2.9.0 전체에서 `com.sun.jersey` 를 import 하는 파일은 **5개뿐**이고 전부
`agents-common` 안에 있다:

| 파일 | jersey import | 줄 수 |
|---|---:|---:|
| `RangerRESTClient.java` | 10 | 922 |
| `RangerAdminRESTClient.java` | 1 | 1027 |
| `RangerUserStoreRefresher.java` | 1 | 435 |
| `RESTResponse.java` | 1 | 212 |
| `PasswordUtils.java` | 1 | 350 |

바꾸는 것은 **플러그인 jar 뿐이다.** Ranger Admin 은 Docker Hub 의
`apache/ranger:2.9.0` 를 그대로 쓴다 — Admin 은 자기 Tomcat 안에서 돌아
Hadoop 클래스패스와 무관하므로 이 문제의 영향을 받지 않는다.

#### Ranger 3.0.0 은 없다

`archive.apache.org` · `downloads.apache.org` 모두 **2.9.0 이 최신**이고,
master 의 프로젝트 버전이 `3.0.0-SNAPSHOT` 이다. 즉 오늘 부딪힌 세 가지
(Hive 4 의 `PREEXECHOOKS`, Hive 4 가 삭제한 인덱스 연산 상수, Hadoop 3.5 의
Jersey 이관)가 **전부 미출시 코드에만 고쳐져 있다.** 미출시 Ranger 를 보안
통제면에 올리는 것은 채택하지 않기로 했다.

#### 백포트를 만들었다 — Hadoop 3.5.0 이 인가와 함께 동작한다

"Ranger 2.9 가 Jersey 2 를 쓰게 할 수 없나" 가 옳은 질문이었다. 설정으로는
불가능하지만 **재빌드로는 된다.**

**★ 1차 시도 실패 — master 를 통째로 가져오면 3.0 이 딸려 온다.**
5개 파일을 master 판으로 바꿨더니 컴파일이 이렇게 막혔다:

```
error: package org.apache.ranger.plugin.authn does not exist
  cannot find symbol: class JwtProvider
  cannot find symbol: class ServiceGdsInfo          <- GDS, 898줄짜리 3.0 기능
  cannot find symbol: class RangerSupportedCryptoAlgo
  cannot find symbol: variable RangerJersey2ClientBuilder
```

**★ 2차 — 좁은 경로로 성공.** 진짜 재작성이 필요한 것은 `RangerRESTClient`
하나뿐이다. 나머지 4개는 2.9.0 원본을 유지하고 Jersey 1 사용처만 기계적으로
옮기면 GDS·crypto 가 따라오지 않는다:

| 파일 | 처리 |
|---|---|
| `RangerRESTClient` | master 판 사용 (+ `RangerJersey2ClientBuilder` 371줄, `JwtProvider` 24줄) |
| `RangerAdminRESTClient`·`RESTResponse`·`RangerUserStoreRefresher` | `ClientResponse`→`Response`, `getEntity(X.class)`→`readEntity(X.class)` |
| `PasswordUtils` | jersey `Base64` → commons-codec (`encode`/`decode` 가 byte[] 라 짝이 맞다) |

**마지막 컴파일 오류는 한 줄이었다** — Jersey 1 의 `getCookies()` 는 `List` 지만
JAX-RS 2 는 **`Map`** 이라 for-each 가 안 된다:

```
RangerAdminRESTClient.java:[1006,48] error: for-each not applicable to expression type
  for (NewCookie cookie : response.getCookies())      // -> .getCookies().values()
```

결과 — **Hadoop 3.5.0 · Ranger 2.9 · 인가 전부 동작**:

```
STARTUP_MSG: version = 3.5.0
INFO FSNamesystem - Using INode attribute provider: RangerHdfsAuthorizer
INFO RangerBasePlugin - Switched policy engine to [9]     <- Admin 의 policyVersion 과 일치
```

| 검증 | 결과 |
|---|---|
| `/rangertest/open` (POSIX 777) + Ranger **DENY** | **거부** — `RangerAccessControlException` |
| `/rangertest/closed` (POSIX 700) + Ranger **ALLOW** | **허용** |
| HBase 인가(원본 2.9 플러그인, 영향 없음) | `oimtest` 통과 / `oimother` 거부 |
| HDFS 데이터 | 그대로 — 레이아웃 업그레이드 불필요했다 |

#### 어떻게 넣었나

`docker/ranger-hdfs-plugin/Dockerfile` 이 소스에서 포팅·빌드한다.
**빌드된 jar 는 커밋하지 않는다** — 무엇을 바꿨는지가 Dockerfile 에 남아야
한다. Jersey 1 참조가 하나라도 남으면 `! grep` 으로 빌드를 거부한다(남은 채
빌드되면 런타임에 위의 "조용한 -1" 이 된다). initContainer 는 이제 이 이미지에서
복사만 하므로 런타임 다운로드도 사라졌다.

**★ 반입 함정.** `local/build-images.sh` 의 반입 루프가 `:latest` 만 넣어서
매니페스트가 참조하는 `:2.9.0-jersey2` 가 없었고, NameNode 가 10분간
`Init:ImagePullBackOff` 였다. 루프에 **매니페스트가 쓰는 정확한 태그**를
넣어야 한다.

**★ 한시적이다.** Ranger 3.0.0 이 릴리스되면 이 이미지도 이 절도 지운다.
Dockerfile·`build-images.sh` 양쪽에 그렇게 적어 두었다.

#### 남는 것

- **HBase·Hive 플러그인은 아직 원본 2.9 다.** HBase 는 자체 이미지가 Hadoop
  클라이언트를 번들해 Jersey 1 을 갖고 있으므로 지금은 문제가 없다. HBase 를
  3.0.0 으로 올리면 같은 포팅이 필요할 수 있다.
- Hive 는 Jersey 와 무관한 별개 문제로 여전히 막혀 있다(§8-67).

### 8-69. HBase 3.0.0 — Ranger 플러그인을 직접 이식했다 (2026-09-06)

§8-68 에서 Hadoop 3.5 를 성공시킨 방식은 **업스트림이 이미 한 수정의 백포트**였다.
HBase 3 은 그 방식이 통하지 않는다 — 그리고 그것이 이 절의 요지다.

#### 먼저 부딪힌 것

HBase 2.6.6 은 이미 2.6 라인의 최신이라 올릴 곳은 3.0.0(메이저)뿐이다.
이미지를 3.0.0 으로 빌드해 올렸더니 마스터가 죽는다:

```
ERROR coprocessor.CoprocessorHost: The coprocessor
  org.apache.ranger.authorization.hbase.RangerAuthorizationCoprocessor threw
  java.lang.NoClassDefFoundError:
    org/apache/hadoop/hbase/protobuf/generated/AccessControlProtos$AccessControlService$Interface
ERROR master.HMaster: ***** ABORTING master ... *****
```

**HBase 는 코프로세서를 못 붙이면 아예 뜨지 않는다.**

#### §8-68 과 무엇이 다른가 — 판단의 핵심

| | Hadoop 3.5 / Jersey (§8-68) | HBase 3.0 / 코프로세서 |
|---|---|---|
| 깨진 것 | **라이브러리**(Jersey 1 → 2) | **HBase 자신의 API** |
| upstream 이 고쳤나 | **예** — master 의 `RangerRESTClient` 는 이미 Jersey 2 | **아니오** |
| 근거 | master pom `hive.version 4.0.1`, Jersey 2 import | master pom **`<hbase.version>2.6.0</hbase.version>`**, 코프로세서가 여전히 구 protobuf import |
| 성격 | upstream 수정 **백포트** — 기계적, 대조 가능 | **원본 이식** — 대조할 구현이 없다 |

즉 이 이식은 **우리가 만든 것이고 검증도 우리 몫이다.** 그래서 "컴파일이
통과했다"를 완료로 보지 않고 DDL 단위까지 시험했다.

#### 인가 공백부터 확인했다 — 컴파일보다 먼저

훅을 하나라도 조용히 떨어뜨리면 그 연산이 통제 밖으로 나간다. 그래서
컴파일을 시도하기 **전에** HBase 3 의 Observer 인터페이스를 `javap` 로 읽어
Ranger 가 구현한 훅과 대조했다.

- Ranger 가 구현한 훅 **53개 중 52개가 HBase 3 에 존재**한다
- `prePrepareBulkLoad`·`preCleanupBulkLoad` 는 **사라진 것이 아니라**
  `BulkLoadObserver` 라는 다른 인터페이스에 있었다(첫 조사가 인터페이스 3개만
  봐서 놓쳤다). 대량적재는 `preBulkLoadHFile` 로도 덮인다
- **진짜 공백은 `preEndpointInvocation` 하나** — 코프로세서 엔드포인트 호출
  인가다. HBase 3 에 대체 훅이 없다. **이것은 남는 공백이다**

#### 이식 내역 — 벽 여섯 개

| # | 벽 | 처리 |
|---|---|---|
| ① | 코프로세서 클래스가 **세 곳**(agent 구현·shim 위임자·레거시 별칭) | 셋 다 |
| ② | protobuf 좌표 이동 | `shaded.protobuf.generated.*`, `org.apache.hbase.thirdparty.com.google.protobuf.*` |
| ③ | `ObserverContext` 와일드카드가 **메서드마다 다름** | `javap` 로 실제 시그니처를 읽어 **규칙 생성** |
| ④ | 인자 목록이 바뀐 8개 | `+currentDesc`·`+currentNs`·`-force`, `preModifyTable` 은 반환형까지 |
| ⑤ | 개명·제거 API 4종 | `filterKeyValue→filterCell`, `addColumnFamily→setColumnFamily`, `HBaseAdmin` 제거, 도달 불가 `catch` |
| ⑥ | **JDK 8 ↔ 17 배타** | 2단계 빌드 |

**★ ③ 이 가장 헷갈렸다.** RegionObserver 는 `<? extends E>` 인데 MasterObserver 는
대체로 `<E>` 다(`postCreateReplicationEndPoint` 같은 예외까지 있다). 일괄
치환했더니 멀쩡한 메서드까지 깨져 **오류가 166개**로 늘었다. `javap` 출력에서
규칙을 생성하도록 바꾸자 한 번에 정리됐다. **추측하지 말고 바이너리에게 물을 것.**

**★ ⑥ 이 가장 근본적이었다.** HBase 3 은 **Java 17 로 컴파일**돼 있어
(`class file has wrong version 61.0, should be 52.0`) JDK 8 은 그 클래스 파일을
읽지 못한다. 그런데 Ranger 2.9 의 `agents-common` 은 Nashorn(`jdk.nashorn.*`)을
써서 **JDK 15+ 에서 컴파일되지 않는다.** 서로 배타적이라 Ranger 코드를 건드리지
않기 위해 **agents-common 은 JDK 8 로 install, HBase 모듈만 JDK 17 로 컴파일**
하는 2단계 빌드로 풀었다.

#### ★ 같은 증상, 반대 처방 — JAX-RS

컴파일을 통과하고 배포했더니 코프로세서는 적재되는데 그다음에서 죽었다:

```
NoClassDefFoundError: javax/ws/rs/core/Cookie
  at PolicyRefresher.<init>
```

§8-68 에서 본 것과 같은 부류인데 **처방이 반대다**:

| | Hadoop 3.5 | HBase 3.0 |
|---|---|---|
| 클래스패스에 이미 있는 것 | `jakarta.ws.rs-api 2.1`(평문 `javax.ws.rs` **있음**) | `hbase-shaded-jersey`(평문 `javax.ws.rs` **없음**) |
| Jersey 1 jar 를 넣으면 | 같은 패키지 두 벌 → `LinkageError` | 중복 없음 → **동작** |
| 그래서 | 소스를 Jersey 2 로 **이식**해야 했다 | **jar 보충으로 충분**하다 |

**같은 오류 메시지라도 클래스패스에 무엇이 이미 있는지에 따라 답이 달라진다.**

#### 검증 — 세 판정 모두 통과

| 판정 | 결과 |
|---|---|
| ① 정책 엔진 | `Switched policy engine to [4]` = Admin 의 `policyVersion 4` |
| ② 데이터 접근 | `oimtest`(ALLOW) 통과 / `oimother`(정책 없음) `Insufficient permissions` |
| ③ **DDL** (시그니처를 바꾼 경로) | `oimother` 의 `create`·`disable` 이 **`AccessDeniedException: Insufficient permissions for user 'oimother' (action=create)`** / 전권 사용자는 `Created table` |

③ 이 이번 이식의 핵심 위험이었다 — 인자 목록을 바꾼 8개가 전부 DDL 훅이라,
잘못 고쳤으면 **테이블 생성·삭제가 조용히 통제 밖으로 나갔을** 것이다.
"컴파일 통과" 로 끝냈으면 확인하지 못했다.

#### 곁다리 — HBase 3 은 클라이언트 접속점 탐색도 바꿨다

마스터·리전서버는 멀쩡한데 `hbase-rest` 만 Ready 가 되지 않았다:

```
Connection refused: hbase-rest-64cc979f9f-bbxq9/10.0.0.19:16000
```

**클라이언트가 자기 자신을 마스터로 여겨 붙으려 한다.** 2.x 는 ZooKeeper 로
마스터를 찾았지만 3.0 은 `RpcConnectionRegistry` 가 기본이고 부트스트랩 주소가
없으면 이렇게 된다. `hbase.masters`·`hbase.client.bootstrap.servers` 를 주어
해결했다. HBase 자체는 정상인데 **클라이언트만** 못 붙는 형태라 원인을 엉뚱한
곳에서 찾기 쉽다.

#### 지금 상태

| 항목 | 값 |
|---|---|
| Hadoop | **3.5.0** (§8-68 의 Jersey 2 백포트) |
| HBase | **3.0.0** (이 절의 이식) |
| Ranger | 2.9.0 — Admin 은 업스트림 이미지 그대로 |
| HDFS 인가 | DENY→`RangerAccessControlException`, ALLOW→통과 |
| HBase 인가 | scan·DDL 모두 정책대로 |
| 비정상 파드 | 없음 |

**남는 공백은 `preEndpointInvocation` 하나** — 코프로세서 엔드포인트 호출은
Ranger 가 검사하지 못한다. HBase 3 에 대체 훅이 없어서다.

**★ 유지보수 부담을 분명히 해 둔다.** `docker/ranger-hbase-plugin` 은 우리가
만든 이식본이고 upstream 대조본이 없다. `docker/hbase` 의 `HBASE_VERSION` 을
바꾸면 **반드시 이 이미지도 함께 손봐야 한다** — 짝이 어긋나면 HBase 가 통째로
기동하지 못한다. Ranger 가 HBase 3 을 정식 지원하면 이 이미지를 지운다.

### 8-70. Hive 4 — Ranger 플러그인을 백포트했다. 세 컴포넌트 모두 통제된다 (2026-09-06)

§8-67 이 남긴 마지막 조각이다. 그때 결론은 "Ranger 2.9 의 Hive 플러그인은
Hive 4 와 바이너리 비호환이고 2.9.0 이 최신 릴리스라 방법이 없다" 였다.
**그 결론은 절반만 맞았다** — 릴리스에는 없지만 **upstream master 에는 있다.**

#### 왜 백포트가 성립하는가 (HBase 와의 대비)

| | Hive 4 (이 절) | HBase 3 (§8-69) |
|---|---|---|
| master 의 pom | **`<hive.version>4.0.1</hive.version>`** | `<hbase.version>2.6.0</hbase.version>` |
| upstream 이 지원하나 | **예** | 아니오 |
| 성격 | **백포트** | 원본 이식 |

#### ★ 그런데 "master 파일을 떼어 온다" 는 실패한다

§8-69 에서 통했던 방식(master 판 파일로 교체)을 먼저 시도했고 막혔다:

```
no suitable constructor found for RangerHiveAccessRequest   24건
incompatible types                                          48건
incomparable types                                          17건
```

master 의 `RangerHiveAuthorizer` 는 master 의 `RangerHiveAccessRequest`·
`RangerHiveResource`·`HiveAccessType` 과 **함께 진화했다.** 게다가 2.9.0 은
`HiveObjectType`·`HiveAccessType` 을 `RangerHiveAuthorizer.java` 맨 아래에
**패키지 전용 top-level enum** 으로 선언해 두어, 그 파일을 갈아끼우면 같은
패키지의 다른 파일들이 타입을 잃는다(`package HiveAccessType does not exist`).

**→ 여기서는 2.9.0 자체 코드를 고치는 쪽이 오히려 좁다.**
HBase 와 정반대 판단이고, 기준은 하나다 — **어느 쪽 변경 표면이 좁은가.**

#### 고친 것은 두 가지뿐

**① `PREEXECHOOKS`** — Hive 4 가 `HiveConf.ConfVars` 상수를 개명했다.
upstream master 의 수정을 그대로 쓴다. 컴파일 시점 enum 상수 대신 **런타임
키 조회**라서 버전 중립적이다:

```java
hiveConf.getVar(ConfVars.PREEXECHOOKS)
  -> hiveConf.getVar(HiveConf.getConfVars("hive.exec.pre.hooks"))
```

설정 키 이름 `hive.exec.pre.hooks` 는 Hive 3·4 가 같다.

**② 인덱스 연산 case 라벨** — Hive 4 가 인덱스 기능을 통째로 걷어내
`HiveOperationType` 에서 `CREATEINDEX`·`DROPINDEX`·`ALTERINDEX_*`·
`SHOWINDEXES` 가 사라졌고 `DROPVIEW_PROPERTIES` 도 없다.

> **지워도 인가 공백이 아니다.** 그 연산 자체가 Hive 4 에 존재하지 않는다.
> `DROPVIEW_PROPERTIES` 는 같은 case 그룹의 `ALTERVIEW_PROPERTIES` 가 덮으며
> 둘 다 `HiveAccessType.ALTER` 로 간다(2.9.0 소스에서 확인).

**★ `CREATEINDEX` 는 두 곳에 있다.** 하나는 혼자 있는 블록이라 라벨만 지우면
문장이 고아가 되고, 다른 하나는 라벨 줄만 지우면 된다. 한쪽만 처리했다가
나머지가 남아 한 번 더 막혔다.

#### 검증 — 세 판정

| 판정 | 결과 |
|---|---|
| ① 정책 엔진 | `Switched policy engine to [12]` = Admin 의 `policyVersion 12` |
| ② 거부 | `HiveAccessControlException Permission denied: user [oimtest] does not have [SELECT] privilege on [default/rangerhive]` |
| ③ 정책으로 뒤집기 | ALLOW 추가 후 같은 질의 통과. **대조군 `oimother` 는 그대로 거부** |

**★ 이 실패는 알아보기 어렵다.** HiveServer2 는 예외를 stdout 에 내지 않고
`/tmp/hive/hive.log` 에만 쓴다. `kubectl logs` 에는 `Hive Session ID = ...` 만
반복되고 파드는 startupProbe 예산을 넘겨 **조용히 kill** 된다. 로그가 비어
보이면 파일 로그를 볼 것.

#### 결산 — §8-66 의 문장은 이제 완전히 거짓이다

§8-66 은 "Knox 로는 뚫었지만 **Ranger 는 권한을 제어하지 않는다**" 로 끝났다.
지금은 셋 다 제어한다:

| 대상 | 버전 | 플러그인 | 인가 증명 |
|---|---|---|---|
| **HDFS** | Hadoop 3.5.0 | `docker/ranger-hdfs-plugin` (Jersey 2 백포트, §8-68) | DENY·ALLOW 양방향 + 대조군 |
| **HBase** | 3.0.0 | `docker/ranger-hbase-plugin` (**이식**, §8-69) | scan + **DDL** + 대조군 |
| **Hive** | 4.0.1 | `docker/ranger-hive-plugin` (백포트, 이 절) | 거부 → 정책 → 허용 + 대조군 |

> ★ 이 표의 Hive 행은 **작성 시점 기준**이다. 곧바로 4.2.1 로 올렸고 그
>   과정에서 여섯 건이 더 걸렸다 — 최종 상태는 §8-71 을 볼 것.

전부 Ranger **2.9.0** 하나로 돌고, Admin 은 업스트림 이미지 그대로다.

#### 남는 것

- **감사(audit)가 세 플러그인 모두 꺼져 있다.** 누가 무엇을 거부당했는지
  남지 않는다 — 지금은 거부가 클라이언트 예외로만 드러난다. 목적지(Solr 또는
  HDFS)를 세우는 것은 별개 작업이다
- **`preEndpointInvocation`**(HBase) — 대체 훅이 없어 남는 공백(§8-69)
- **이식본 세 개의 유지보수 부담.** Hadoop·HBase·Hive 버전을 움직이면
  해당 플러그인 이미지를 함께 손봐야 한다. Ranger 3.0.0 이 릴리스되면
  HDFS·Hive 것은 지울 수 있다(HBase 는 upstream 이 아직 지원하지 않는다)

### 8-71. Hive 4.2.1 — 올리는 일은 스키마·SA·플러그인 세 갈래로 갈라진다 (2026-09-06)

§8-70 에서 Ranger 통제를 세운 대상은 Hive **4.0.1** 이었다. 최신은 **4.2.1** 이다.
버전만 바꾸면 되는 일로 보였고, 실제로는 **서로 다른 계층에서 여섯 건**이 걸렸다.
전부 "오류가 늦게, 엉뚱한 곳에서 나오는" 부류다.

먼저 되돌릴 수 없는 것부터 처리했다 — 메타스토어 스키마 업그레이드는 일방향이다.

```
pg_dump hive_metastore -> C:\Users\darka\iso\backup\hive_metastore-preupgrade-20260906-1421.sql
```

#### ① 이미지 태그와 Maven 아티팩트가 어긋난다

`apache/hive:4.2.1` 은 있는데 **Maven Central 에 4.2.1 아티팩트가 없다**
(`hive-jdbc`·`hive-service`·`hive-exec` 가 404). 바이너리만 릴리스된 경우다.
패치 차이라 API 는 같으므로 **4.2.0 으로 컴파일해 4.2.1 위에서 돌린다.**
`docker/ranger-hive-plugin/Dockerfile` 의 `ARG HIVE_VERSION=4.2.0` 이 그것이고,
매니페스트의 이미지 태그(4.2.1)와 **의도적으로 다르다** — 주석에 그 이유를 남겼다.

#### ② 부트스트랩 Job 이 `default` SA 로 돌아 DB 에 닿지 못했다 (Gotcha 19 네 번째)

스키마를 올리려고 `hive-schematool` Job 을 다시 돌리자:

```
ERROR MetastoreSchemaTool: Failed to get schema version.
Underlying cause: org.postgresql.util.PSQLException : The connection attempt failed.
```

인증 실패가 아니라 **연결 실패**다. 원인은 DB 가 아니라 ztunnel 이었다 —
`allow-database-access` 는 principal 목록으로 5432 를 허용하는데 이 Job 은
`default` SA 로 돌고 `*/sa/default` 는 거기 없다(Gotcha 10: ambient 에서
ServiceAccount 는 곧 신원이다).

**★ 이것이 이 결함을 어렵게 만드는 지점이다.** Job 안의 TCP 사전 검사
(`/dev/tcp/postgresql-headless/5432`)는 **통과한다.** ztunnel 은 15008 에서
끊으므로 포트 열림 검사로는 드러나지 않는다. 그래서 "DB 는 살아 있는데
JDBC 만 안 된다" 로 보이고 JDBC 드라이버·자격을 의심하게 된다.

부트스트랩 Job 은 평소에 돌지 않아 ambient 편입 시점에 드러나지 않고
**재실행할 때** 터진다. `kafka-topics`·`elasticsearch-ilm-setup`·
`databases-migrate` 에 이은 **네 번째** 사례다(§8-52·§8-55).

고친 방법은 앞의 셋과 같다 — 전용 SA 를 만들고 정책에 넣는다:

| 파일 | 변경 |
|---|---|
| `kubernetes/base/bootstrap/hive-schematool.yaml` | `ServiceAccount/hive-schematool` 추가 + `serviceAccountName` |
| `kubernetes/base/service-mesh/authorization-policies.yaml` | `allow-database-access` 에 `"*/sa/hive-schematool"` |

#### ③ `-info` 의 실패는 "스키마가 없다" 를 뜻하지 않는다

Job 은 원래 "`-info` 가 성공하면 건너뛰고, 아니면 `-initSchema`" 두 갈래였다.
그 전제가 틀렸다 — **`-info` 는 스키마가 바이너리보다 낡아도 실패한다.**
그대로 두면 이미 데이터가 든 메타스토어에 `-initSchema` 를 걸게 된다.

세 갈래로 고쳤다. 실패 출력에서 **버전을 읽어냈는지**로 가른다
(`psql` 로 가르지 않는 이유는 hive 이미지에 psql 이 없어서다):

```
INFO=$(schematool -dbType postgres -info ...); RC=$?
if   [ "$RC" -eq 0 ];                                        then 건너뜀
elif echo "$INFO" | grep -qiE "Metastore schema version|Database Schema Version"; then -upgradeSchema
else                                                              -initSchema
fi
```

실제 결과 — 두 단계를 거쳐 올라갔다:

```
Completed upgrade-4.0.0-to-4.1.0.postgres.sql
Completed upgrade-4.1.0-to-4.2.0.postgres.sql
Hive distribution version:  4.2.0
Metastore schema version:   4.2.0
```

이 갈래가 없으면 메타스토어가 `Hive Schema version does not match metastore's`
로 기동하지 못하고, **그 오류는 메타스토어 로그에만** 나온다.

#### ④ 스키마가 최신이 되는 순간 메타스토어가 CrashLoop 한다

스키마를 맞춰 놓자 이번엔 메타스토어가 죽었다:

```
Upgrading from the version 4.2.0
Unknown version specified for upgrade 4.2.0 ...
*** schemaTool failed ***   ->   Schema initialization failed!
```

`apache/hive` 엔트리포인트는 `SKIP_SCHEMA_INIT` 이 없으면 무조건
`schematool -initOrUpgradeSchema` 를 돌리는데, **올릴 대상이 없는 상태를
오류로 처리한다.** 4.0.1 처럼 스키마가 바이너리보다 낮을 때는 드러나지 않고
**최신에 도달하는 순간** 터진다 — 즉 이 결함은 업그레이드를 성공시켜야
비로소 보인다.

스키마의 소유자는 부트스트랩 Job 이므로 메타스토어에서는 끈다
(`hive-server` 가 `IS_RESUME=true` 로 건너뛰는 것과 같은 이유다):

```yaml
- name: SKIP_SCHEMA_INIT
  value: "true"
```

#### ⑤ Ranger 플러그인은 **JDK 21 로** 다시 빌드해야 한다

§8-70 의 플러그인 이미지는 Hive 4.0.1 API 로 컴파일돼 있다. 4.2 로 다시
빌드하자 오류가 하나 났다:

```
RangerHiveAuthorizer.java:[44,36] error: cannot access FileUtils
```

"클래스를 못 찾는다" 로 읽히지만 아니다. `maven-compiler-plugin 3.3` 이
**사유 줄을 삼킨다**(HBase 때와 같다, §8-69). 바이트코드에 직접 물었다:

```
hive-common 4.0.1  class version 52   (Java 8)
hive-common 4.2.0  class version 65   (Java 21)
```

**Hive 4.2 는 Java 21 로 컴파일돼 있고 JDK 8 은 그 클래스 파일을 읽지 못한다.**
4.0.1 이 52 였기 때문에 지금까지 JDK 8 로 됐던 것이다. HBase 3 에서 61(Java 17)로
겪은 것과 같은 함정이고, **판정은 추측이 아니라 `javap -verbose | grep major`** 다.

#### ⑥ Hive 4.2 가 `getTables` 에 `TException` 을 추가했다

JDK 를 올리자 남은 오류가 정확히 한 줄이었다:

```
HiveClient.java:[365,67] error: unreported exception TException;
                                must be caught or declared to be thrown
```

`IMetaStoreClient.getTables(String, String)` 의 선언 예외가 바뀌었고
`getTblListFromHM()` 은 `MetaException` 만 잡고 있었다. **`MetaException` 은
`TException` 의 하위형**이므로 catch 를 넓히면 기존 처리가 그대로 유지된다
(`TException` 은 이미 import 되어 있어 새 import 도 필요 없다).

★ 이 파일에는 `catch (MetaException e)` 가 **두 곳**이다. 뒤쪽은 바로 다음에
`catch (Throwable t)` 가 있어 손댈 필요가 없으므로 **첫 번째만** 바꾸고
남은 한 곳을 세어 확인한다(fail-closed).

★ 인가 로직이 아니라 **서비스 정의용 자원 조회 클라이언트**다 — Ranger Admin
UI 가 정책을 만들 때 DB·테이블 목록을 자동완성하는 데 쓴다.

#### ★ 2단계 빌드의 근거가 실측에서 무너졌다

HBase 판(§8-69)을 본떠 "Ranger 2.9 의 `agents-common` 은 Nashorn 때문에
JDK 15+ 에서 컴파일되지 않는다" 를 전제로 1단계(JDK 8)를 두었다.
**그 전제는 성립하지 않았다** — 2단계(JDK 21)가 `-am` 으로 상위 10개 모듈을
전부 다시 컴파일했고 `Common library for Plugins ... SUCCESS` 로 통과했다.

즉 이 이미지는 **단일 JDK 21 단계로 접을 수 있다.** 접지 않고 둔 이유는
정확성이 아니라 **반복 빌드 시간**이다 — 1단계가 `~/.m2` 를 채워 두면
2단계를 고쳐 다시 돌릴 때 의존성 재다운로드(약 950건)를 건너뛴다.
Dockerfile 주석에 그렇게 적었다. HBase 판에서는 그 분리가 **필수**였고
여기서는 아니다 — 같은 모양이라고 같은 이유는 아니다.

#### ⑦ `build-images.sh` 안에 리터럴 `\n` 이 들어 있었다

이 작업 중에 발견한 별개 결함이다. hive 플러그인 빌드 줄과 반입 루프에
줄바꿈 대신 **문자 그대로의 백슬래시+n** 이 박혀 있었다:

```
sudo podman build --format docker --network host \n  -t oneinch/ranger-hive-plugin:latest ...
```

`bash -n` 은 **통과한다** — 문법적으로 완결된 다른 명령이 되기 때문이다
(`\n` 은 `n` 으로 해석되어 `n` 이라는 인자가 podman 에 넘어간다).
§8-30 의 BOM 건과 같은 부류다: **정적 검증이 잡지 못하는 조용한 변형.**
드러나지 않았던 이유는 그동안 hive 플러그인을 podman 으로 직접 빌드했기
때문이고, 클러스터를 다시 세우려고 이 스크립트를 돌렸다면 거기서 막혔다.

#### 검증 — 판정 기준은 §8-70 과 같다

파드가 `1/1 Running` 인 것으로는 아무것도 증명되지 않는다(Gotcha 40).

| 단계 | 확인 |
|---|---|
| ① 정책 엔진 | `/tmp/hive/hive.log` 에 `Switched policy engine to [12]`, ERROR 0건 |
| ② 허용 | `oimtest` 로 `SELECT * FROM rangerhive` -> `No rows selected (5.171 seconds)` |
| ③ 대조군 | `oimother` 로 같은 질의 -> `HiveAccessControlException Permission denied: user [oimother] does not have [SELECT] privilege on [default/rangerhive/*]` |

정책을 하나도 바꾸지 않고 §8-70 이 남긴 상태 그대로 시험했다 — **버전을
올린 뒤에도 같은 정책이 같은 판정을 낸다**는 것이 여기서 필요한 증거다.

HDFS·HBase 도 함께 확인했다(플러그인을 건드리지 않았으므로 회귀만 본다):

| 대상 | 확인 |
|---|---|
| HDFS (Hadoop 3.5.0) | `Switched policy engine to [9]` = 캐시 파일의 `policyVersion 9` |
| HBase (3.0.0) | `Switched policy engine to [4]` |

#### 최종 상태

| 대상 | 버전 | 플러그인 | 비고 |
|---|---|---|---|
| **HDFS** | Hadoop 3.5.0 | `docker/ranger-hdfs-plugin` (Jersey 2 백포트) | §8-68 |
| **HBase** | 3.0.0 | `docker/ranger-hbase-plugin` (이식) | §8-69 |
| **Hive** | **4.2.1** | `docker/ranger-hive-plugin` (백포트, JDK 21 빌드) | 이 절 |

셋 다 Ranger **2.9.0** 하나로 돌고 Admin 은 업스트림 이미지 그대로다.
메타스토어 스키마는 **4.2.0**, 컴파일 대상 아티팩트도 4.2.0, 런타임 이미지는
4.2.1 이다 — 이 셋이 다른 것은 ① 때문이며 의도된 것이다.

> ★★ **정정(§8-72).** 이 절은 "`HADOOP_CLASSPATH` 가 가리키는
> `hadoop-aws-3.3.6.jar`·`aws-java-sdk-bundle-1.12.367.jar` 이 4.2.1 에도
> 그대로 있으므로 S3A 는 안전하다" 로 확인했다. **몇 시간 뒤 그것이 거짓이
> 되었다** — `apache/hive:4.2.1` 태그의 내용이 바뀌어(Hadoop 3.3.6 -> 3.4.1,
> AWS SDK v1 -> v2) 그 파일들이 사라졌고 S3A 가 `ClassNotFoundException` 으로
> 깨졌다. 확인이 틀렸던 것이 아니라 **확인 대상이 움직였다.**
> 지금은 셋 모두 `apache/hive@sha256:b19bb5bd…` 다이제스트로 고정되어 있다.
> 버전 태그를 신뢰한 것이 결함이었다 — 상세는 §8-72 ④.

#### 남는 것

- **감사(audit)는 여전히 세 플러그인 모두 꺼져 있다** — §8-70 의 목록 그대로다
- **`docker/ranger-hive-plugin` 의 2단계 빌드는 접을 수 있다.** 지금은 캐시
  이득 때문에 두었을 뿐이다(위 ★ 참조)
- **버전 올리기의 비용이 이제 명확하다.** Hadoop·HBase·Hive 중 하나를 움직이면
  ⓐ 해당 플러그인 이미지의 컴파일 대상 버전, ⓑ 빌드 JDK, ⓒ (Hive 라면)
  메타스토어 스키마까지 셋이 함께 움직인다. Ranger 3.0.0 이 나오면 ⓐⓑ 는
  HDFS·Hive 에서 사라진다

### 8-72. 이미지 태그를 전부 고정했다 — 그 과정에서 드러난 것들 (2026-09-06)

"다른 컨테이너 이미지들도 최신인지" 를 확인하는 일로 시작했다. 확인 자체는
레지스트리 API 로 끝났지만, **더 큰 문제가 버전이 아니라 태그였다.**

렌더된 고유 이미지 92개 중 **65개 참조가 `:latest`·`:stable`·`:slim`·`:lts`**
였다. 그 상태에서는 "최신인가" 를 물을 수 없다 — 파드를 다시 만들 때마다
다른 것이 내려올 수 있고, **재현성이 없다.**

#### 핀의 원천이 둘이었고, 실제로 어긋나 있었다

`overlays/prod/kustomization.yaml` 의 `images:` 블록이 약 40종을 핀하고
base 매니페스트는 `:latest` 였다. 두 값이 갈린 것을 실측으로 셋 찾았다:

| 이미지 | prod 가 핀한 것 | 실제로 도는 것 |
|---|---|---|
| `clickhouse/clickhouse-server` | `25.9-alpine` | **26.8**(비-alpine) — 버전뿐 아니라 **계열이 다르다** |
| `percona/percona-server-mongodb` | `8.3.8` | **8.0.29-13** — `latest` 가 가리키는 것은 8.3 이 아니라 **8.0 LTS** 다 |
| `apache/knox` | 다이제스트 | `3.0`(RC 추종 가변 태그) — local·dev 는 **다른 바이너리**를 돌리고 있었다 |

게다가 base 의 65곳 중 prod 블록이 덮는 것은 일부뿐이라, 나머지는 prod 에서
Enforce 인 Kyverno `disallow-latest` 에 걸려 **배포가 거부된다.**

→ **핀은 base 매니페스트가 소유한다.** prod 의 `images:` 블록은 제거했다.
세 환경이 같은 바이너리를 쓰고, 버전을 바꿀 자리가 하나이며, 값과 사유가
같은 곳에 있다. prod 전용 오버라이드가 필요해지면 그때 되살린다.

#### 핀 값을 고르는 규칙 — "최신" 이 항상 정답은 아니다

| 부류 | 규칙 | 예 |
|---|---|---|
| 데이터 보유 | **지금 도는 버전**으로 고정 | PostgreSQL 18.6 · MariaDB 12.3.3 · Redis 8.10.1 · ClickHouse 26.8 · MongoDB 8.0.29-13 |
| 무상태 | 레지스트리 최신 | nginx 1.31.5 · Grafana 13.2.1 · OTel 0.160.0 · curl 8.22.0 |
| 버전 태그가 없는 것 | **다이제스트** | `inquotient/admin` · `inquotient/cmmn-api` · `apache/knox` · `apache/hive` |
| 베이스 이미지에 묶인 것 | **올리면 안 된다** | `hadoop-aws` · `aws-java-sdk-bundle`(아래) |

★ 마지막 줄이 중요하다. `docker/spark-iceberg` 의 `HADOOP_AWS_VERSION=3.3.4` 는
낡아 보이지만 **최신으로 올리면 깨진다** — `apache/spark:3.5.6` 이 번들한 것이
`hadoop-client-api-3.3.4.jar` 이고 hadoop-aws 는 같은 계열을 전제한다. AWS SDK
계열(v1/v2)도 hadoop-aws 가 정한다. **상한을 정하는 것은 레지스트리가 아니라
베이스 이미지다.** Iceberg 만 1.7.1 -> **1.11.0** 으로 올렸다.

#### 적용하며 드러난 것 — 여섯 건

**① 네 개의 StatefulSet 은 애초에 어떤 변경도 받을 수 없었다.**
`gitlab`·`jenkins`·`keycloak`·`pyroscope` 가 apply 를 거부했다:

```
StatefulSet.apps "gitlab" is invalid: spec: Forbidden: updates to statefulset spec
for fields other than 'replicas', 'ordinals', 'template', ... are forbidden
```

원인은 이미지가 아니다 — 라이브의 `volumeClaimTemplates.storageClassName` 이
**비어 있고** 렌더 결과는 `standard` 다. `standard` StorageClass 를 도입하기
전(Gotcha 5)에 만들어진 넷이고, 그 이후로 **매니페스트 변경이 한 번도 반영된
적이 없다.** 오류는 apply 할 때만 나오고 평소에는 아무 증상이 없다.

해소는 `kubectl delete sts <name> --cascade=orphan` 후 재적용이다 — 파드와
PVC 는 그대로 남고 새 StatefulSet 이 그것을 입양한다. PVC 4개와 파드 4개가
모두 유지되는 것을 확인한 뒤 진행했다.

★ **`kubectl apply` 의 오류를 `head` 로 자르지 말 것.** 첫 적용에서
`grep -iE "error|warning: " | head -10` 이 경고 10줄로 채워져 **오류가
잘려 나갔고**, 나는 "오류 0" 으로 읽었다. Gotcha 12 의 반복이다.

**② 완료된 Job 5건은 `spec.template` 이 불변이라 거부된다.** 정상이다.
`databases-migrate`·`defectdojo-initializer`·`elasticsearch-ilm-setup`·
`hive-schematool`·`keycloak-realm-bootstrap` — 새 이미지를 반영하려면 지워서
다시 돌려야 한다. 즉 **매니페스트와 클러스터가 그때까지 갈라져 있다.**

**③ Dependency-Track 의 `latest` 는 4.x 였다.** 5.1.0 으로 핀하자 기동 즉시:

```
IllegalStateException: Legacy Dependency-Track v4 configuration properties are
no longer supported: [alpine.database.username, alpine.data.directory, ...]
```

v5 는 설정 키를 `alpine.*` -> `dt.*` 로 바꾼 **메이저**다. PostgreSQL 스키마
이관도 따라온다. 별도 작업이므로 4.x 계열 최신(**4.14.3**)에 머문다.
★ "`latest` 를 그 시점의 최신 버전으로 바꾼다" 가 **무해하지 않다**는 실례다.

**④ `apache/hive:4.2.1` 은 같은 태그로 내용이 바뀌었다.** 이번 세션 안에서다.

```
이전 : hadoop-aws-3.3.6.jar   aws-java-sdk-bundle-1.12.367.jar   (Hadoop 3.3.6 · AWS SDK v1)
이후 : hadoop-aws-3.4.1.jar   bundle-2.24.6.jar                  (Hadoop 3.4.1 · AWS SDK v2)
```

매니페스트의 `HADOOP_CLASSPATH` 가 **jar 파일명을 하드코딩**하고 있어 그
순간 S3A 가 깨졌다:

```
Error: FAILED: RuntimeException java.lang.ClassNotFoundException:
       Class org.apache.hadoop.fs.s3a.S3AFileSystem not found
```

★ 증상이 나오는 곳이 원인과 멀다 — 파드는 `1/1 Running` 이고(probe 가 TCP다)
DDL 을 실행해야 비로소 드러난다. 메타스토어도 같은 하드코딩이라 함께 깨져
있었으나 **아무 오류도 내지 않았다.**

★★ 고친 방식이 요점이다. jar 이름을 3.4.1 판으로 고치는 것만으로는 다음
번에 또 깨진다. **이미지를 다이제스트로 고정해야 비로소 파일명 하드코딩이
안전해진다** — 셋(`hive-schematool`·`hive-metastore`·`hive-server`)을 모두
`apache/hive@sha256:b19bb5bd…` 로 바꿨다. 셋은 반드시 같은 다이제스트여야
한다(스키마 도구와 서버의 버전이 갈리면 스키마 검사가 어긋난다).

**⑤ filebeat 을 올리면 Elasticsearch 가 yellow 가 된다.** 9.5.2 -> 9.5.3 직후:

```
yellow  .ds-filebeat-9.5.3-2026.09.06-000001  rep=1
```

filebeat 의 데이터스트림 이름에는 **버전이 들어간다.** 즉 버전을 올릴 때마다
**새 인덱스**가 생기고, filebeat 이 스스로 설치하는 템플릿의 기본값이 복제본
1 이라 단일 노드에서 배정될 곳이 없다. yellow 면 **ECK 가 파드를 롤링하지
않는다**(Gotcha 14·34).

`elasticsearch-ilm-setup` 의 템플릿 목록으로는 막지 못한다 — 그 Job 은
filebeat 데이터스트림을 모르고, filebeat 이 나중에 자기 것을 덮어쓴다.
**filebeat 설정에 넣어야 한다:**

```yaml
setup.template.settings:
  index.number_of_shards: 1
  index.number_of_replicas: 0
```

템플릿은 생성 시점에만 적용되므로 이미 만들어진 인덱스에는 `_settings` 를
한 번 더 밀었다. 그 뒤 green.

**⑥ 대량 재시작은 OTel 게이트웨이의 4MB gRPC 한계를 넘긴다.**

```
Exporting failed. Dropping data. ... ResourceExhausted: grpc: received message
after decompression larger than max 4194304   dropped_items=1081
```

117개 파드를 한꺼번에 재시작하면 에이전트가 밀린 로그를 한꺼번에 읽어 배치가
커진다. **일시적이다** — 재시작이 끝난 뒤 3분간 오류 0건이었다. 다만 과금
경로(§8-55)가 이 구간에서 유실될 수 있다는 뜻이므로 기록해 둔다.

★ Vault 가 `0/1` 이 된 것은 회귀가 아니다 — **재시작하면 봉인되는 것이 설계**고
문서에 이미 있다(`local/vault-init.sh unseal`). 대량 재시작을 하면 반드시
따라온다는 것만 기억하면 된다.

#### 검증

| 항목 | 결과 |
|---|---|
| 렌더 결과의 가변 태그 | **0건**(local·dev·prod 3개 오버레이 합집합) |
| 세 오버레이 렌더 | 전부 성공 — 456 / 333 / 341 객체 |
| 파드 | 117개, 비정상 0 · Ready 아님 0 |
| Elasticsearch · Kibana | **green** (9.5.3) |
| Ranger 인가 회귀 | HDFS `정책 10` · HBase `정책 5` · Hive 허용/거부 전환 재확인 |

Hive 는 §8-71 과 같은 기준으로 다시 증명했다 — `oimtest` 는
`No rows selected`, 대조군 `oimother` 는
`HiveAccessControlException Permission denied ... [SELECT] on default/rangerhive/*`.

#### 남는 것

- ~~**Dependency-Track v5 이관**~~ — **§8-74 에서 해소됐다.** 옮길 데이터가
  0건이라 마이그레이션하지 않고 5.1.0 을 새로 세웠다
- **Istio 1.24.2 -> 1.31.0 · k3s v1.31.4 -> v1.36.4** — 오퍼레이터 계층이라
  `local/install-operators.sh` 소관이다. Istio 는 이 클러스터의 인가가 ztunnel
  에 얹혀 있어(Gotcha 9·13) 마지막에 해야 한다
- **OpenReplay 17종 v1.27.x -> v1.28.0**, 그리고 그 번들의
  `clickhouse 25.9-alpine`·`postgres 17`·`alpine/git 2.52.0` — 업스트림
  벤더링본이라 별도 판단이 필요하다
- **불변 필드 드리프트를 찾는 수단이 없다.** ①은 apply 를 해봐야 드러났다.
  `kubectl diff -k` 를 정기적으로 돌리는 것이 답이다

### 8-73. Istio 1.24.2 -> 1.31.0 · k3s 1.31.4 -> 1.36.4 — 12단계 교차 업그레이드 (2026-09-06)

§8-72 의 "남는 것" 에 적어 둔 플랫폼 계층이다. 오퍼레이터 계층이라 매니페스트가
아니라 `local/install-operators.sh`·`local/bootstrap-wsl-k3s.sh` 소관이고,
이 클러스터의 인가가 ztunnel 에 얹혀 있어(Gotcha 9·13) 가장 위험한 작업이다.

#### 순서를 잘못 계획했다 — 한쪽을 먼저 끝낼 수 없다

처음에는 "k3s 를 먼저 올리고 그다음 Istio" 로 계획했다. **틀렸다.**
Istio 공식 지원 표(`istio.io` 의 `data/compatibility/supportStatus.yml`)를
받아 보니 배타적이었다:

| Istio | 지원 Kubernetes |
|---|---|
| **1.24**(출발점) | 1.28 – **1.31** |
| 1.25 | 1.29 – 1.32 |
| 1.26 · 1.27 | 1.29 – 1.33 |
| 1.28 | 1.30 – 1.34 |
| 1.29 | **1.31** – 1.35 |
| 1.30 · **1.31**(목표) | **1.32** – 1.36 |

k3s 를 1.32 로 올리는 순간 Istio 1.24 가 지원 밖으로 나가고, Istio 1.31 은
k8s 1.32 미만에서 돌지 않는다. **겹치는 구간을 밟으며 번갈아 올려야 한다.**

★ 이 표는 **추측하지 말고 받아 볼 것.** 문서 페이지의 표는 shortcode 로
렌더되므로 페이지를 긁어도 값이 없다. 원천은
`https://raw.githubusercontent.com/istio/istio.io/master/data/compatibility/supportStatus.yml`
이고 `k8sVersions` 필드가 그것이다.

#### 실행한 12단계

| # | 대상 | 버전 | 그때의 상대 |
|:--:|---|---|---|
| 1–5 | Istio | 1.24.2 -> 1.25.5 -> 1.26.8 -> 1.27.9 -> 1.28.10 -> **1.29.7** | k8s 1.31.4 |
| 6–9 | k3s | 1.31.4 -> 1.32.13 -> 1.33.13 -> 1.34.11 -> **1.35.8** | Istio 1.29.7 |
| 10–11 | Istio | 1.29.7 -> 1.30.4 -> **1.31.0** | k8s 1.35.8 |
| 12 | k3s | 1.35.8 -> **1.36.4** | Istio 1.31.0 |

**마이너를 하나도 건너뛰지 않았다.** Istio·Kubernetes 모두 한 단계씩만
지원한다. 건너뛰면 ztunnel 이 AuthorizationPolicy 를 어떻게 해석하는지가
함께 흔들릴 수 있고, 이 레포는 접미 매칭 규칙 26곳이 거기 얹혀 있다(§8-47).

#### 방법

**Istio** — 설치가 `istioctl install --set profile=ambient` 였으므로 같은
프로파일·리소스 오버라이드로 in-place 업그레이드한다. 오버라이드를 빠뜨리면
istiod 2Gi·ztunnel 512Mi 기본값이 돌아와 단일 노드에서 스케줄되지 않는다.

```bash
istioctl x precheck                    # ★ 매 단계 먼저
istioctl install --set profile=ambient -y \
  --set values.pilot.resources.requests.memory=256Mi \
  --set values.pilot.resources.requests.cpu=100m \
  --set values.ztunnel.resources.requests.memory=128Mi \
  --set values.ztunnel.resources.requests.cpu=50m
```

**k3s** — 공식 설치 스크립트를 **같은 서버 인자로** 다시 실행한다. 인자를
빠뜨리면 스크립트가 systemd 유닛을 새로 쓰면서 `--flannel-backend=none` 등이
사라지고 Cilium 과 충돌한다.

```bash
curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh && chmod +x /tmp/k3s-install.sh
sudo INSTALL_K3S_VERSION="v1.3X.Y+k3sZ" /tmp/k3s-install.sh server \
  --write-kubeconfig-mode 644 --disable traefik --disable servicelb \
  --flannel-backend=none --disable-network-policy \
  --kubelet-arg=config=/etc/rancher/k3s/kubelet-config.yaml
```

★ 데이터스토어는 **sqlite** 다(etcd 아님). 백업은 k3s 를 멈추고
`/var/lib/rancher/k3s/server/db/state.db`(+`-wal`)를 복사하면 된다 —
k3s 를 멈춰도 containerd 가 파드를 유지하므로 워크로드는 계속 돈다.
실행 전에 떠 두었다: `C:\Users\darka\iso\backup\k3s-state-preupgrade-20260906-1826.db`

#### 관찰한 것

**① k3s 업그레이드는 워크로드를 건드리지 않는다.** 5회 모두 파드 117개가
재시작 없이 유지됐고 istio-system 세 파드의 AGE 도 그대로였다. API 서버만
잠깐 내려간다 — 그 사이에 실행된 CronJob 하나(`openmeter-billing-collect-invoices`)
가 `Error` 로 끝났고 다음 스케줄에 정상 실행됐다.

**② Istio 업그레이드는 ztunnel 을 재시작하므로 장기 TCP 연결이 끊긴다.**
매 단계마다 OpenReplay 의 `canvases`·`images`·`sink` 가 CrashLoop 에 들어갔다:

```
2026/09/06 10:09:39 pgConn.Ping() error: unexpected EOF
```

재연결을 하지 않는 애플리케이션의 문제이고 **자가 복구된다**(90초 내). 다만
ztunnel 을 롤링할 때마다 반복되므로, 연결을 오래 붙들고 있는 워크로드가
있으면 예상해 둘 것.

**③ waypoint 와 게이트웨이는 스스로 교체된다.** 교체 중 이전 파드가 잠깐
`Error`·`Terminating` 으로 보이는데 정상이다 — 새 파드가 뜨면 사라진다.

**④ `istioctl x precheck` 는 12회 전부 통과했다.** 실제로 문제를 잡아 준 적은
없지만, 통과하지 못했다면 그 단계에서 멈췄을 것이므로 계속 넣는 것이 맞다.

#### 검증

각 단계마다 같은 기준으로 확인했다 — **정책이 실제로 적재되어 있는가**가
핵심이다. 파드가 `1/1 Running` 인 것으로는 아무것도 증명되지 않는다.

```
istioctl ztunnel-config policy | grep local     -> 6건 (매 단계 동일)
  allow-database-access · allow-datalakehouse-access · allow-messaging-access
  allow-observability-access · api-require-jwt · spark-connect-authz
```

최종 상태:

| 항목 | 결과 |
|---|---|
| 노드 | `v1.36.4+k3s1` |
| Istio | istiod · ztunnel · istio-cni 전부 `1.31.0-distroless` |
| ztunnel 정책 | **6건** — 시작 시점과 동일 |
| 파드 | 117개, Ready 아닌 것 **0** |
| Elasticsearch · Kibana | **green** (9.5.3) |
| HDFS 인가 | `Switched policy engine to [10]` |
| HBase 인가 | `Switched policy engine to [5]` |
| Hive 인가 | `oimtest` -> `No rows selected` · `oimother` -> `HiveAccessControlException Permission denied ... [SELECT] on default/rangerhive/*` |

#### 남는 것

- **`envoyOtelAls` 를 다시 시험해 볼 것.** Gotcha 21 은 "Istio 1.24.2 +
  수집기 0.160 에서 gRPC 스트림이 `upstream reset: protocol error` 로 끊긴다"
  였다. 1.31.0 에서도 같은지 확인하지 않았다 — 지금이 그 전제가 바뀐 시점이다
- **오퍼레이터 나머지** — ECK · Kyverno · cert-manager · Tetragon ·
  Trivy Operator · Policy Reporter 는 이번에 손대지 않았다. k8s 1.36 에서
  지원되는지 각각 확인이 필요하다
- ~~**Dependency-Track v5 이관**(§8-72)~~ — **§8-74 에서 해소됐다**

### 8-74. Dependency-Track v5 — 마이그레이션하지 않고 새로 세웠다 (2026-09-06)

§8-72 가 "별도 작업" 으로 미뤄 둔 것이다. `:latest` 를 그 시점 최신으로 바꾸는
것이 무해하지 않다는 실례이기도 했다 — `dependencytrack/apiserver:latest` 는
**4.x** 였고, 5.1.0 으로 핀하자 기동 즉시 죽었다:

```
IllegalStateException: Legacy Dependency-Track v4 configuration properties are
no longer supported: [alpine.database.username, alpine.data.directory,
alpine.database.url, alpine.database.password]
```

#### 먼저 물어야 할 것 — 옮길 데이터가 있는가

공식 마이그레이션 경로는 무겁다. `v4-migrator` CLI 로 extract → transform →
load 3단계를 돌리고, v5 쪽 Postgres 안에 스테이징 스키마(`dt_v4_migration`)를
만들며, **v4 는 전 과정 동안 정지**해야 한다. 게다가 가이드에
"Lossy and non-obvious changes" 절이 통째로 있다 — 팀·OIDC 그룹·태그 중복 제거,
프로젝트 중복 제거, EPSS 값, 알림 규칙 설정, 저장소·분석기 **자격증명**,
암호화된 속성 값… 일부는 유실된다.

그래서 먼저 셌다:

```
PROJECT 0 · COMPONENT 0 · BOM 0 · FINDINGATTRIBUTION 0 · POLICYVIOLATION 0
MANAGEDUSER 1  (기본 admin 뿐)
```

**한 번도 SBOM 을 받은 적이 없었다.** DB 1.78 GB 중 1.76 GB(99%)가 NVD 미러다:

| 테이블 | 행 수 | 크기 |
|---|---:|---:|
| `AFFECTEDVERSIONATTRIBUTION` | 2,563,199 | 787 MB |
| `VULNERABILITY` | 387,338 | 551 MB |
| `VULNERABLESOFTWARE` | 497,851 | 258 MB |

PVC `/data` 3.0 GB 도 같은 성격이다. 둘 다 v5 가 다시 받는다.
그리고 CI·스크립트 어디에도 **SBOM 을 올리는 연동이 없다** — `.gitlab-ci.yml`
의 Trivy 3잡은 결과를 DT 로 보내지 않는다. 즉 떠 있기만 하고 파이프라인에
연결된 적이 없다.

→ **마이그레이션할 것이 없다. 새로 세운다.**

#### 설정 이름은 추측하지 않았다

v5 는 키를 `alpine.*` -> `dt.*` 로 갈았고, 5.0.0-rc.2 에서 **약 100개를 한 번 더**
kebab-case 로 개명했다. 호환 shim 이 없어 하나만 틀려도 기동을 거부한다.
그래서 두 원천에 대조했다:

1. 공식 설정 레퍼런스 `docs/next/reference/configuration/properties/`
2. 공식 Helm 차트 **2.3.0**(앱 5.1.0)을 `helm template` 으로 렌더

★ 이 레포는 **No Helm** 이다. 차트는 **읽기 위해서만** 썼다 — Tetragon 과 같은
방식이다(CLAUDE.md 0번 계층). 클러스터에 Helm 릴리스는 남지 않는다.

내 첫 추측은 틀렸다. `DT_DATABASE_*` 가 아니라 **`DT_DATASOURCE_*`** 다:

| v4 | v5 |
|---|---|
| `ALPINE_DATABASE_URL` | `DT_DATASOURCE_URL` (+ `?reWriteBatchedInserts=true`) |
| `ALPINE_DATABASE_USERNAME` | `DT_DATASOURCE_USERNAME` |
| `ALPINE_DATABASE_PASSWORD` | `DT_DATASOURCE_PASSWORD` |
| `ALPINE_DATABASE_MODE`·`_DRIVER` | **없어짐** (v5 는 PostgreSQL 전용) |
| `ALPINE_DATA_DIRECTORY` | `DT_FILE_STORAGE_LOCAL_DIRECTORY` (+ `DT_FILE_STORAGE_PROVIDER`) |
| — | **`DT_SECRET_MANAGEMENT_PROVIDER` · `DT_SECRET_MANAGEMENT_DATABASE_KEK`** |
| — | `DT_MANAGEMENT_PORT` · `DT_METRICS_ENABLED` |

★★ **KEK 는 v4 에 없던 필수 항목이다.** v5 는 저장소·분석기 자격증명을 DB 에
암호화해 넣고 그 키를 KEK 로 감싼다(v4 는 데이터 디렉터리의 `secret.key`
파일이었다). **32바이트 난수의 base64** 여야 한다 —
`local/create-secrets.sh` 의 `gen()` 은 hex 라 쓸 수 없어 `openssl rand -base64 32`
를 따로 쓴다. **이 값을 잃으면 저장된 자격증명을 복호화할 수 없다.**

#### 포트와 프로브가 바뀌었다

v5 는 **관리 포트 9000** 이 생겼다. 헬스체크와 Prometheus 지표가 모두 그쪽이다.

```
v4 :  startup/liveness/readiness  ->  GET /api/version           (8080)
v5 :  startup   -> GET /health/started  (9000)
      liveness  -> GET /health/live     (9000)
      readiness -> GET /health/ready    (9000)
```

v4 경로를 그대로 두면 8080 은 살아 있으므로 **프로브는 통과하는데 준비 판정이
틀린다** — 조용히 어긋나는 부류다.

#### 전환 절차

되돌릴 수 있게 했다. `DROP DATABASE` 대신 **이름을 바꿔 보관**한다:

```sql
ALTER DATABASE dependencytrack RENAME TO dependencytrack_v4_20260906;
CREATE DATABASE dependencytrack OWNER dependencytrack;
```

그다음 KEK 를 시크릿에 추가하고, PVC 를 지우고(3 GB NVD 캐시는 v5 에 무의미),
적용한다. v5 는 `DT_INIT_TASK_DATABASE_MIGRATION_ENABLED`·`_SEEDING_ENABLED`
로 **스스로 스키마를 만들고 시드한다** — 별도 초기화 Job 이 필요 없다.

#### ★★ 그 과정에서 드러난 것 — 결함 둘이 서로를 가리고 있었다

**① 프런트의 `API_BASE_URL` 이 처음부터 무시되고 있었다.**
프런트 엔트리포인트(`30-oidc-configuration.sh`)는 **자기 static 디렉터리의
`config.json` 을 제자리에서 고쳐** 환경변수를 넣는다:

```sh
if ! touch ./static/config.json 2>/dev/null; then
  entrypoint_log "$ME: info: can not modify config.json - ENV configuration will be ignored"
```

우리는 `readOnlyRootFilesystem: true` 였고 그 경로에 쓰기 볼륨이 없다. 그래서
`touch` 가 실패하고 **환경변수가 통째로 버려졌다.** 실측으로
`/static/config.json` 이 `"API_BASE_URL": ""` 였다.

★ 알아채기 어려운 이유가 셋이다 — 실패 로그가 **`info` 한 줄**이고, 파드는
**Ready** 이며, 프로브가 `/` 였다(그 경로는 config 와 무관하게 200 을 준다).
★★ **v4 이미지에 같은 스크립트가 있다.** 즉 이 결함은 v5 가 만든 것이 아니라
**계속 있었고**, 아무도 UI 를 쓰지 않아 드러나지 않았다.

고친 방법은 업스트림 차트와 같다 — 이 컨테이너만
`readOnlyRootFilesystem: false`. ConfigMap 으로 `config.json` 을 주입하는 대안도
있으나 **버전이 올라가며 키가 늘면 조용히 어긋난다** — §8-72 ④(하드코딩한
jar 이름)와 같은 실패 유형이라 택하지 않았다. 프로브도
`/static/config.json` 으로 바꿔 **설정이 실제로 써졌는지**를 보게 했다.

**② ①을 고치자 두 번째 불일치가 드러났다.** `API_BASE_URL` 이
`http://localhost:8081` 인데 `local/access-gen.py` 와 `ACCESS.md` 는 API
port-forward 를 **8087** 로 안내한다. ①이 값을 통째로 버리고 있었기 때문에
이 불일치가 여태 보이지 않았다. **결함 하나가 다른 결함을 가리고 있었던 것이다.**
8087 로 맞췄다.

#### 검증

| 항목 | 결과 |
|---|---|
| 파드 | apiserver · frontend 둘 다 `1/1 Running` |
| `/health/ready` (9000) | `{"status":"UP","checks":[{"name":"dataSources","status":"UP",...}]}` |
| `/api/version` (8080) | `"application":"Dependency-Track"` · `5.1.0` |
| 스키마 자동 생성 | 새 DB 에 **103개 테이블** |
| 미러링 | NVD·EPSS·KEV 진행 — `VULNERABILITY` 79,500행 / 248 MB (계속 증가) |
| 프런트 설정 | `"API_BASE_URL": "http://localhost:8087"` — 엔트리포인트가 `effective config` 출력 |
| 서비스 경유 | apiserver -> `dependency-track:8080` · frontend -> `dependency-track-api:8080` 양방향 확인 |

★ `/api/version` 의 `framework.name` 은 여전히 **`Alpine`** 이다(버전만 5.1.0).
v5 가 Alpine 프레임워크를 걷어낸 것이 아니라 **설정 네임스페이스를 옮긴 것**이다
— 이 절을 쓰며 처음에 "프레임워크를 걷어냈다" 로 잘못 적었다가 바로잡았다.

#### 남는 것

- **파이프라인 연동이 없다.** v5 든 v4 든 SBOM 을 받지 않으면 빈 껍데기다.
  **버전 올리기보다 이쪽이 먼저다** — 다만 조각내면 오히려 비싸므로
  **한 덩어리로 나중에** 하기로 결정했다. 범위와 사유는 **§9-7**
- **`dependencytrack_v4_20260906`(1.78 GB)를 언젠가 지울 것.** 되돌릴 필요가
  없다고 확신이 서면 `DROP DATABASE`
- **파일 저장소를 MinIO 로 옮길 수 있다.** v5 는 `DT_FILE_STORAGE_PROVIDER=s3`
  를 지원한다 — PVC 대신 이미 있는 MinIO 를 쓰면 RWO 제약이 사라진다
- **관리 포트 9000 의 지표를 Prometheus 가 긁게 할 것.** Service 에 포트는
  열어 두었으나 scrape 설정과 NetworkPolicy 는 아직 없다

### 8-75. ShardingSphere-Proxy 도입 — 소비자 없이 옆에 세운다 (2026-09-07)

관계형 DB 접근 계층을 네 후보로 검토한 끝에 **ShardingSphere-Proxy 를 도입했다.**
검토 과정 자체가 결론만큼 중요하므로 함께 남긴다.

#### 검토한 것 — 그리고 두 번 틀린 것

| 후보 | 판정 |
|---|---|
| **CNPG** · **Galera** | 검토 대상이 아니었다 — **§13-2 의 기결정 사항**이고 `replicas-prod.yaml`·`ha-verification/` 이 이미 참조한다 |
| **MariaDB Operator** | §13-2 의 **빈칸**. Galera 라는 기구는 골랐으나 누가 운영할지는 고르지 않았다 |
| **ProxySQL** | ShardingSphere 보다 가볍고(C++ vs JVM) `mysql_galera_hostgroups` 로 Galera 를 안다. 저장소 설명이 이제 *"proxy for MySQL and PostgreSQL"* 이라 커버리지도 같다 |
| **Envoy** | MySQL·Postgres·Mongo·Redis 네트워크 필터가 **전부 있다.** 이미 돌고 있는 것이기도 하다(waypoint) |

★ **두 번 틀렸고 둘 다 사용자가 잡아 주었다.**

**① "k3s 를 먼저 올리자"(§8-73)** 와 같은 부류의 실수를 여기서도 했다 —
ShardingSphere 를 **샤딩 도구로만 평가**하고 "필요 없다" 로 끝냈다. 게이트웨이
관점(토폴로지 은닉·자격 은닉·감사)은 다른 질문이고, 그 관점에서는 §15-1 이
"가장 큰 숨은 작업" 이라 부른 접속 문자열 변경을 흡수한다는 진짜 논거가 있다.

**② "ProxySQL 이 모든 축에서 낫다" 도 틀렸다.** 게이트웨이 용도의 축에서만
그렇다. **샤딩 · 분산 SQL · 분산 트랜잭션 · 암호화/마스킹 · 복잡한 분할**에서는
ProxySQL 이 경쟁 상대가 아니다. 두 제품은 같은 범주가 아니다 — 하나는 라우팅
프록시, 하나는 데이터 분할 플랫폼이다.

★ 그리고 조사 중에 **"SQL 감사는 Ranger 의 자리" 라고 쓴 것도 틀렸다** —
Ranger 플러그인은 Hive·Trino·HBase·HDFS·Kafka 계열이고 **PostgreSQL·MariaDB
플러그인은 없다.** 그 조언대로 하면 켤 것이 없다.

#### 도입 판단

문서 전수 조사 결과 ShardingSphere 고유 축 다섯 중 넷은 **요구사항이 0건**이고
하나(페더레이션)는 Trino 가 담당한다. 남는 것이 **암호화·마스킹**이고, 그것은
규모가 아니라 거버넌스 요건이라 "언젠가" 가 아니라 "요건이 서면 즉시" 다.

그래서 **미리 세워 둔다.** 필요해진 시점에 프록시를 새로 도입하고 소비자를
옮기는 것보다, 세워 두고 소비자를 하나씩 옮기는 편이 낫다.

#### ★★ 도입 형태 — "앞에" 가 아니라 "옆에"

**지금 이 프록시에는 소비자가 없다.** 기존 `postgresql-headless` 와 나란히 서고
접속 문자열 14곳은 그대로다. 이유는 셋이다:

1. 앞단에 끼워 넣으면 **돌고 있는 것에 SPOF 만 추가**된다. HA 를 세우려다 HA
   문제를 하나 더 만드는 구조다
2. CNPG 가 오면 백엔드가 `-rw`/`-ro` 로 바뀐다. 지금 소비자를 옮기면 **두 번**
   고친다
3. 규칙(sharding·encrypt·mask)을 하나도 걸지 않은 **패스스루**라, 지금 옮겨도
   얻는 것이 없다. 규칙은 DistSQL 로 런타임에 추가할 수 있다(재기동 불필요)

#### 구성

| 항목 | 값 | 근거 |
|---|---|---|
| 이미지 | `apache/shardingsphere-proxy:5.5.3` | 최신 릴리스 |
| 프런트엔드 프로토콜 | **PostgreSQL** | 인스턴스당 하나뿐이다. 접속 지점이 PostgreSQL 14곳 · MariaDB 1곳이라 이쪽을 택했다 |
| 포트 | 3307 | `proxy-default-port` |
| 모드 | **Standalone** (JDBC 저장소) | Cluster 모드는 레지스트리를 요구한다. 이 랩의 ZooKeeper 는 HBase 전용이고, 레플리카가 1이라 이점도 없다. ★ **레플리카를 늘리려면 반드시 Cluster 로 바꿀 것** — Standalone 은 인스턴스마다 설정이 갈린다 |
| 힙 | `-Xmx768m` (limit 1Gi) | 도입 시점 노드 메모리 요청이 95% 였다 |
| 비밀번호 | 자리표시자 + initContainer 치환 | ShardingSphere 도 **환경변수 오버라이드가 없다**(OpenMeter 와 같은 제약, Gotcha 26). ranger-usersync 와 같은 패턴이다 |

★ 프록시 사용자(`proxyadmin`)의 자격은 뒤쪽 PostgreSQL 자격과 **별개**다 —
프록시 자격이 새도 DB 자격은 지켜진다(§8-44 와 같은 이유).

★ initContainer 는 **fail-closed** 다. 치환되지 않은 자리표시자가 남으면 기동
하지 않는다 — 남은 채로 뜨면 프록시가 틀린 비밀번호로 붙어 조용히 실패한다.

#### ★★ 막힌 지점 — Gotcha 9 를 내가 다시 밟았다

파드가 `1/1 Running` 이고 백엔드 HikariPool 이 커넥션 10개를 정상 확보했는데도
클라이언트 접속이 즉시 끊겼다:

```
psql: error: connection to server at "shardingsphere" ... failed:
      server closed the connection unexpectedly
```

ztunnel 로그가 답을 준다:

```
connection closed due to policy rejection: allow policies exist, but none allowed
```

원인은 프록시가 아니다. ShardingSphere 에 `app.kubernetes.io/component: database`
라벨을 주었고, 그래서 **`allow-database-access` 가 이 워크로드를 선택**하는데
그 정책의 규칙에는 5432·3306·27017·6379 만 있고 **3307 이 없다.**
ALLOW 정책이 워크로드를 선택하면 **매칭되지 않은 전부가 거부된다**(Gotcha 9).

★ 알아채기 어려운 이유가 겹친다 — 파드는 Ready 이고, 백엔드 풀은 정상이며,
오류 메시지가 "서버가 연결을 닫았다" 라 **프록시 자체의 문제로 읽힌다.**

해소는 3307 규칙 추가다. 원칙은 **"PostgreSQL 에 직접 닿을 수 있는 것은
프록시를 통해서도 닿을 수 있다"** 이고, 그래서 5432 와 **같은 principal 집합**을
쓴다. ★ 한쪽만 고치면 프록시로 옮긴 소비자가 조용히 끊긴다.

#### 검증 — 파드 상태가 아니라 기능으로

```
=== 1) 스토리지 유닛 ===
 name          | type       | host                | port | db
 oneinchmarket | PostgreSQL | postgresql-headless | 5432 | oneinchmarket

=== 2) 프록시를 통한 실제 질의 ===
 current_database | version
 oneinchmarket    | PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2) ...
```

프록시(3307)를 거쳐 실제 PostgreSQL 18.6 에 질의가 도달했다. `1/1 Running` 만
보고 끝냈다면 위의 정책 결함을 놓쳤을 것이다.

#### 남는 것

- **소비자 이설이 0곳이다.** 마스킹·암호화 요건이 서면 그때 건별로 옮긴다.
  옮길 때는 `allow-database-access` 의 3307 목록도 함께 볼 것
- **MariaDB 는 덮지 못한다.** 인스턴스당 프로토콜이 하나라 별도 인스턴스가
  필요하고, 지금은 메모리가 없다(요청 96%)
- **Standalone 이라 레플리카가 1로 고정**이다. 늘리려면 Cluster 모드 + 레지스트리
- **CNPG 가 오면 백엔드 URL 을 `-rw`/`-ro` 로 바꿔야 한다** — 이 프록시가 그
  변경을 소비자로부터 가려 주는 것이 원래 노린 이득이다
- **MariaDB Operator 는 여전히 §13-2 의 빈칸이다**

### 8-76. ProxySQL 4.0.11 도입 — 공식 이미지가 없어 직접 굽는다 (2026-09-07)

§8-75 의 ShardingSphere 와 **상보 관계**다. 인스턴스당 프런트엔드 프로토콜이
하나이므로:

| 프록시 | 와이어 | 포트 | 백엔드 |
|---|---|---|---|
| ShardingSphere-Proxy 5.5.3 | PostgreSQL | 3307 | `postgresql-headless` |
| **ProxySQL 4.0.11** | **MySQL/MariaDB** | **6033** | `mariadb-headless` |

둘 다 **소비자가 없다.** 기존 서비스와 나란히 서고 접속 문자열은 그대로다.

#### 왜 4.0.11 이고 왜 자체 빌드인가

**ProxySQL 은 패키지와 컨테이너 이미지의 릴리스 주기가 다르다.** 실측:

```
GitHub 최신 릴리스              : v4.0.11
Docker Hub proxysql/proxysql   : 3.0.11  (전체 300개 태그에 4.x 없음)
ghcr.io/sysown/proxysql        : 없음
v4.0.11 릴리스 자산            : rpm · deb · tar.gz + 서명/해시. Docker 언급 0건
```

4.x 는 **GenAI 플러그인 · MCP 엔드포인트 · RAG/벡터 도구**가 들어간 기능 계열
이고 3.x 가 안정 계열로 보인다 — 4.0.11 바이너리 스스로
`Latest ProxySQL version available: 3.0.11-...` 을 보고한다.

★ 나는 처음에 "메모리 때문에 3.0.11 을 쓰자" 고 했다. **틀렸다.** 실측하니
유휴 RSS 가 3.0.11 **18.5 MB**, 4.0.11 **18.4 MB** 로 차이가 없다. C++ 바이너리라
JVM 과 성격이 다르다(같은 랩의 ShardingSphere 는 힙만 768 MB 다).
메모리는 버전 선택의 근거가 되지 못했다.

#### ★★ 체크섬이 없었다면 잘린 아티팩트로 이미지를 구웠다

tarball 을 받으며 `curl --max-time` 을 썼고 **종료 코드를 확인하지 않았다.**
그 결과:

| 시도 | 크기 | sha256 |
|---|---:|---|
| 1차(`--max-time 60`) | 29.7 MB | `5fab5e…` |
| 2차(`--max-time 90`) | 40.5 MB | `ea7e78…` |
| 공식 게시값 | — | `635f0e…` |
| **정상(`--max-time` 제거)** | **95.4 MB** | **`635f0e…` ✓** |

**같은 URL 을 두 번 받아 크기가 다른 파일 두 개가 나왔고 둘 다 게시값과 달랐다.**
그런데 **1차 파일은 `tar` 로 풀렸고 바이너리가 실행까지 됐다** — 앞부분만으로도
동작한 것이다. Gotcha 12 그대로다. Dockerfile 에 `sha256sum -c` 를 넣고
`--max-time` 금지를 주석으로 못박았다.

#### 구성

| 항목 | 값 | 근거 |
|---|---|---|
| 이미지 | `oneinch/proxysql:4.0.11` | `docker/proxysql/Dockerfile` — 릴리스 tarball + sha256 검증 |
| 베이스 | `debian:13.6-slim` | 런타임 의존은 `ldd` 로 확인한 **`libgnutls30` 하나뿐**. 추측으로 넣지 않았다 |
| 사용자 | uid 1000 (비-root) | 이미지에 USER 선언이 없어 기본이 root 다. Dockerfile 에서 만든다 |
| datadir | **emptyDir** | ★★ 아래 참조 |
| 관리 포트 6032 | **Service 미노출** | 런타임 설정을 바꾸는 문이다. cnf 가 `127.0.0.1` 로만 바인딩한다 |
| MCP | **끄지 않고 그대로 둔다**(기본 비활성) | 노출 범위·토큰 보관 미결. 아래 "남는 것" |
| 자원 | request 64Mi / limit 256Mi | 실측 RSS 18.3 MB |

★★ **datadir 을 emptyDir 로 두는 것이 설계다.** ProxySQL 은 설정을 datadir 의
SQLite(`proxysql.db`)에 넣고 **그 파일이 있으면 `.cnf` 를 무시한다.**
`--initial` 없이 재기동하면 옛 설정으로 뜬다. emptyDir 이면 매 기동이 새것이라
ConfigMap 이 항상 권위를 갖는다. **PVC 로 바꾸는 순간 설정 변경이 조용히
무시된다** — 이 레포가 반복해서 겪은 "설정이 반영되지 않는데 오류도 없는"
부류다(Gotcha 26·48).

★ 모니터 계정을 **분리했다.** `mariadb-bootstrap` 이 `'proxysql-monitor'@'%'` 를
`GRANT USAGE` 만으로 만든다 — 헬스체크는 ping 과 연결 성립만 보므로 데이터
접근 권한이 필요 없다. 앱 계정 재사용은 §8-44(Ranger 의 다섯 자격이 전부 같은
값이었던 결함)의 반복이다. Galera 를 세우면 wsrep 상태를 읽어야 하므로 그때
`REPLICATION CLIENT` 를 더한다.

#### 도입 목적 — Galera 대비

§13-2 는 MariaDB Galera 에 대해 **"접속 문자열 변경 없음(아무 노드나 쓰기)"**
이라고 적었다. 접속 문자열 관점에서는 맞지만 **비용이 0 이라는 뜻은 아니다.**
Galera 는 다중 마스터지만 여러 노드에 동시에 쓰면 같은 행에 대해 **커밋 시점에
certification 실패**가 난다. 실무 표준은 **단일 라이터 라우팅**이고, ProxySQL 의
`mysql_galera_hostgroups` 가 그것을 강제한다:

```
writer_hostgroup · backup_writer_hostgroup · reader_hostgroup · offline_hostgroup
max_writers DEFAULT 1     -- 초과 노드는 backup 으로 밀린다
```

`wsrep_local_state`·`wsrep_desync`·`wsrep_reject_queries` 를 감시해 문제 노드를
자동으로 뺀다. **§13-2 가 빠뜨린 비용이 여기서 지불된다.**

#### ★★ 부트스트랩 Job 이 무한 대기하고 있었다 — Gotcha 19 의 다섯 번째

모니터 계정을 만들려고 `mariadb-bootstrap` 을 재실행하자 **끝나지 않았다.**
로그는 `[mariadb-bootstrap] MariaDB 대기` 한 줄에서 멈춘 채였다.

원인은 전용 SA 부재다. ztunnel 로그가 답을 준다:

```
src.workload="mariadb-bootstrap-..." src.identity="spiffe://.../sa/default"
dst.service="mariadb-headless..." dst.hbone_addr=...:3306
error="connection closed due to policy rejection: allow policies exist, but none allowed"
```

★ **증상이 오류가 아니라 대기다.** `until mariadb-admin ping ...` 루프가 영원히
돌아 Job 이 `Running` 인 채로 남는다. hive-schematool(§8-71)은 `PSQLException`
이라도 냈지만 이쪽은 아무것도 내지 않는다 — **더 늦게 드러난다.**

★★ 그리고 이것만이 아니다. `base/bootstrap/` 의 **4개가 `default` SA 로 돈다**:
`mariadb-bootstrap` · `postgres-bootstrap` · `minio-bootstrap` · `ds389-bootstrap`.
앞의 셋은 ztunnel 로그에서 실제로 거부되는 것을 확인했다. 이번에는 작업에 필요한
`mariadb-bootstrap` 만 고쳤다 — 나머지는 §9 로 넘긴다.

#### 검증 — 파드 상태가 아니라 기능으로

```
=== ProxySQL(6033) 경유 ===
 v                        backend_host
 12.3.3-MariaDB-ubu2404   mariadb-0

=== 대조군: MariaDB 직접(3306) ===
 v                        backend_host
 12.3.3-MariaDB-ubu2404   mariadb-0
```

프록시를 거친 결과가 직접 접속과 동일하다. 그리고 Job 이 `Completed` 로 끝나며
`mysqld is alive` · `cmmn` DB 를 보고했다 — 위의 무한 대기가 해소된 증거다.

★ 인가 정책은 ShardingSphere 에서 배운 것을 **미리** 적용했다 —
`component: database` 라벨 때문에 `allow-database-access` 가 ProxySQL 을
선택하므로 **6033 규칙을 처음부터 넣었다**(Gotcha 9). §8-75 에서는 이걸 빠뜨려
한 번 막혔다.

#### 남는 것

- **소비자 이설 0곳.** Galera 가 서는 시점에 `cmmn-api` 를 옮긴다
- **MCP 는 꺼져 있다.** 켜기 전에 정해야 할 것 셋: ① 엔드포인트가 무엇을
  노출하는지(processlist·쿼리 통계가 AI 에 나간다) ② 베어러 토큰을 어디 둘지
  — 이 레포의 시크릿 관리가 미작동이다 ③ 3.x/4.x 트랙 관계
- **`docker/proxysql` 은 유지보수 짐이다.** Ranger 플러그인 3종과 같은 성격이라
  업스트림이 4.x 컨테이너를 내면 지운다. 자체 빌드 이미지가 이제 **9종**이다
- **`default` SA 부트스트랩 Job 3개가 남았다** — `postgres-bootstrap` ·
  `minio-bootstrap` · `ds389-bootstrap`
- **`cmmn` 과 `cmmn-api` 두 계정이 공존한다.** `mariadb-bootstrap` 은 `cmmn` 을
  만들고 앱(`cmmn-api-statefulset`)은 `DB_USERNAME=cmmn-api` 로 붙는다.
  후자는 MariaDB 이미지 엔트리포인트가 만든 것이고 **비밀번호 출처가 다르다**
  (`mariadb-secret/app-password` vs `cmmn-api-secret/db-password`).
  이번 검증은 `cmmn-api` 로 통과했으므로 앱 경로는 살아 있으나, **부트스트랩이
  만드는 계정과 앱이 쓰는 계정이 다른 것 자체가 정리 대상이다**

### 8-77. WSL2 `networkingMode=mirrored` 를 시도했고 되돌렸다 (2026-09-07)

윈도우에서 컴포넌트에 **도메인으로** 접속하려던 작업이다. 결론부터 —
**mirrored 는 이 환경에서 클러스터를 통째로 무너뜨린다. 쓰지 말 것.**

#### 왜 시도했나 — port-forward 가 구조적으로 부족하다

`local/ACCESS.md` 는 port-forward 40여 개를 전제한다. 이 세션에서 그 방식이
두 번 물렸다:

- **Gotcha 12** — 파드를 재생성하면 port-forward 가 죽고 **14시간 조용히**
  끊겨 있었다. 오류가 나지 않는다
- **§8-74** — Dependency-Track 의 `API_BASE_URL` 이 `localhost:8081` 인데
  `ACCESS.md` 는 8087 을 안내하고 있었다. **앱이 자기 외부 주소를 알아야 하는데
  port-forward 포트는 그 주소가 될 수 없다.** Apicurio UI 도 같은 함정이었다

Keycloak redirect URI · OIDC · 쿠키 도메인 · CORS 가 전부 같은 문제다.

#### 막고 있던 것 두 가지 — 클러스터 문제가 아니었다

Gateway 는 이미 서 있다(`PROGRAMMED=True`, NodePort **443→30727 · 80→31938**).
그런데 Windows 에서 닿지 않았고, 원인은 둘이었다:

**① NodePort 는 리스닝 소켓을 만들지 않는다.** kube-proxy 의 iptables DNAT 다
(`KubeProxyReplacement: False`). `ss -lntp` 에 아무것도 안 나온다. WSL2 의
`localhostForwarding` 은 **실제 소켓만** 잡으므로 이 포트를 보지 못한다.

**② Hyper-V 방화벽이 인바운드 TCP 를 막는다.** 어댑터 이름이
`vEthernet (WSL (Hyper-V firewall))` 이고 실측이 이렇다:

```
Test-NetConnection 172.25.102.72 -Port 31938
  PingSucceeded    = True      ← 라우팅은 된다
  TcpTestSucceeded = False     ← TCP 만 막힌다
```

WSL 안에서는 `127.0.0.1:31938` 도 `172.25.102.72:31938` 도 **404 를 응답한다**
— 게이트웨이는 멀쩡했다.

#### ★★ 시도 결과 — 노드 IP 자동 감지가 무너뜨린다

`.wslconfig` 에 `networkingMode=mirrored`(+`dnsTunneling=false`·`autoProxy=false`)
를 넣고 `wsl --shutdown` 했다. 사전에 알고 들어간 위험이 그대로 일어났다:

```
전:  hostname -I → 172.25.102.72
후:  hostname -I → 10.77.0.190  192.168.1.222  172.17.0.1  (+IPv6 4개)
```

mirrored 는 **Windows 의 Up 어댑터를 전부 미러링한다.** 이 호스트에는 6개가
있었다 — Wi-Fi · 네트워크 브리지 · `vEthernet (L0-WAN)` · `(L0-LAN)` ·
`(Default Switch)` · `(WSL)`. 그중 **L0-LAN(Hyper-V 랩)의 `10.77.0.190`** 이
첫 주소가 됐고, k3s 는 `--node-ip` 가 **미설정**이라 그것을 노드 IP 로 골랐다.

그 결과:

```
kubectl logs -n kube-system ds/cilium
  Error from server: Get "https://10.77.0.190:10250/containerLogs/..."
  proxy error from 127.0.0.1:6443 while dialing 10.77.0.190:10250,
  code 502: 502 Bad Gateway
```

**apiserver 가 kubelet 에 닿지 못한다.** 연쇄가 즉시 따라왔다:

| 계층 | 상태 |
|---|---|
| Cilium (CNI) | `0/1`, 재시작 64~65회 |
| CoreDNS | `Completed` — 죽어 있다 |
| Kyverno webhook | `no endpoints available for service "kyverno-svc"` → **파드 생성 자체가 거부된다** |
| 워크로드 | OpenReplay 8종 · DefectDojo · kube-state-metrics 등 CrashLoopBackOff |
| ingress 게이트웨이 | 기동 후 37초 만에 `exitCode 0` 로 종료 반복 |

★ 게이트웨이 로그가 특히 헷갈린다 — 인증서를 정상으로 받고
`Envoy aborted normally` 로 **깨끗하게** 끝난다. 크래시가 아니라 종료 신호를
받는 것이라 게이트웨이 자체 문제로 읽힌다. 진짜 원인은 두 계층 아래에 있었다.

#### 되돌리기

`.wslconfig` 에서 세 줄을 지우고 `wsl --shutdown` 하면 끝이다. 즉시
`172.25.102.72` 로 복귀했고 Cilium·CoreDNS 가 `1/1` 로 돌아왔다.

복구 검증(약 10분 소요):

| 항목 | 결과 |
|---|---|
| 노드 | `Ready` · `v1.36.4+k3s1` · IP `172.25.102.72` |
| Cilium · CoreDNS | `1/1 Running` |
| ztunnel 정책 | **6건** — 시작 시점과 동일 |
| HBase 인가 | `Switched policy engine to [7]` |
| Hive 인가 | `oimtest` → `No rows selected` · `oimother` → `Permission denied ... [SELECT] on default/rangerhive/*` |
| 프록시 2종 | ShardingSphere · ProxySQL 둘 다 `1/1` |

★ Vault 는 재시작하면 봉인된다 — 설계다(`local/vault-init.sh unseal`).

#### 배운 것

**① mirrored 를 쓰려면 노드 IP 를 먼저 고정해야 한다.** `--node-ip` 와
`--tls-san` 이 없으면 k3s 가 6개 어댑터 중 하나를 자동으로 고르고, 그 선택이
Hyper-V 랩 주소일 수 있다. **그런데 mirrored 후의 주소는 바꿔 봐야 알 수 있어
닭과 달걀이다** — 굳이 한다면 두 단계로 나눠야 한다.

**② 이 호스트에서는 mirrored 의 이점이 뒤집힌다.** 원래 NAT 의 단점이
"WSL IP 가 재시작마다 바뀐다" 였는데, mirrored 로 가면 노드 IP 가 **Wi-Fi DHCP
주소나 Hyper-V 랩 주소**에 묶인다. 랩톱이라 네트워크를 옮기면 또 바뀐다.
**더 불안정해진다.**

**③ Hyper-V L0 랩이 돌고 있으면 어댑터가 2개 더 늘어난다**(`L0-WAN`·`L0-LAN`).
`L0-OPNsense`·`L0-Target` 이 Running 이었고 그 주소가 선택됐다.

#### 그래서 남는 경로 — B

도메인 접속은 여전히 필요하고, 남은 방법은 **NAT 유지 + Hyper-V 방화벽 규칙**
이다. 변경 범위가 작고 클러스터 네트워킹을 건드리지 않는다:

```
1. Hyper-V 방화벽 인바운드 허용 (30727 · 31938 또는 전체)
2. Windows hosts 파일 → WSL IP  (재시작마다 바뀌므로 keepalive.ps1 이 갱신)
3. HTTPRoute 40여 개 생성 — access-gen.py 의 매핑 116개를 재사용
4. netsh portproxy 443→30727 (URL 에서 포트를 없애려면)
5. cert-manager 자체 서명 CA 를 Windows 가 신뢰하도록
```

★ 3번이 핵심이다. `access-gen.py` 를 **단일 원천**으로 삼아 `ACCESS.md` 와
HTTPRoute 를 함께 뽑으면 §8-74 처럼 **문서와 실제가 어긋나는 일**을 구조적으로
막는다. 지금은 호스트가 붙은 HTTPRoute 가 `api.oneinchmarket.local` 하나뿐이다.


### 8-78. 메시가 절반만 서 있었다 — ztunnel 은 파드를 스스로 되찾지 않는다 (2026-09-07)

§8-77 의 mirrored 롤백 뒤 "클러스터가 아직 불안정하다" 로 보였고, 실제로는
**서로 다른 두 결함**이 겹쳐 있었다. 둘 다 증상이 원인과 멀다.

#### ① 배포판이 매 명령마다 재부팅되고 있었다 — Gotcha 6 의 재발

증상은 "k3s 가 계속 재시작한다" 였다. 그런데 systemd 는 이렇게 말한다:

```
NRestarts=0
ActiveEnterTimestamp=Mon 2026-09-07 04:31:02 KST   ← 방금
```

**재시작이 0회인데 방금 기동했다** — 서비스가 재시작한 것이 아니라 **호스트가
새로 부팅된 것**이다. 결정적 단서는 PID 다: 연속된 확인에서 `k3s[335]` →
`k3s[326]` 으로 **번호가 줄었다.** 300번대는 부팅 직후에만 나오는 번호다.

원인은 `local/keepalive.ps1` 이 떠 있지 않은 것이었다(Gotcha 6). 붙은 프로세스가
없으면 WSL 이 배포판을 종료하므로, **`wsl.exe -- <명령>` 하나하나가 콜드 부팅**이
된다. 그래서 진단하려고 명령을 넣을 때마다 클러스터가 처음부터 다시 떴고,
"kubelet 이 10250 을 열지 않는다"·"ztunnel 이 워크로드를 2개만 들고 있다" 같은
관측이 전부 **"방금 떴기 때문"** 이었다. ★ 이 상태에서는 진단 자체가 원인을
재생산한다 — **관측값이 이상하면 관측 행위부터 의심할 것**(Gotcha 25 와 같은 부류).

판정:

```bash
uptime -p                                       # 몇 분이면 의심
systemctl show k3s -p NRestarts -p ActiveEnterTimestamp
sudo journalctl -u k3s -n1 -o json | jq ._PID   # 300번대면 부팅 직후
```

처방은 `powershell -File local\keepalive.ps1` 한 줄이고, 그 뒤로 배포판이 계속
살아 있으면 kubelet(10250)·Kyverno 웹훅·Cilium 이 **10분 안에 스스로** 회복했다.

#### ② ztunnel 을 재시작하면 기존 파드가 메시에서 빠진다

①을 고친 뒤에도 ProxySQL 접속이 되지 않았다. 그런데 증상이 이상했다 —

```
1) TCP proxysql:6033       → TCP OK
3) 직접 MariaDB (대조군)   → ERROR 2013: Lost connection ... reading initial communication packet
4) ProxySQL 경유            → ERROR 2013: (같음)
```

**대조군이 같이 실패한다.** ProxySQL 문제가 아니라는 뜻이다. 그리고 TCP 는
열리는데 프로토콜 핸드셰이크에서 끊긴다 — ztunnel 이 연결을 받아 주고 나서
목적지로 잇지 못하는 모양이다. ztunnel 로그가 정확히 그렇게 말한다:

```
src.identity="spiffe://.../sa/cmmn-api"  dst.addr=10.0.0.101:15008
dst.hbone_addr=10.0.0.101:3306  direction="outbound"
error="io error: Connection refused (os error 111)"
```

★ **정책 거부가 아니다**(그러면 `policy rejection: allow policies exist, but none
allowed` 가 나온다, §8-76). 신원도 정상이다. 거부당한 것은 **목적지 파드의
HBONE 15008** 이다 — 즉 그 파드에는 ztunnel 의 inbound 프록시가 서 있지 않다.

앰비언트에서 파드를 메시에 넣는 것은 ztunnel 이 아니라 **istio-cni** 다. CNI 가
파드 netns 를 ztunnel 에 넘겨야(`sending pod add to ztunnel`) 비로소 프록시가
선다. 그런데 istio-cni 는 **CNI 이벤트가 있을 때만** 그 일을 한다 — 즉 새로
뜨는 파드만 등록한다. ztunnel 이 재시작하면 **이미 떠 있던 파드는 아무도 다시
넣어 주지 않는다.**

실측이 그대로다:

```
ztunnel 이 프록시를 시작한 파드 수: 49     ← 실제 파드는 138
mariadb-0 등록 여부: (없음)
```

★★ **`istioctl ztunnel-config workload` 는 116 을 보고했다.** 그것은 xDS 로 받은
**워크로드 목록**이지 프록시가 선 파드가 아니다. 두 수가 다르다는 것이 이
결함의 전부이며, 그래서 "ztunnel 이 정상 동기화됐다" 로 오판하기 쉽다.
**판정은 xDS 건수가 아니라 로그의 `pod received, starting proxy` 건수로 한다.**

처방:

```bash
kubectl rollout restart -n istio-system ds/istio-cni-node
# 기동 시 앰비언트 파드를 전부 다시 열거해 ztunnel 로 보낸다
```

결과 **49 → 138**, `mariadb-0`·`proxysql`·`postgresql-0`·`shardingsphere` 가 모두
등록되고 접속이 즉시 통했다.

> ★ 이것이 §8-73 의 관찰("Istio 업그레이드는 ztunnel 재시작으로 장기 TCP 연결을
> 끊는다")보다 한 단계 나쁜 이야기다. 그때는 **연결이 끊겼을 뿐 다시 붙었다.**
> 여기서는 **파드가 메시 밖으로 나가 다시 들어오지 않았다.** ztunnel 을
> 재시작할 일이 있으면 **istio-cni 도 함께 재시작할 것.**

#### 이번 소동에서 확인된 접속 정보

`local/ACCESS.md` §2-7 에 적은 두 프록시의 값이 실제로 동작한다:

| 프록시 | 확인 방법 | 결과 |
|---|---|---|
| ProxySQL (6033) | `cmmn-api` 로 `SELECT VERSION(), @@hostname` | `12.3.3-MariaDB-ubu2404` · `mariadb-0` — 직접 접속과 **같은 백엔드** |
| ShardingSphere (3307) | `proxyadmin` 으로 논리 DB `oim` | `oneinchmarket` · PostgreSQL 18.6, `SHOW STORAGE UNITS` 가 `postgresql-headless:5432` |

## 9. 뒤로 미룬 일 — 전부 끝난 뒤에 한다

> **이 절은 "지금 하지 않기로 결정한 것" 의 목록이다.** §8 의 각 절 끝에
> 달린 "남은 것" 이 여기로 모인다. 하나씩 처리하다 흐름이 끊기는 것보다
> 본 줄기(계량 → 가격 → 인보이스)를 먼저 잇는 편이 낫다고 판단했다.
> **잊어서 미룬 것이 아니라 순서를 정해 미룬 것이다** — 이 구분이 사라지면
> 목록은 그냥 빚이 된다.

### 9-1. 경보 (§8-63 에서 미룸)

| 할 일 | 왜 미뤘나 | 지금 상태 |
|---|---|---|
| **사람에게 밀어내는 수신처** — Slack·메일 | webhook URL·SMTP 가 이 랩에 없다. 없는 것을 있는 척하면 경보가 조용히 사라진다(Gotcha 33) | Elasticsearch `alerts` 인덱스에는 남는다. Alertmanager 의 `receivers:` 에 한 항목 더하면 되도록 자리를 비워 뒀다 |
| **규칙 확장** — 디스크·메모리·Kafka consumer lag | 지금 5개는 **실제로 겪은 실패**에서만 골랐다. 겪지 않은 실패에 규칙을 붙이면 임계값이 추측이 되고, 틀린 임계값은 경보를 무시하게 만든다 | `prometheus-rules.yaml` 에 그룹을 더하면 된다 |
| **elasticsearch exporter** | Gotcha 32 가 지목한 셋 중 유일하게 아직 없는 것. ES 자체의 지표(힙·샤드·색인 지연)가 Prometheus 에 없다 | 미착수 |

### 9-2. 과금 — 계량은 끝났고 **가격이 없다**

이것이 인보이스 발행 전 마지막 조각이다. §8-58~§8-63 이 만든 것은
**"얼마나 썼나"** 까지다. **"얼마인가"** 는 비어 있다.

- 요금제(plan)·가격(price)·구독(subscription) 정의가 없다
- OpenMeter 의 billing 쪽 CronJob 3종(`billing-advance-invoices`·
  `billing-collect-invoices`·`subscription-sync`)은 **돌고는 있으나
  대상이 없다** — §8-63 에서 경보를 띄운 그 Job 들이다
- 계량 이벤트와 달리 가격은 **소급 적용이 가능하다**(청구 이력은 불가능,
  Gotcha 15). 그래서 계량을 먼저 끝내고 가격을 뒤로 미룰 수 있었다

### 9-3. 그 밖에 열려 있는 것

- **로그 회전 내성 미검증** — §8-57 의 시험 방법이 틀렸다(Gotcha 25).
  올바른 방법은 kubelet 의 실제 회전을 유도하는 것이고 아직 하지 않았다
- **Kyverno 미충족** — `require-health-probes` 약 212건,
  `disallow-privilege-escalation` 178건(prod 는 Enforce 다)
- **`default` SA 로 도는 부트스트랩 Job 3건** — `postgres-bootstrap` · `minio-bootstrap` · `ds389-bootstrap`. 셋 다 ztunnel 이 거부하며, 증상이 **오류가 아니라 무한 대기**일 수 있다(§8-76). `mariadb-bootstrap` 은 §8-76 에서 고쳤다
- **`default` SA 로 도는 워크로드** — `nginx`·`ds389-bootstrap`·
  `efs-cleaner`·`databases-migrate`(매니페스트는 고쳤고 파드가 낡은
  Complete 다). ambient 에서 SA 는 곧 신원이다(Gotcha 10)

### 9-4. 머지 관문 (ADR-068) — `local` → `v2`

ADR-068 이 **"7단계까지 모두 끝난 뒤 `v2` 로 합치고 `local` 은 소멸한다"** 로
정해 두었다. 워크로드 기준으로는 7·8단계가 이미 다 떠 있으나, **머지 선행
조건이 매니페스트에 반영돼 있지 않다.**

| 선행 조건 | 현재 | 왜 먼저인가 |
|---|---|---|
| prod `targetRevision` 을 태그로 고정 | ❌ dev·prod **둘 다 `v2`** | 지금 머지하면 dev 만이 아니라 **prod 도 같이 맞는다.** `.gitlab-ci.yml` 의 prod `when: manual` 게이트가 `automated{selfHeal}` 로 **무력**하다 |
| dev `automated` 일시 해제 | ❌ dev·prod 둘 다 `prune: true`·`selfHeal: true` | 머지 시 dev 오버레이가 98 → 234 오브젝트, 신규 워크로드 26종이 한 번에 뜬다 |
| wave 순 분할 머지 | 미착수 | 오퍼레이터(ECK·Kyverno·cert-manager·Tetragon)가 로컬에서만 검증됐다. 첫 단계가 관문이다 |

> `local` 은 `v2` 대비 **0 뒤처짐**이라 fast-forward 가 유지된다. 누가 `v2` 에
> 커밋하면 이 성질이 깨지므로 그때는 즉시 rebase 할 것.

### 9-6. HA — 고치기 전까지 건드리면 안 되는 것

- **Knox 가 아무것도 프록시하지 않는다**(§8-65). 이미지 기본 토폴로지로 돌아
  `localhost:50070`(Hortonworks 데모)를 가리키고, 데모 LDAP 이 안 떠 모든
  요청이 401 이다. `tcpSocket` probe 라 `1/1 Running` 으로 보인다.
  토폴로지 ConfigMap + 인증 원천(Keycloak OIDC 권장) + probe 교체가 필요하다
- **오퍼레이터 7종이 메모리 requests 없이 돈다**(§18-3) — cert-manager 3종·
  cilium-operator·local-path-provisioner·trivy-operator·policy-reporter.
  **BestEffort QoS 라 메모리 압박 시 가장 먼저 축출된다.** provisioner 가
  빠지면 새 PVC 가 묶이지 않고 cert-manager 가 빠지면 인증서 갱신이 멈춘다.
  HA 와 무관하게 고쳐야 한다
- ~~prod 의 DB 3종 `replicas`~~ — **지혈 완료**(2026-09-05). `replicas-prod.yaml` 에서 postgresql 2→1 · mariadb 2→1 · mongodb 3→1 로 되돌리고 사유를 파일 머리말에 박았다. **제대로 된 조치는 아직이다** — DB 안에서 복제를 구성해야 하며 방법·비용·순서는 §13 에 있다
- **백업이 전무하다**(ADR-018 `Open`). §11-0 이 디스크 장애를 범위 밖으로 두어 **MinIO 로 충분하다** — 호스트 밖 반출이 필요 없어 사실상 공짜다. 막는 것은 **논리 손상**(실수·결함)이고 복제로는 막지 못한다. 순서상 복제보다 먼저 할 것(§13-5)
- **ADR-015(스토리지)를 닫아야 한다.** `Open` 인 채로는 HA 논의가 전부 공중에 뜬다 —
  PVC 27개가 전부 RWO local-path 라 노드를 늘려도 상태 있는 워크로드는 묶여 있다
- 전체 HA 스택은 이 호스트에서 **56.6 GiB 가 필요하고 가용은 47.6** 이다(§11-4)
- **ADR-015 의 실제 선택지는 ⓒ(Longhorn/OpenEBS) 하나다**(§11-2-b). Hyper-V 공유 VHDX 는 부착이 거부된다. 판단 기준은 "메모리 3.5 GiB + 쓰기 증폭을 **이동성**과 바꿀 것인가" 이고, **DB 는 §13 의 복제로 더 싸게 해결되므로** Longhorn 이 필요한 것은 Prometheus·Loki·Jenkins·GitLab 같은 비-DB PVC 다
- §11-0 이 디스크·호스트·전원 장애를 **범위 밖**으로 정했다(2026-09-05). 되돌리려면 물리 디스크를 한 장 더 꽂는 것이 유일한 길이다

### 9-5. 문서·결정 기록의 미정리

- **ADR 번호가 충돌한다.** `ADR-071`·`ADR-072` 가 각각 **두 번** 쓰였다 —
  2026-09-05 에 새로 추가하면서 파일 앞부분만 보고 번호를 매겼다. 참조가
  양쪽으로 갈려 있어(`ADR-072` 19건 중 계량 계열은 새 것, 나머지는 옛 것)
  기계적으로 못 바꾼다. **참조를 하나씩 판별해 새 쪽을 077·078 로 옮기는
  방향**이 맞아 보인다
- **Alertmanager 결정에 ADR 이 없다.** "빈 receiver 를 두지 않고 Logstash→ES 로
  받는다"(§8-63)는 되돌리기 어려운 선택이다 — 경보 이력이 그 인덱스에 쌓인다
- **`rotate-elasticsearch` 를 어떻게 할 것인가**(§8-64). ECK 가 `elastic` 사용자의
  소유자라 이 Job 의 회전은 유지되지 않는다. "ECK 관리 사용자를 회전할 것인가,
  전용 사용자를 따로 둘 것인가" 를 정해야 한다. 지금은 실행돼도 실패해 피해가
  없으나, **고쳐서 동작하게 만드는 순간 ES 인증이 깨진다**

### 9-7. SBOM 연동 — **한 덩어리로 나중에** (§8-74 에서 미룸)

Dependency-Track 은 5.1.0 으로 새로 섰지만(§8-74) **파이프라인에 연결되어
있지 않다.** CI·스크립트 어디에도 SBOM 을 올리는 경로가 없고, 그래서
`PROJECT 0 · COMPONENT 0 · BOM 0` 이다. 버전이 무엇이든 지금은 빈 껍데기다.

**조각내지 않고 한 번에 하기로 했다.** 아래가 서로 물려 있어서, 절반만 해 두면
나머지를 붙일 때 앞의 절반을 다시 봐야 하기 때문이다:

| 조각 | 내용 |
|---|---|
| **생성** | `.gitlab-ci.yml` 의 Trivy 3잡이 CycloneDX SBOM 을 만들게 한다(`trivy image --format cyclonedx`). 지금은 취약점 리포트만 낸다 |
| **업로드** | `POST /api/v1/bom` (프로젝트 이름·버전을 태그로) |
| **자격** | DT API 키를 발급해 CI 변수로 넣는다. 이 레포의 시크릿 관리가 미작동이라(CLAUDE.md) 그 자리에 무엇을 둘지가 함께 정해져야 한다 |
| **경로** | CI 러너 -> `dependency-track-api:8080` NetworkPolicy. ambient 라면 AuthorizationPolicy 도(Gotcha 9·10 — 전용 SA 필요) |
| **계약** | 프로젝트 이름 규약. SBOM 의 프로젝트 키가 흔들리면 **소급 알림(SEC-505)이 깨진다** — 이 컴포넌트의 존재 이유가 그것이다 |

★ 지금 하지 않는 실질적 이유가 하나 더 있다 — **NVD 미러링이 끝나지 않았다.**
첫 기동에서 수십 분~수 시간이 걸린다. 그전에 SBOM 을 올리면 분석 결과가
반쪽이라, 연동이 되는지 안 되는지 판정할 수 없다.

★★ **버전 올리기보다 이쪽이 먼저다.** §8-72 가 이미 보여줬듯 쓰이지 않는
컴포넌트는 버전을 올려도 아무것도 나아지지 않는다 — v5 로 올리는 동안 드러난
결함 둘(§8-74 의 `API_BASE_URL`)도 **아무도 UI 를 쓰지 않아** 그때까지 숨어
있던 것이다.

### 9-8. 윈도우에서 도메인으로 접속하기 (§8-77 에서 미룸)

`ACCESS.md` 의 port-forward 40여 개는 구조적으로 부족하다 — 파드를 재생성하면
조용히 끊기고(Gotcha 12), **앱이 자기 외부 주소를 알아야 하는 경우**를 감당하지
못한다(§8-74 의 `API_BASE_URL`, Apicurio UI). Keycloak redirect URI·OIDC·쿠키
도메인·CORS 가 전부 같은 문제다.

`networkingMode=mirrored` 로 풀려다 클러스터가 무너져 되돌렸다(§8-77).
**남은 경로는 NAT 유지 + Hyper-V 방화벽 규칙이다:**

| 단계 | 내용 |
|---|---|
| 1 | Hyper-V 방화벽 인바운드 허용 — 실측 `PingSucceeded=True` / `TcpTestSucceeded=False` 였다 |
| 2 | Windows hosts 파일 → WSL IP. **재시작마다 바뀌므로** `keepalive.ps1` 이 갱신하게 한다 |
| 3 | **HTTPRoute 40여 개** — 지금은 `api.oneinchmarket.local` 하나뿐이다 |
| 4 | `netsh portproxy` 443→30727 (URL 에서 `:30727` 을 없애려면) |
| 5 | cert-manager 자체 서명 CA 를 Windows 가 신뢰하도록 |

★★ 3번이 핵심이고, **`access-gen.py` 를 단일 원천으로 삼는 것**이 요점이다.
그 파일에 컴포넌트 매핑 116개(서비스명·포트·계정)가 이미 있다. 거기서
`ACCESS.md` 와 HTTPRoute 를 **함께** 뽑으면 §8-74 처럼 문서와 실제가 어긋나는
일을 구조적으로 막는다 — 그때는 매니페스트가 8081, 문서가 8087 이었고 둘 다
반영되지 않아 아무도 몰랐다.

★ NodePort 는 **리스닝 소켓을 만들지 않는다**(kube-proxy iptables DNAT).
`ss -lntp` 로 확인하려 하면 없다고 나오지만 정상이다 — WSL2 의
`localhostForwarding` 이 이 포트를 못 잡는 이유이기도 하다.

## 10. Hyper-V 배포(ADR-051 A안) 재검토 — 2026-09-05 실측

§8-31 에서 H5(Hyper-V 합성 NIC 의 Cilium eBPF)가 해소되어 **기술적 중단 사유는
없다.** 그래서 남은 질문은 "되는가" 가 아니라 **"지금 이 호스트에 들어가는가,
그리고 무엇을 얻는가"** 다. 오늘 실측으로 다시 계산했다.

### 10-1. 예산 — `l0-lab/README.md` 의 산정이 낡았다

그 문서는 워크로드 requests 를 **35.16 GiB** 로 잡는다. 그 뒤 과금 파이프라인
(OpenMeter·ClickHouse·Redis)·경보 체계(kube-state-metrics·Alertmanager)·Falco 가
들어왔다. 오늘 값은 다르다.

```
memory requests   38.9 GiB   (allocatable 41.1 GiB 의 94.6%)
파드              107 / 110
CPU requests      17.6 코어 / 24
```

이 값으로 다시 계산하면:

| 구성 | VM 오버헤드 | 워크로드 | VM 합 | 호스트 잔여 | L0 랩(8.8) 뺀 Windows 몫 |
|---|---:|---:|---:|---:|---:|
| 현행 WSL2 단일 | 2.5 | 38.9 | **44.0**(캡) | 19.4 | **10.6 GiB** ✅ |
| Hyper-V 2노드 | 9.5 | 38.9 | **48.4** | 15.0 | **6.2 GiB** ⚠ |
| Hyper-V 3노드 | 13.5 | 38.9 | **52.4** | 11.0 | **2.2 GiB** ❌ |

> 호스트 물리 63.4 GiB. L0 랩(OPNsense 6.0 + Target 2.8 = 8.8 GiB)은 ADR-031 의
> 경계 통제라 끌 수 없다. Windows 데스크톱 실사용은 현재 여유가 8.6 GiB 다.

**★ 이 표는 §10-1-b 에서 정정되었다.** 오버헤드를 `l0-lab/README.md` 의 추정치(노드당 4.5~4.75 GiB)로 계산했는데 실측은 **2.82 GiB** 다. 실측 기준으로는 **3노드까지 들어간다.** 아래 표는 추정 모델의 결과로 남긴다.
README 가 "메모리는 들어간다" 고 적은 것은 워크로드 35.16 GiB 기준이었고
L0 랩 몫을 빼지 않았다. 지금은 둘 다 달라졌다.

그리고 이 얇음은 **완충 장치가 없는 얇음**이다. H1 이 동적 메모리를 금지하므로
VM 간 슬랙이 넘어가지 않는다. 지금은 41 GiB 한 풀이 어디서 터지든 흡수하고,
그 위에 zram(32G, 현재 DATA 7.1G / COMPR 1.9G)이 한 겹 더 있다.

### 10-1-b. 정정 — 오버헤드를 실측하니 노드가 더 들어간다

§10-1 의 표는 `l0-lab/README.md` 의 오버헤드 모델(2노드 9.5 · 3노드 13.5 GiB,
즉 **노드당 4.5~4.75**)을 그대로 썼다. 그 값을 검증하지 않은 것이 잘못이었다.
실측하면 다르다.

```
DaemonSet 노드당 requests   0.92 GiB   (8종: falco 256Mi · otel-agent 192 ·
                                        filebeat 128 · ztunnel 128 · tetragon 128 ·
                                        istio-cni 100 · cilium 10 · cilium-envoy 0)
시스템 예약(MemTotal-allocatable)  1.9 GiB   (43.0 → 41.1 실측)
                                  --------
노드당 한계비용                    2.82 GiB
```

스케줄링은 **requests 기준**이므로 모델은 이렇게 된다.

```
Σ VM MemTotal(n) = 38.0(노드에 복제되지 않는 워크로드) + n × 2.82
```

`n=1` 에 대입하면 40.8 GiB 이고, 실제 캡 44 GB · requests 38.9 · allocatable 41.1
과 맞는다. 모델이 현실을 재현한다.

| 노드 | Σ VM 메모리 | WSL 종료 후 여유(47.6) |
|:-:|---:|---|
| 1 | 40.8 | ✅ 6.8 |
| 2 | 43.6 | ✅ 4.0 |
| **3** | **46.5** | **✅ 1.1 — 들어간다** |
| 4 | 49.3 | ❌ 1.7 초과 |

> 가용 47.6 GiB = 물리 63.4 − Windows 7.0(`.wslconfig` 주석이 정한 몫) − L0 랩 8.8.

**즉 §10-1 이 "3노드 불가" 라고 적은 것은 틀렸다.** 오버헤드를 추정치로 계산했기
때문이다. 3노드가 들어간다.

#### 더 밀면 어디까지인가

| 지렛대 | 회수 | 결과 |
|---|---:|---|
| `L0-Target` 종료(동적, 현재 2.8) | +2.8 | **4노드**(49.3 ≤ 50.4) |
| requests 를 실사용 기준으로 정정 | +6.0 | **5노드**(46.1 ≤ 50.4) |

두 번째 지렛대는 근거가 있다 — **requests 38.9 GiB 에 비해 실사용은 29.5 GiB**
(allocatable 의 70%)다. 2026-09-03 에 같은 작업으로 6.7 GiB 를 회수한 전례가
있다(`overlays/local/patches/requests-local.yaml`).

#### 그러나 숫자가 말하지 않는 것

`n` 을 늘릴수록 **정적 분할의 대가가 커진다.** H1 이 동적 메모리를 금지하므로
VM 간 슬랙이 넘어가지 않는다. 지금은 41 GiB 한 풀이 어디서 터지든 흡수하고 그
위에 zram(32G · 현재 DATA 7.1G → COMPR 1.9G)이 한 겹 더 있다. 5노드로 쪼개면
같은 총량이 **9~10 GiB 짜리 칸 다섯 개**가 되고, 한 칸이 터질 때 옆 칸의 여유는
도움이 되지 않는다.

`elasticsearch`(2048Mi) · `gitlab`(2304) · `safeline`(2368) · `trino`(2048) 처럼
단일 파드가 2 GiB 를 넘는 것이 여럿이라, 작은 노드에서는 **배치 자체가 실패**할
수 있다. 노드를 키우면 개수가 줄고, 개수를 늘리면 칸이 작아진다.

**따라서 산술적 상한(5)과 운용상 권장(3)은 다르다.** 3노드는 k8s 의 통상 구성
(control-plane 1 + worker 2)이고 여유 1.1 GiB 위에 requests 정정분 6 GiB 를
얹으면 실질 7 GiB 여유가 된다.

### 10-2. Hyper-V 가 **유일하게** 푸는 것 — 파드 상한

```
파드 107 / 110      ← 남은 자리 3
```

k3s 노드 기본 상한이 110 이다. 실제로 §8-64 에서 Falco 를 넣을 때
`0/1 nodes are available: 1 Too many pods` 로 스케줄이 막혔다. **메모리보다
이쪽이 먼저 걸린다.** 노드를 늘리면 상한이 노드 수만큼 늘어난다 — 단일 노드에서는
`--kubelet-arg=max-pods=` 로 올릴 수 있으나 그것은 한 커널에 부담을 몰아넣는 것이다.

이것이 오늘 시점에서 A안의 **가장 실질적인 근거**다. 다른 이득(다중 노드 CNI
데이터패스·HA 페일오버 검증)은 §1 의 "검증 불가" 목록 그대로이고 여전히 유효하나,
지금 당장 막고 있는 것은 파드 수다.

### 10-3. WSL2 쪽 근거는 **오늘 더 강해졌다**

§8-1 의 WSL2 고유 블로커 3건 중 하나가 사라졌다.

| # | 상태 |
|:-:|---|
| W1 마운트 전파 | 유닛 한 장(`mount-rshared.service`)으로 해소. 유지 |
| W2 debugfs | 유닛 한 장(`mount-debugfs.service`)으로 해소. 유지 |
| **W3 Falco 기동 불가** | **소멸(§8-64).** 커널 탓이 아니라 이미지가 2024년판이었다. 0.44.1 에서 modern_ebpf 가 정상 동작한다 |

ADR-051 이 WSL2 를 기각한 근거 중 "런타임 탐지가 안 된다" 는 이제 사실이 아니다.

### 10-4. 이설 비용 — 되돌릴 수 없는 쪽

```
PVC 27개 · 실사용 116 GB
  (PostgreSQL · GitLab · Elasticsearch · MinIO · Kafka · ClickHouse …)
```

전부 `rancher.io/local-path` + `WaitForFirstConsumer` 라 **노드 로컬**이다. 이설은
곧 재생성이고, 여기에는 이제 **과금 원장(ClickHouse·PostgreSQL)** 이 들어 있다.
§8-58 이후의 계량 이력이 여기 있고, 청구는 소급 재해석이 불가능하다(Gotcha 15).
§8-31 이 이설 전에 H5 를 먼저 본 이유가 그대로 유효하며, **그때보다 잃을 것이
늘었다.**

### 10-5. 진짜로 아쉬운 것 — L0 랩이 k3s 를 보호하지 못한다

지금 구조의 가장 큰 충실도 결손은 메모리도 노드 수도 아니다.

```
suricata --syslog--> syslog-ng --> netsh portproxy --> WSL localhostForwarding
  --> kubectl port-forward --> logstash
```

§8-34 가 적어 둔 그대로 **"검증용 경로"** 다. WSL2 의 k3s 는 Hyper-V VM 에서 직접
보이지 않아 Windows 를 두 번 경유한다. 즉 **OPNsense 는 k3s 의 경로에 없다** —
남–북 IDS·경계 통제가 랩 안에서만 성립하고 클러스터를 감싸지 않는다.

k3s 를 `L0-LAN` 위의 Hyper-V VM 으로 옮기면 이것이 **실제 구성**이 된다.
ADR-031 이 문서가 아니라 경로가 된다. 이것이 A안의 가장 정직한 값어치다.

### 10-6. 판단

**가능하다. 다만 지금은 아니다 — 그리고 이유는 기술이 아니라 순서다.**

| | |
|---|---|
| 기술 위험 | 없다. H5 해소(§8-31, 12/12 PASS) |
| 용량 | **3노드까지 가능**(§10-1-b 실측). `L0-Target` 을 끄면 4, requests 를 정정하면 5. 다만 정적 분할이라 **운용상 권장은 3** |
| 지금 얻는 것 | 파드 상한 해소, OPNsense 가 실제 경로에 들어옴, 다중 노드 검증 |
| 지금 잃는 것 | PVC 27개 116 GB 재생성 — **과금 원장 포함**. 되돌릴 수 없다 |

권고하는 순서:

1. **먼저 §9-2(가격·인보이스)를 끝낸다.** 과금 줄기가 미완인 상태에서 원장을
   날리는 것은 가장 나쁜 시점이다
2. **파드 상한은 그 전에 따로 푼다** — `max-pods` 상향이 임시방편으로 충분하다.
   이설을 파드 3자리 때문에 앞당기지 않는다
3. **이설은 §9-4 의 `v2` 머지와 함께 계획한다.** 어차피 클러스터를 다시 세우는
   시점이고, 그때는 PVC 재생성이 비용이 아니라 절차의 일부다
4. 이설한다면 **3노드**다(control-plane 1 + worker 2). 산술 상한은 5지만
   정적 분할이라 칸이 작아질수록 2 GiB 급 파드의 배치가 위태롭다.
   `DEPLOYMENT.md §4-3` 의 3-VM 할당안은 **노드 수는 맞고 크기 산정만**
   이 호스트 기준으로 갱신하면 된다

> **되짚어 둘 것** — ADR-051 의 상태는 여전히 `Proposed` 이고, 이 문서(§1)가
> B안(WSL2)을 택한 근거는 "WSL2 커널이 요건을 충족한다" 였다. 그 근거는 오늘
> 더 강해졌다(W3 소멸). A안으로 가는 이유는 이제 **커널 능력이 아니라
> 토폴로지**다 — 노드 수와 경계 통제.

## 11. 고가용성(HA) 검토 — 2026-09-05

§10 에서 3노드가 들어간다는 것이 나왔으니 다음 질문은 자연스럽다. **HA 도
되는가.** 세 층으로 나눠 봐야 답이 갈린다.

### 11-0. 전제 — 무엇을 막으려는 것인가 (2026-09-05 결정)

**물리 디스크·호스트·전원 장애는 고려 대상에서 제외한다.** 물리 호스트가
한 대인 이상 어떤 구성으로도 막을 수 없고, 막을 수 없는 것을 계속 단서로
달면 실제로 막을 수 있는 것까지 값어치가 없어 보인다.

| | |
|---|---|
| **범위 안** | VM·노드 장애 · 커널 패닉 · 노드 드레인 · 롤링 업그레이드 · 프로세스 사망 · **논리 손상(사람의 실수·소프트웨어 결함)** |
| **범위 밖** | 물리 디스크 장애 · 호스트 장애 · 전원 |

이 전제 아래에서는 아래 결론들이 **올라간다** — etcd 3중화도, DB 복제도,
분산 스토리지의 이동성도 전부 "범위 안" 의 장애를 실제로 막는다. 이 절의
나머지는 그 기준으로 읽을 것.

> 범위 밖을 다시 범위 안으로 들이는 유일한 방법은 **물리 디스크를 한 장 더
> 꽂는 것**이다. 그때 Storage Spaces 미러 또는 Longhorn 복제본을 다른 물리
> 디스크에 둘 수 있게 된다. 지금은 그 선택을 하지 않는다.

### 11-1. 제어평면 HA — 된다

k3s 는 내장 etcd 로 다중 server 를 지원한다(`--cluster-init` + `--server`).
etcd 정족수는 3이고 §10-1-b 의 예산에 3노드가 들어가므로 **구성 자체는 가능**하다.

§11-0 의 전제 아래에서 이것은 **실익이 있다.** 견디는 장애가 곧 범위 안의
장애다 — VM 커널 패닉, 노드 드레인, 롤링 업그레이드, k3s 프로세스 사망.
단일 노드에서는 그 전부가 클러스터 전체 정지인데, 3중화하면 나머지 둘이
정족수를 유지한다.

**남는 실질 비용은 디스크 I/O 다.** etcd 는 fsync 민감한데 같은 NVMe 에
PVC 27개의 I/O 가 함께 얹힌다. 3중화하면 fsync 가 세 배가 된다 — 이것은
디스크 장애와 달리 **범위 안의 문제**이므로 실제로 측정해야 한다.

> **그래도 값어치가 있다.** ADR-051 이 A안의 목적으로 적은 것이 바로
> **"클라우드 재구축 전 선검증"** 이다. HA 를 *가지려고* 가 아니라 HA 설정을
> *시험하려고* 라면 이 구성은 정확히 그 용도에 맞다. 다만 문서에 "HA 달성" 으로
> 적으면 안 된다.

### 11-2. 스토리지 — 여기가 진짜 관문이고, 이미 알려져 있었다

```
PVC 27개 전부   RWO · standard(= local-path 별칭) · WaitForFirstConsumer
분산 스토리지   레포에 없다 (Longhorn·Rook·OpenEBS·NFS 어느 것도)
```

ADR-015 가 이것을 정확히 지목하고 **아직 `Open`** 이다.

> ⓐ k3s `local-path`(무료·빠름, **StatefulSet 이 노드 고정되어 ADR-013 의 HA 가
> 무의미해짐**) ⓑ 프로바이더 CSI 블록 볼륨 ⓒ Longhorn/OpenEBS(복제 계층 추가,
> 상당한 오버헤드)

즉 **노드를 늘려도 상태 있는 워크로드는 여전히 한 노드에 묶인다.** 그 노드가
빠지면 PVC 를 든 파드는 다른 노드에서 뜨지 못한다 —
`WaitForFirstConsumer` + 노드 로컬 경로이기 때문이다.

### 11-2-b. 하이퍼바이저 계층의 스토리지 가상화는 되는가 — 실측 (2026-09-05)

§11-2 는 "레포에 분산 스토리지가 없다" 까지만 보고 **Hyper-V 자신이 무엇을
해줄 수 있는지는 따지지 않았다.** 따져 봤다.

#### ① 공유 VHDX(VHD Set) — 만들어지지만 붙지 않는다

```powershell
New-VHD -Path shared.vhds -Dynamic -SizeBytes 1GB     # → 성공
Add-VMHardDiskDrive -VMName a -Path shared.vhds -SupportPersistentReservations
```
```
장치 'Virtual Hard Disk'을(를) 추가하지 못했습니다.
가상 하드 디스크가 있는 저장소가 가상 하드디스크 공유를 지원하지 않습니다.
```

**`New-VHD` 는 성공하고 파일도 두 개 만든다**(`.vhds` + `.avhdx`). 그런데
부착이 거부된다. 공유 VHDX 의 전제가 **CSV(클러스터 공유 볼륨) 또는 SMB3
스케일아웃 파일 공유**인데 이 호스트의 로컬 NTFS 는 둘 다 아니다.

```
Windows 11 Pro — 실패 클러스터링 기능 없음
```

전형적인 **"성공 출력이 성공을 뜻하지 않는" 경로**다(Gotcha 12 계열).
`.vhds` 파일이 생겼다고 되는 줄 알고 넘어가기 딱 좋다.

#### ② Storage Spaces 미러링 — 디스크가 하나다

```
물리 디스크   NVMe CT2000E100SSD8  1863 GB  ×1     CanPool: False
저장소 풀     Primordial 뿐 (사용자 풀 없음)
풀에 넣을 수 있는 디스크: 0 개   (미러링에는 2개 이상 필요)
```

Windows 11 Pro 에도 Storage Spaces 는 있으나 **미러링하려면 물리 디스크가
둘 이상**이어야 한다. 하나뿐이다.

#### ③ 얻는 것은 이동성이다 — 그리고 §11-0 아래에서 그것으로 충분하다

어떤 스토리지 가상화를 얹어도 복제본은 전부 같은 NVMe 한 장에 떨어지므로
**디스크 내구성은 늘지 않는다.** 다만 §11-0 이 그것을 범위 밖으로 두었다.

범위 안에서 얻는 것은 **이동성**이다 — 노드가 빠지면 PVC 가 다른 노드에서
뜬다. 노드 드레인·VM 크래시·롤링 업그레이드가 전부 여기에 걸리므로,
`local-path` 의 "PVC 가 노드에 못 박힌다" 는 성질은 **범위 안의 실제 제약**이다.

#### ④ 그럼 무엇이 되는가 — 하이퍼바이저가 아니라 k8s 계층이다

| 방법 | 주는 것 | 대가 |
|---|---|---|
| **Longhorn · Rook-Ceph · OpenEBS**(권장) | **이동성 + 노드 장애 내성.** 노드가 빠지면 PVC 가 다른 노드에서 뜬다 | 메모리 ~3.5 GiB(노드당 1.2) · 디스크 2~3배(116 → 232~348 GB, 여유 1352 라 무관) · **같은 NVMe 에 쓰기 증폭** |
| iSCSI 타깃 VM(Linux LIO) + CSI | 공유 블록 | 타깃 VM 이 그 자체로 SPOF. 얻는 것보다 층이 하나 더 는다 |
| 호스트 SMB/NFS + CSI | RWX | 호스트가 SPOF. DB 에는 부적합 |

**쓰기 증폭을 가볍게 보지 말 것.** 이미 같은 NVMe 에 PVC 27개(116 GB)와
etcd 3중화가 얹힌다. 거기에 3배 복제를 더하면 etcd 의 fsync 지연에 직접
영향을 준다 — §11-1 이 지적한 것과 같은 디스크다.

#### 정리

| | 가능한가 |
|---|---|
| Hyper-V 공유 VHDX | ❌ 저장소가 공유를 지원하지 않음(실측) |
| Storage Spaces 미러링 | ❌ 물리 디스크 1개 |
| k8s 내 분산 스토리지(Longhorn 등) | ✅ **이동성은 준다** |
| 디스크 내구성 | — **§11-0 으로 범위 밖** |

즉 **"Hyper-V 로 스토리지 가상화" 는 안 되고, "k8s 안에서 복제" 는 된다.**
**ADR-015 를 닫을 때의 실제 선택지는 ⓒ(Longhorn/OpenEBS) 하나**이고 판단
기준은 "메모리 3.5 GiB + 쓰기 증폭을 **이동성**과 바꿀 것인가" 다.

다만 §13 을 먼저 볼 것 — **DB 복제는 분산 스토리지 없이도 되고**, 영속
컴포넌트의 노드 장애 내성은 그쪽이 더 싸게 해결한다. Longhorn 이 필요해지는
것은 DB 가 아닌 PVC(Prometheus·Loki·Jenkins·GitLab 등)까지 옮기고 싶을 때다.

### 11-3. ★ 그런데 지금 prod 의 HA 설정은 **HA 가 아니라 데이터 분기다**

이것이 이번 검토에서 가장 중요한 발견이다. `overlays/prod/patches/replicas-prod.yaml`
은 이렇게 올린다.

```
postgresql 2 · mariadb 2 · mongodb 3 · keycloak 2 · logstash 2 · nginx 2
```

셋의 모양을 보면 문제가 드러난다.

| 확인 항목 | PostgreSQL | MariaDB | MongoDB |
|---|---|---|---|
| 워크로드 종류 | StatefulSet | StatefulSet | StatefulSet |
| 볼륨 | `volumeClaimTemplates` — **파드마다 별도 PVC** | 〃 | 〃 |
| 서비스 | `clusterIP: None`(헤드리스), 셀렉터 `app.kubernetes.io/name` | 〃 | 〃 |
| 복제 설정 | **없다** (`wal_level`·`primary_conninfo`·repmgr·patroni 전무) | **없다**(Galera·`wsrep` 전무) | **없다**(`replSet` 전무) |

`replicas: 2` 로 올리면:

1. `data-postgresql-1` 이 새로 생기고 **빈 디스크에 `initdb` 가 돈다**
2. 헤드리스 서비스의 DNS 가 **두 파드 IP 를 모두** 반환한다
3. 소비자는 전부 서비스 이름으로 붙는다 — 실측 **34곳이 `postgresql-headless`**,
   특정 파드(`postgresql-0.postgresql-headless`)를 지정한 곳은 **0곳**이다

결과는 가용성이 아니라 **두 개의 서로 다른 데이터베이스에 쓰기가 나뉘는 것**이다.
Keycloak·GitLab·Apicurio·Hive Metastore·OpenMeter 가 요청마다 절반의 데이터만
보게 된다. **오류는 나지 않는다** — 접속은 성공한다.

> `nginx`·`logstash` 는 무상태라 `replicas: 2` 가 정상이다. 문제는 **DB 3종**이다.
> 그리고 `prod` 는 배포된 적이 없어 이 결함이 드러난 적도 없다. 매니페스트에서
> 판정한 것이다.

**따라서 HA 는 "노드를 늘리면 되는 것" 이 아니다.** 지금 상태로 노드를 늘리고
prod 오버레이를 적용하면 **가용성이 오르는 게 아니라 데이터가 갈라진다.**

### 11-4. 진짜 HA 의 비용

셋을 다 갖추려면:

```
3노드 기본                       46.5 GiB   (§10-1-b)
+ 복제본 확대(실측)               6.6       (postgresql·mariadb·mongodb·
                                            logstash·nginx·es·redis)
+ 분산 스토리지(Longhorn 급)      ~3.5       (노드당 관리자+엔진 약 1.2)
                                --------
                                 56.6 GiB   vs 가용 47.6  →  9.0 초과
```

지렛대를 다 써도 빠듯하다: requests 정정(−6.0)과 `L0-Target` 종료(+2.8)를
합치면 필요 50.6 · 가용 50.4 — **여전히 0.2 모자란다.**

그리고 이 계산에는 **DB 복제를 실제로 구성하는 비용이 빠져 있다.** Patroni 나
Galera 는 매니페스트를 새로 쓰는 일이지 replicas 숫자를 올리는 일이 아니다.
스토리지 복제도 디스크를 2~3배 쓴다(116 GB → 232~348 GB, 디스크는 여유 1352 GB 라
문제없다).

### 11-5. 판단

| 층 | 가능한가 | 단서 |
|---|---|---|
| 제어평면 3중화 | ✅ 예산 안에 든다 | §11-0 범위 안의 장애(VM·드레인)를 **실제로 막는다**. 비용은 etcd fsync 3배 |
| 무상태 워크로드 복제 | ✅ 지금도 된다 | nginx·logstash 등 |
| **상태 있는 워크로드** | ⚠ | Longhorn 등으로 **이동성은 얻을 수 있다**(§11-2-b). 그러나 **DB 복제가 미구성**이라 DB 3종은 그래도 단일이다 |
| 하이퍼바이저 스토리지 가상화 | ❌ | 공유 VHDX 부착 거부(§11-2-b). k8s 계층(Longhorn)으로 우회 |
| 전체 HA 스택 | ❌ | 56.6 GiB 필요 · 가용 47.6 |

**결론 — §11-0 의 범위 안에서는 상당 부분 된다.** 제어평면 3중화·무상태
복제·DB 복제·볼륨 이동성이 전부 VM·노드 장애를 실제로 막는다. 막지 못하는
것은 범위 밖(디스크·호스트·전원)과 **논리 손상**이며, 후자는 복제가 아니라
백업의 몫이다(§13-5).

다만 **"HA 처럼 보이게" 가 위험하다** — §11-3 의 결함이 정확히 그 형태다.
복제 기구 없이 `replicas` 만 올리는 것은 가용성이 아니라 손상이다.

순서는 이렇게 본다.

1. **§11-3 을 먼저 고친다.** 노드 수와 무관하게 지금 prod 에 있는 결함이다.
   최소 조치는 DB 3종의 `replicas` 를 1로 되돌리는 것이고, 제대로 된 조치는
   Patroni/Galera/replSet 을 구성하는 것이다. **둘 중 무엇도 아닌 상태로
   두지 말 것**
2. **ADR-015 를 닫는다.** 스토리지가 정해지기 전의 HA 논의는 전부 공중에 뜬다
3. 그 뒤에 노드 수를 늘린다. HA 의 **검증**이 목적이라면 3노드로 충분하고,
   HA 를 **가지는** 것은 이 호스트에서 성립하지 않는다

## 12. 컴포넌트→노드 매핑과 용량 (Hyper-V 3노드) — 2026-09-05 실측

§11 이 "전체 HA 는 안 된다" 로 끝났으므로, 다음은 **무엇을 어디까지 다중화하고
어디에 놓을 것인가** 다. 88개 워크로드의 requests 를 실측해 계산했다.

### 12-1. 컴포넌트 HA 등급

다중화 가능 여부는 **복제 기구가 실제로 구성돼 있는가**로 갈린다. `replicas` 를
올릴 수 있다는 것과 다중화된다는 것은 다르다(§11-3 이 그 반례다).

| 등급 | 뜻 | 해당 컴포넌트 |
|---|---|---|
| **A** | 클러스터링이 **내장·구성돼 있다** | `kafka`(KRaft, RF≥2) · `elasticsearch`(ECK) · `zookeeper`(앙상블) |
| **B** | 무상태 — 복제본만 늘리면 된다 | `ingress-istio` · `nginx` · `otel-gateway` · `openmeter-api`·`-sink-worker` · `istiod` · `coredns` · `admin` · `cmmn-api` · `waypoint` · `logstash` · OpenReplay 프런트 다수 |
| **C** | **단일만 가능** — 복제 기구가 없거나 본질적 단일 | `postgresql`·`mariadb`·`mongodb`(★§11-3) · `gitlab` · `vault` · `prometheus`·`loki`·`tempo` · `jenkins` · `clickhouse` · `redis`(standalone) · `minio`(3노드로는 erasure 불가) · `hadoop-namenode` · `hbase-master` · `hive-metastore` · `safeline` · `trino`(코디네이터) |
| **D** | DaemonSet — 노드마다 1개 | `falco` 256Mi · `otel-agent` 192 · `filebeat` 128 · `ztunnel` 128 · `tetragon` 128 · `istio-cni-node` 100 → **노드당 0.91 GiB** |

> **C 등급이 압도적으로 많다.** 그리고 그 이유의 대부분은 ADR-015(스토리지)가
> `Open` 이라는 한 가지다. 분산 스토리지가 생기면 C 의 상당수가 B 로 내려온다.

### 12-2. 세 가지 시나리오

```
Σ VM 메모리 = 배치된 파드 requests + 노드당 DaemonSet 0.91 + 시스템 예약 1.9
가용 = 63.4(물리) − 7.0(Windows) − 8.8(L0 랩) = 47.6 GiB
                                  L0-Target 종료 시 50.4 GiB
```

| 시나리오 | 다중화 범위 | Σ VM | 판정 |
|---|---|---:|---|
| ① 완전 HA | A 전부 3중 + B 11종 2중 | **56.28** | ❌ 8.7 초과 |
| **② 실용 HA** | **Kafka 3중 + 핵심 B 6종 2중** | **49.47** | **⚠ `L0-Target` 종료 시 들어감** |
| ③ ② + requests 정정 | 〃 (requests −16%) | **41.55** | ✅ 여유 6.0 |

①이 넘치는 주된 이유는 **Elasticsearch 3중(+4.0 GiB)** 과 `logstash` 2중(+1.5)이다.
ES 를 3중으로 두는 것은 **단일 호스트에서는 가용성이 아니라 검증 가치**다 —
샤드 배치·ILM 복제본·재배정을 시험할 수 있다. 그 값어치가 4 GiB 이상이라고
보면 ①을, 아니면 ②를 택한다.

③의 −16% 는 근거가 있다. **requests 38.9 GiB 대 실사용 29.5 GiB**(−24%)이고,
2026-09-03 에 같은 작업으로 6.7 GiB 를 회수한 전례가 있다. −16% 는 보수적으로
잡은 값이다.

### 12-3. 권장안 ② 의 노드 매핑

| | node-1 (server) | node-2 | node-3 |
|---|---|---|---|
| **VM 메모리** | 16.47 GiB | 16.50 GiB | 16.50 GiB |
| 파드 requests | 13.66 | 13.69 | 13.69 |
| 파드 수 | 42 | 42 | 36 |
| CPU | 7.1 코어 | 7.2 | 6.7 |
| **HA 배치** | kafka(1/3) · istiod(1/2) · otel-gateway(1/2) · openmeter-api(1/2) · ingress(1/2) · nginx(1/2) · coredns(1/2) | kafka(2/3) · istiod(2/2) · otel-gateway(2/2) · openmeter-api(2/2) · ingress(2/2) · nginx(2/2) · coredns(2/2) | kafka(3/3) |
| **주요 단일** | gitlab 2304 · postgresql 1024 · loki 1024 · keycloak 640 · mariadb 512 · solr 512 | elasticsearch 2048 · logstash 1536 · hive-metastore 768 · wazuh-indexer 768 · minio 640 · clickhouse 512 · prometheus 512 | safeline 2368 · trino 2048 · kibana 768 · livy 768 · hadoop-namenode 512 · mongodb 512 · vault 128 |

전 노드 공통: DaemonSet 6종 0.91 GiB.

**단일(C 등급)의 배치는 메모리 균형으로 정했다** — 세 노드가 13.7 GiB 로 거의
같다. 친화성(affinity)으로 묶지 않은 이유는 k8s 통신이 네트워크 투명하기
때문이다. 다만 **장애 반경은 균형과 무관하게 갈린다**:

| 잃는 노드 | 죽는 것 |
|---|---|
| node-1 | GitLab · **PostgreSQL**(Keycloak·Apicurio·Hive MS·OpenMeter 연쇄) · Loki |
| node-2 | **Elasticsearch · Logstash**(SIEM 전체) · MinIO · ClickHouse(과금 집계) · Prometheus |
| node-3 | SafeLine · Trino · Kibana · Vault · MongoDB |

**어느 노드가 빠져도 무언가는 죽는다.** 이것이 §11-2 가 말한 것의 구체적 모습이다 —
분산 스토리지가 없으면 노드를 늘려도 상태 있는 워크로드는 그 자리에 묶인다.
`postgresql` 이 node-1 에 있는 한 node-1 은 사실상 단일 장애점이다.

### 12-4. 파드 수와 CPU

```
파드   42 / 42 / 36   (노드 상한 110 → 여유 충분. 현재 단일 노드는 107/110)
CPU    7.1 / 7.2 / 6.7 코어 = 21.0   (호스트 24 코어)
```

**파드 상한 문제는 이것으로 확실히 해소된다.** CPU 는 21.0 코어가 requests 이고
실사용은 1.5 코어(6%)라 여유가 크다 — 다만 VM 에 vCPU 를 배정할 때 합이 24 를
넘어도 된다(CPU 는 오버커밋이 정상이다). 메모리와 달리 H1 의 제약을 받지 않는다.

### 12-5. 이 매핑이 주지 **않는** 것

- **DB 이중화** — C 등급의 DB 3종은 여전히 단일이다. §11-3 을 고치기 전에는
  `replicas` 를 올리면 안 된다
- **스토리지 이동성** — `local-path` 그대로면 PVC 는 노드에 고정되고, 노드가 죽으면
  그 위의 PVC 파드는 다른 노드에서 뜨지 못한다. **Longhorn 등을 얹으면 해소된다**
  (§11-2-b). DB 는 그것 없이도 §13 의 복제로 해결된다
- ~~호스트 장애 내성~~ — §11-0 으로 **범위 밖**이다
- **논리 손상 내성** — 복제는 잘못된 삭제를 그대로 복제한다. 백업의 몫이다(§13-5)

주는 것은 **다중 노드 검증 환경**이다 — 노드 간 CNI 데이터패스, 안티어피니티,
PDB, 스케줄링, `topologySpreadConstraints`, 노드 드레인. §1 의 "검증 불가" 목록
대부분이 여기서 검증 가능으로 바뀐다. ADR-051 이 A안의 목적으로 적은 것이
정확히 그것이다.

## 13. 영속 컴포넌트의 복제 — 어떻게 할 것인가 (2026-09-05)

§11-3 이 남긴 숙제다. `replicas` 를 올리는 것으로는 안 되고, **DB 안에서
복제를 구성**해야 한다.

### 13-0. 먼저 알아 둘 것 — 이건 분산 스토리지가 필요 없다

§11-2-b 의 결론("Longhorn 을 얹어도 이동성뿐")과 겹쳐 오해하기 쉬운데,
**DB 복제는 분산 스토리지를 요구하지 않는다.**

```
Longhorn 방식   PVC 한 개를 블록 계층에서 3벌 복제  → k8s 가 볼륨을 옮겨 준다
DB 복제 방식    복제본마다 자기 노드의 PVC          → DB 가 데이터를 맞춰 준다
```

후자가 이 호스트에 더 맞는다. `local-path` 그대로 쓰면서 되고, 메모리
3.5 GiB 를 Longhorn 에 내지 않아도 되며, **논리적 손상(잘못된 DELETE)을 제외한
노드 장애에 대해 더 빠른 복구**를 준다. 순서로 보면 **DB 복제가 먼저이고
분산 스토리지는 그 다음**이다.

### 13-1. 지혈 먼저 — 5분짜리

`overlays/prod/patches/replicas-prod.yaml` 에서 **DB 3종을 1로 되돌린다.**
§11-3 의 결함은 노드 수·스토리지와 무관하게 지금 존재한다.

```
postgresql 2 → 1      mariadb 2 → 1      mongodb 3 → 1
nginx 2 · logstash 2  유지 (무상태라 정상)
keycloak 2            유지 — 상태가 PostgreSQL 에 있다(`KC_DB_*`). PVC 는
                      /opt/keycloak/data 로 프로바이더·테마용이다.
                      ★ 단 세션 복제(Infinispan JGroups DNS_PING)가 없어
                        파드가 바뀌면 로그아웃된다 — 데이터 손상은 아니다
```

복제를 **구성하기 전까지는** 1이 정답이다. 지금 상태의 2는 가용성이 아니라 손상이다.

### 13-2. 컴포넌트별 방법

| 컴포넌트 | 방법 | 구성 | 추가 메모리 | 접속 문자열 변경 |
|---|---|---|---:|---|
| **PostgreSQL** | **CloudNativePG** 오퍼레이터 | primary 1 + standby 2, 스트리밍 복제 + **자동 페일오버** + MinIO 로 PITR 백업 | 2×1024 + 오퍼레이터 200 = **2.19 GiB** | `postgresql-headless` → `<cluster>-rw`(쓰기)·`-ro`(읽기). **34곳** |
| **ClickHouse** | `ReplicatedMergeTree` + ClickHouse Keeper | 복제본 2 + Keeper 3(경량) | 512 + 3×128 = **0.88 GiB** | 분산 테이블 또는 다중 호스트 지정 |
| **MongoDB** | 네이티브 replica set | 3 노드 + `rs.initiate()` Job | 2×512 = **1.0 GiB** | `?replicaSet=rs0` + 시드 3개 |
| **MariaDB** | Galera 3중(동기 다중 마스터) | 3 노드 | 2×512 = **1.0 GiB** | 변경 없음(아무 노드나 쓰기) |
| **Redis** | ★ **하지 않는다** — 아래 참조 | AOF 지속화만 켠다 | 0 | 없음 |
| | | | **합계 5.07 GiB** | |

#### 왜 PostgreSQL 만 오퍼레이터인가

셋 중 가장 중요하고(**Keycloak 인증 + OpenMeter 과금 원장** + Apicurio + Hive
Metastore + GitLab), 수기로 하기 가장 어렵다. 수기 스트리밍 복제는
`pg_basebackup` 초기화와 `primary_conninfo` 로 **핫 스탠바이까지는** 되지만
**자동 페일오버가 없다** — 장애 시 사람이 승격해야 한다. 그러면 복제를 해 둔
의미가 절반이다.

레포 관례와도 충돌하지 않는다. ADR-003 이 금지하는 것은 Helm **릴리스**이고,
오퍼레이터 계층은 이미 6종(`local/install-operators.sh`)이 돈다. CloudNativePG
는 단일 YAML 로 배포된다. 그리고 **MinIO 로 PITR 백업**이 딸려 와 ADR-018
(백업 전무)의 일부가 함께 닫힌다.

#### 왜 Redis 는 복제하지 않는가

Sentinel 은 **클라이언트가 Sentinel 을 알아야** 한다. 실측으로 이 레포의
Redis 소비자 8곳(GitLab·GlitchTip·DefectDojo·OpenMeter·OpenReplay·cmmn-api…)
어디에도 Sentinel 설정이 없다 — 전부 단일 호스트를 전제한다. Sentinel 을
넣으면 **여덟 곳의 클라이언트 설정을 각각 고쳐야 하고**, 지원하지 않는 것도
있다.

대신 AOF(`appendonly yes`)를 켠다. 재시작 시 데이터가 살아남는다. OpenMeter 의
중복 제거 키가 사라지면 **과다 청구**가 되므로(Gotcha 16) 이것은 그냥 캐시가
아니다 — 지속화는 반드시 필요하다.

### 13-3. 용량 — requests 정정이 전제다

```
§12 시나리오 ② 실용 HA         49.47 GiB  + 5.07 = 54.54  ❌ 초과
§12 시나리오 ③ ② + requests 정정 41.55 GiB  + 5.07 = 46.62  ✅ 가용 47.6 안
```

**DB 복제는 requests 정정을 선행하면 들어간다.** 근거는 있다 —
requests 38.9 GiB 대 실사용 29.5 GiB 이고 2026-09-03 에 같은 작업으로
6.7 GiB 를 회수한 전례가 있다.

### 13-4. 순서

우선순위는 **잃었을 때 무엇이 무너지는가**로 정한다.

| 순위 | 컴포넌트 | 잃으면 |
|:-:|---|---|
| 1 | **PostgreSQL** | 인증(Keycloak) 정지 + **과금 원장**(OpenMeter 요금제·구독·인보이스) 소실 |
| 2 | **ClickHouse** | **과금 집계** 소실 — 청구 근거가 사라진다 |
| 3 | Redis(AOF) | 중복 제거 키 소실 → **과다 청구** |
| 4 | MongoDB | admin·cmmn-api 데이터 |
| 5 | MariaDB | 〃 |

1·2·3 이 전부 **과금**에 걸린다. §9-2 의 가격·인보이스 작업과 같은 줄기이므로
그때 함께 하는 것이 맞다.

### 13-5. 복제와 백업은 다른 것을 막는다 — 둘 다 필요하다

§11-0 이 디스크·호스트 장애를 범위 밖으로 두었으므로, 남는 위협은 둘이다.

| 위협 | 막는 것 | 비용 |
|---|---|---:|
| **VM·노드 장애** (범위 안) | **복제**(§13-2) | 5.07 GiB |
| **논리 손상** — 사람의 실수, 소프트웨어 결함 | **백업** | ~0 GiB |

**복제는 논리 손상을 막지 못한다.** 잘못된 삭제 구문을 복제본이 충실히 따라
실행한다. 반대로 백업은 노드가 죽는 순간의 가용성을 지켜 주지 못한다.
서로 대체재가 아니다.

#### 백업 — 지금 전무하고, 이제 싸다

실측으로 `pg_dump`·`mysqldump`·`mongodump` 어느 것도 없다(ADR-018 `Open`).

§11-0 의 전제가 여기서 비용을 크게 낮춘다. **디스크 장애가 범위 밖이므로
백업 대상은 MinIO 로 충분하다** — 호스트 밖으로 반출할 필요가 없다.
논리 덤프 CronJob 몇 개면 되고 추가 메모리는 사실상 0이다.

> ADR-018 이 지적한 *"MinIO 를 백업 대상으로 쓰는 것은 순환"*(레이크하우스
> 주 저장소이기도 하다)은 여전히 유효한 지적이다. 다만 그것은 **운영 범위의
> 문제**이지 이 호스트에서 지금 백업을 시작하지 못할 이유는 아니다.
> 버킷을 분리하고 수명주기를 따로 두면 된다.

#### 순서

```
① §13-1 지혈                    완료 (2026-09-05)
② 논리 덤프 CronJob → MinIO       ~0 GiB · 논리 손상 대비
③ §13-2 DB 복제                 5.07 GiB · requests 정정 선행
```

②를 먼저 두는 이유는 값어치가 커서가 아니라 **거의 공짜이고 지금 당장
할 수 있어서**다. ③은 §12 시나리오 ③(requests 정정)을 전제로 하고,
§9-2 의 가격·인보이스 작업과 같은 줄기이므로 그때 함께 하는 것이 맞다.

## 14. HA·장애내구성 검증 스위트 — `scripts/ha-verification/` (2026-09-05)

§11~§13 이 "무엇이 되고 안 되는가" 를 정리했다면 이 절은 **그것을 실제로
확인하는 수단**이다. HA 를 *가지는* 것과 *시험하는* 것은 다르고, 후자는
단일 노드에서도 상당 부분 지금 할 수 있다 — ADR-051 이 A안의 목적으로 적은
"클라우드 재구축 전 선검증" 이 바로 그것이다.

기존 `scripts/security-verification/` 과 같은 모양이다(개별 스크립트 + `run-all.sh`).

### 14-1. 무엇을 시험하는가

| | 시험 | 방식 | 파괴적 |
|---|---|---|:-:|
| **HA-1** | 복제본 수 가드 | §11-3 회귀 방지 — 복제 기구 없이 `replicas>=2` 면 FAIL | — |
| **HA-2** | 무상태 페일오버 | 복제본을 **실제로 죽이며** 요청을 계속 보낸다 | ★ |
| **HA-3** | StatefulSet 복구 | 파드를 **죽이고** 같은 PV 재바인딩·복구 시간을 잰다 | ★ |
| **HA-4** | 다중 노드 공백 | 아무것도 하지 않는다 — **못 하는 시험을 나열한다** | — |

### 14-2. 실행 결과 (2026-09-05)

```
HA-1  postgresql·mariadb·mongodb  replicas=1 · 복제 미구성이나 1이라 안전   통과
HA-2  nginx 복제본 하나를 죽이는 동안  ok=80 · bad=0                        통과
HA-3  postgresql-0 삭제 → 16s 만에 같은 PV 재바인딩 후 Ready               통과
HA-4  GAP 14건                                                            (정보)
```

**HA-1 은 통과만으로 믿지 않았다.** 회귀를 주입한 사본
(`postgresql: replicas: 2`)에서 돌려 `FAIL` + 종료코드 1 을 확인했다 —
가드가 실제로 잡는다.

**HA-3 이 재는 것은 "다른 노드로 옮겨가는가" 가 아니다.** 단일 노드에서
의미 있는 것은 **"같은 PVC 를 다시 물고 데이터가 남아 있는가"** 이고 그것은
노드 수와 무관하다. PV 가 바뀌면 빈 볼륨을 물었다는 뜻이므로 FAIL 이다.

### 14-3. ★ 시험이 부수 피해를 냈다 — 그래서 사전 점검을 넣었다

첫 실행에서 **시험 대상이 아닌 워크로드 둘이 죽었다.**

```
openmeter-billing-advance-invoices-...   Pending
openmeter-billing-collect-invoices-...   Pending
  0/1 nodes are available: 1 Too many pods.
```

HA-2 의 프로브 파드 하나가 노드를 파드 상한(110)에 밀어 넣었고, 마침 그때
뜬 **과금 CronJob 둘이 스케줄되지 못했다.** 프로브가 정리되자 자력 복구됐고
2분 뒤 비정상 파드는 0이었으나, **시험 때문에 과금 Job 이 죽는 것은 받아들일
수 없다.**

`run-all.sh` 에 사전 점검을 넣었다 — 파드 여유가 3자리 미만이면 **중단**한다
(HA-2 가 프로브 1 + 복제본 1, 두 자리를 쓴다).

```
파드 여유: 110 / 110 (여유 0)
중단 — 파드 여유가 0 자리다. ... 여유를 3자리 이상 만들고 다시 돌릴 것.
```

이것은 부수적으로 **§12-4 의 예측이 현실이 되었음을 보여 준다.** 파드 상한은
더 이상 다가오는 제약이 아니라 **지금 걸려 있는 제약**이다(109 Running +
Init:Error 1 = 110/110). 노드를 늘리거나 `max-pods` 를 올리기 전에는 새 워크로드가
아예 스케줄되지 않는다.

### 14-4. HA-4 가 존재하는 이유

통과 항목만 출력하는 검증 스위트는 위험하다. **통과 4건이 "HA 검증 완료" 로
읽힌다.** 이 레포에서 반복된 실패 유형이 정확히 그것이다 — 설정은 있으나 한
번도 실행된 적이 없어 아무 증상도 내지 않는 것(§8-64 에서 셋이 한꺼번에
드러났다).

그래서 HA-4 는 **못 하는 시험을 세어 출력한다.** 현재 14건이다.

```
다중 노드 필요   드레인 · PDB 실동작 · 안티어피니티 · topologySpread ·
                 볼륨 재배치 · 노드 간 CNI · etcd 정족수            (7)
복제본이 1       kafka · elasticsearch · redis · clickhouse         (4)
DB 복제 미구성   PostgreSQL 페일오버 · Galera · replSet             (3)
```

`run-all.sh` 는 마지막에 이렇게 출력한다 — **"통과 건수는 'HA 가 된다' 는 뜻이
아니다. HA-4 의 GAP 목록이 비어야 그렇게 말할 수 있다."**

### 14-5. 다음

GAP 을 줄이는 순서는 §13-4·§9-2 와 같다.

1. **DB 복제**(§13-2) — GAP 3건이 사라지고 HA-3 에 페일오버 시험이 붙는다
2. **Kafka·ES 3중화**(§12 시나리오 ①) — GAP 4건 중 2건
3. **다중 노드**(§10) — GAP 7건이 한꺼번에 사라진다

## 15. 단일 노드에서 복제·HA 를 먼저 세우고 시험한다 (2026-09-05 결정)

**전략은 옳다.** §13-2 의 작업 대부분은 노드 수와 무관하고, 단일 노드에서
검증한 뒤 다중 노드로 옮기면 이설 시점의 위험이 크게 준다. §8-31 이 H5 를
랩 VM 한 대로 먼저 확인한 것과 같은 논리다.

다만 **"단일 노드에서 통과했으니 다중 노드도 된다" 로 읽으면 안 되는 항목**이
분명히 있다. 그 경계를 먼저 적는다.

### 15-1. 옮겨가는 것 — 단일 노드에서 검증 가능

| 항목 | 왜 노드 수와 무관한가 |
|---|---|
| **복제 부트스트랩** | CNPG 클러스터 형성 · `rs.initiate()` · wsrep 초기 동기화 · Keeper 앙상블 — 전부 프로세스 간 프로토콜이다 |
| **접속 문자열 전환 34곳** | `postgresql-headless` → `-rw`/`-ro`. **가장 큰 숨은 작업이고 100% 옮겨간다** |
| **페일오버 기구** | primary 를 죽이고 승격되는지. 죽이는 방식이 다를 뿐 기구는 같다 |
| **소비자 재접속** | Keycloak·GitLab·Apicurio·Hive MS·OpenMeter 가 승격 후 다시 붙는가 |
| **스키마·데이터 정합성** | 페일오버 후 데이터가 맞는가 |
| **백업·복원 절차** | CNPG → MinIO PITR. §13-5 의 ②와 함께 |
| **오퍼레이터 조정** | CNPG 가 상태를 되돌리는 동작 |

### 15-2. ★ 옮겨가지 않는 것 — 거짓 확신의 자리

| 항목 | 단일 노드에서 무슨 일이 일어나는가 |
|---|---|
| **안티어피니티·topologySpread** | `required` 로 두면 복제본이 **아예 스케줄되지 않고**, `preferred` 로 두면 **조용히 한 노드에 뭉친다.** 즉 시험하려면 규칙을 느슨하게 해야 하고 **그 순간 다중 노드 동작은 미검증이 된다.** 가장 위험한 항목이다 |
| **네트워크 분단·split-brain** | 복제의 **가장 중요한 실패 모드**인데 유도할 수 없다. Galera split-brain, Patroni 펜싱, MongoDB 선거가 전부 여기 걸린다 |
| **정족수 상실** | 3중 중 하나를 죽이는 것과 **노드 하나를 잃는 것**은 다르다. 후자는 그 노드의 다른 워크로드도 함께 사라진다 |
| **지연·타임아웃 정정** | 루프백은 0.1ms 다. 거기서 맞춘 값이 실제 네트워크에서 깨진다 — **동기 복제(Galera)가 특히** |
| **자원 경합 성격** | 3 인스턴스가 페이지 캐시·디스크를 공유한다. 다중 노드에서는 그러지 않으므로 성능 특성과 그에 의존하는 타임아웃이 달라진다 |
| **PVC 배치** | `local-path` 라 복제본 3개의 PVC 가 **같은 디스크**에 놓인다. `WaitForFirstConsumer` 와 스케줄러의 상호작용이 다중 노드에서 달라진다 |

> **결론적으로 단일 노드 시험이 답해 주는 질문은 "설정이 맞는가" 이고,
> 답해 주지 않는 질문은 "분단되면 어떻게 되는가" 다.** 전자가 작업량의
> 대부분이고 후자가 위험의 대부분이다. 둘 다 필요하다.

### 15-3. 지금 막고 있는 것 두 가지

실측(2026-09-05):

```
파드     109 / 110      여유 1자리
메모리   38.0 / 41.1 GiB (92%)   여유 3.0 GiB
```

§13-2 의 복제 구성은 **파드 11자리와 메모리 5.07 GiB** 를 더 쓴다.

| 추가분 | 파드 | 메모리 |
|---|:-:|---:|
| PostgreSQL CNPG (인스턴스 3 + 오퍼레이터) | +3 | 2.19 GiB |
| MongoDB replica set 3 | +2 | 1.00 |
| MariaDB Galera 3 | +2 | 1.00 |
| ClickHouse 복제본 2 + Keeper 3 | +4 | 0.88 |
| **합계** | **+11** | **5.07** |

**둘 다 지금 여유를 넘는다.** 먼저 자리를 만들어야 한다.

### 15-4. 자리를 만드는 순서

```
① max-pods 상향        110 → 150     k3s kubelet 인자. 재기동 필요
② requests 정정         −6 GiB 회수   실사용 29.5 vs requests 38.0
③ 그 다음에 §13-2 착수
```

**①** 은 §12-4·§14-3 에서 이미 걸린 제약이다. 단일 노드에 파드를 몰아넣는
것이므로 커널·containerd 부담이 늘지만, 다중 노드로 가기 전의 임시 조치로는
타당하다.

**②** 는 근거가 있다 — requests 38.0 GiB 대 실사용 29.5 GiB 이고,
2026-09-03 에 같은 작업으로 6.7 GiB 를 회수한 전례가 있다
(`overlays/local/patches/requests-local.yaml`). WSL 캡(44GB)을 올리는 것보다
이쪽이 낫다: 캡을 올리면 Windows·L0 랩 몫을 뺏는데, requests 정정은
**아무것도 뺏지 않고** 스케줄 가능 공간만 늘린다.

### 15-5. 시험 순서 — 스위트에 붙을 것들

§14 의 스위트에 복제가 생기면 아래가 GAP 에서 시험으로 바뀐다.

| 새 시험 | 내용 | 단일 노드에서 |
|---|---|---|
| HA-5 복제 부트스트랩 | 복제본이 형성되고 동기화되는가 | ✅ 완전히 |
| HA-6 페일오버 | primary 를 죽이고 승격·쓰기 재개까지 시간 | ✅ 완전히 |
| HA-7 소비자 재접속 | 승격 후 Keycloak·OpenMeter 가 다시 붙는가 | ✅ 완전히 |
| HA-8 데이터 정합성 | 페일오버 전후 행 수·체크섬 | ✅ 완전히 |
| HA-9 분단 내성 | split-brain·펜싱 | ❌ **다중 노드 전용** |
| HA-10 정족수 상실 | 노드 하나를 잃을 때 | ❌ **다중 노드 전용** |

HA-9·10 은 §14-4 의 GAP 목록에 **남겨 둔다.** 단일 노드에서 5~8이 전부
통과해도 그 둘이 GAP 인 한 "다중 노드에서도 된다" 고 적지 않는다.

## 16. DB 밖의 컴포넌트는 어떻게 HA 로 만드는가 (2026-09-05)

> **★ 이 절은 불완전하다 — §17 이 대신한다.** 손으로 30개쯤을 적고 완전한
> 것처럼 보이게 두었다. 실제 컨트롤러는 **124개**이고 OpenReplay 17종,
> OpenMeter 6종, 오퍼레이터 13종, SafeLine·DefectDojo 계열, CronJob 15종이
> 통째로 빠져 있었다. 아래 내용 자체는 맞으나 목록으로 쓰지 말 것.


§13 이 DB 를 다뤘고 §12-1 은 등급만 나눴다. 나머지를 컴포넌트별로 적는다.
**일반론이 아니라 이 레포의 실제 매니페스트를 읽고 확인한 것이다.**

### 16-0. ★ 먼저 — "무상태처럼 보이지만 아닌 것" 다섯

§11-3 과 같은 부류의 함정이다. `replicas` 를 올리면 될 것처럼 생겼는데
**로컬 디스크에 상태가 있어서** 올리는 순간 갈라지거나 조용히 어긋난다.

| 컴포넌트 | 실측된 현재 구성 | 올리면 |
|---|---|---|
| **Grafana** | `GF_DATABASE_*` 가 없다 → **SQLite on PVC** | 대시보드·사용자가 인스턴스마다 따로 논다 |
| **Loki** | `object_store: filesystem` | 인스턴스마다 다른 로그를 본다 |
| **Tempo** | `backend: local` | 〃 |
| **MinIO** | `args: ["server", "/data"]` — **단일 드라이브 standalone** | 분산 모드가 아니라 그냥 별개 인스턴스 |
| **Vault** | `storage "file"` (설정 주석도 "Raft 는 3노드 이상" 이라 적고 있다) | 별개 금고 |

**전부 저장소를 먼저 바꿔야 복제본이 의미를 갖는다.** 다행히 넷은 목적지가
같다 — **MinIO(S3)** 다. 그런데 그 MinIO 자신이 단일 드라이브라 **MinIO 가
선행 조건**이 된다.

### 16-1. 플랫폼 필수 — 가장 싸고 가장 효과가 크다

| 컴포넌트 | 현재 | HA 구성 | 추가 메모리 |
|---|:-:|---|---:|
| **CoreDNS** | **1** | `replicas: 2` + anti-affinity. **DNS 는 전부의 의존성**이라 여기가 1인 것이 가장 위험하다 | 70Mi |
| **istiod** | **1** | `replicas: 2`. 죽으면 새 워크로드가 메시에 못 들어온다(기존 트래픽은 유지) | 256Mi |
| **ingress gateway** | 1 | `replicas: 2` | 128Mi |
| **ztunnel·istio-cni** | DaemonSet | 노드당 1 — 구조상 이미 그렇다 | — |
| | | **소계** | **~0.44 GiB** |

**0.44 GiB 로 DNS·컨트롤플레인·진입점이 이중화된다.** §13 의 DB 복제(5.07 GiB)
보다 훨씬 싸고, 다중 노드로 가면 곧바로 효과가 난다.

### 16-2. 메시징·검색 — base 는 이미 HA 다

| 컴포넌트 | base | local | HA 로 만들려면 |
|---|:-:|:-:|---|
| **Kafka** | `replicas: 3` | 1 | local 오버레이의 축소를 걷고, **토픽 RF≥2 · `min.insync.replicas=2`** 를 함께 볼 것. 브로커만 3이고 RF=1 이면 브로커 하나 잃을 때 그 파티션이 사라진다 |
| **Elasticsearch** | `nodeSets.count: 3` | 1 | 〃 + **인덱스 복제본 ≥1**. `ES_REPLICAS=0` 을 걷어야 한다(Gotcha 14 와 반대 방향) |
| **ZooKeeper** | 1 | 1 | 앙상블 3. lakehouse-local 전용 |

> **base 가 이미 3인데 local 이 1로 줄이고 있다.** 즉 HA 구성은 "만드는" 것이
> 아니라 **"local 의 축소를 걷는" 것**이다. 비용은 §12 시나리오 ①의 ES 3중
> (+4.0 GiB) · Kafka 3중(+3.0 GiB)이 그대로다.

### 16-3. 관측성 — 넷이 각각 다르다

| 컴포넌트 | HA 구성 방법 | 비고 |
|---|---|---|
| **Alertmanager** | **네이티브 클러스터링이 있다.** 현재 `--cluster.listen-address=`(빈 값 = 비활성). 3 복제본 + `--cluster.peer` 로 gossip 하면 **알림 중복이 자동 제거**된다 | 싸고(64Mi×2) 효과가 크다. §8-63 에서 단일로 세운 것을 되돌리면 된다 |
| **Prometheus** | 동일 설정 2대를 **나란히** 돌린다(HA 쌍). 둘 다 같은 타깃을 긁고 Alertmanager 가 중복을 제거한다. 장기 저장·전역 질의가 필요하면 Thanos/Mimir | 512Mi 추가. 데이터는 이중으로 쌓인다 |
| **Loki** | `filesystem` → **MinIO(S3)** 로 옮기고 마이크로서비스 모드(distributor·ingester·querier)로 분리 | 가장 큰 작업. 단일 바이너리로는 HA 불가 |
| **Tempo** | `backend: local` → MinIO. Loki 와 같은 패턴 | 〃 |
| **Grafana** | **먼저 SQLite → PostgreSQL** 로 옮긴다. 그 뒤에는 완전 무상태라 `replicas: 2` 로 끝 | §13 의 PostgreSQL 복제가 선행되면 자연스럽다 |
| **Logstash** | 이미 무상태에 가깝다. Kafka **컨슈머 그룹**이 분배를 맡으므로 `replicas: 2` 로 충분 | prod 가 이미 2다 |
| **Kibana** | 상태가 ES 에 있다 → `replicas: 2` | 768Mi 추가 |

### 16-4. 보안·거버넌스

| 컴포넌트 | HA 구성 방법 | 함정 |
|---|---|---|
| **Vault** | `storage "file"` → **Raft(integrated storage) 3노드** | ★ **자동 봉인 해제(auto-unseal)가 없으면 HA 가 무의미하다** — 재시작마다 사람이 열어야 한다(`NEXT-SESSION.md` 에 이미 적혀 있다). Transit·KMS auto-unseal 이 선행 |
| **Keycloak** | 상태는 이미 PostgreSQL 에 있다. `replicas: 2` 는 지금도 동작한다 | ★ **세션 복제(Infinispan)가 없어 파드가 바뀌면 로그아웃**된다. `KC_CACHE=ispn` + JGroups **DNS_PING** 을 붙여야 진짜 무중단이 된다 |
| **Wazuh indexer** | OpenSearch 클러스터다(`cluster.name` 있음) → 3노드 | ES 와 같은 패턴 |
| **Wazuh manager** | master/worker 클러스터 모드 | 매니페스트에 클러스터 설정 없음 |
| **Ranger admin** | 상태가 DB 에 있다 → 여러 인스턴스 + 앞단 분산 | Gotcha 11(계정 잠금)과 무관하게 가능 |
| **DS389** | `replicas: 1` — **multi-supplier 복제** 구성 필요 | LDAP 복제는 별도 설정이다. 복제본만 늘리면 갈라진다 |
| **Solr** | ZK 를 안 본다 → standalone. **SolrCloud** 로 바꿔야 한다 | ZooKeeper 앙상블이 선행 |
| **SafeLine·Caldera·DefectDojo·Dependency-Track** | compose 태생 단일 | 웹 계층만 2로 늘릴 수 있으나 실익이 작다 |

### 16-5. 레이크하우스

| 컴포넌트 | HA 구성 방법 |
|---|---|
| **MinIO** | **분산 모드는 엔드포인트 4개 이상**이 필요하다. 3노드라면 노드당 드라이브를 2개씩 두어 6드라이브로 구성한다. 이것이 Loki·Tempo·Grafana·백업의 **공통 선행 조건**이다 |
| **Trino** | 코디네이터 1 + 워커 N. **코디네이터 HA 는 Trino 에 없다** — 워커만 늘어난다 |
| **Hive Metastore** | 상태가 PostgreSQL 에 있다 → `replicas: 2` 로 끝. 싸다 |
| **HDFS NameNode** | JournalNode 3 + ZKFC + standby NN. **큰 작업**이고 lakehouse-local 전용이다 |
| **HBase Master** | 마스터를 여럿 두면 ZK 가 선출한다. 비교적 쉽다 |
| **Spark History·Livy·Connect** | 단일. 실익 작음 |

### 16-6. DevOps — 사실상 불가

- **GitLab** — 진짜 HA 는 Gitaly Cluster(Praefect) + Redis + 오브젝트 스토리지가
  필요하다. 단일 StatefulSet 을 늘리는 것으로는 안 된다. **범위 밖으로 둔다.**
- **Jenkins** — 컨트롤러 HA 는 상용 기능이다. 에이전트를 늘리고 컨트롤러는
  백업으로 보호한다.

### 16-7. 우선순위 — 싼 것부터

| 순위 | 묶음 | 추가 메모리 | 얻는 것 |
|:-:|---|---:|---|
| 1 | **플랫폼 필수**(CoreDNS·istiod·게이트웨이) | 0.44 GiB | DNS·컨트롤플레인·진입점 |
| 2 | **Alertmanager 클러스터링** | 0.13 | 경보 중복 제거 — 설정 한 줄 |
| 3 | **Hive MS·Kibana·Logstash 복제본** | ~2.3 | 무상태라 그냥 됨 |
| 4 | **Keycloak 세션 복제** | 0 | 설정만. 로그아웃 문제 해소 |
| 5 | §13 의 **DB 복제** | 5.07 | 영속 계층 |
| 6 | **MinIO 분산** | ~1.9 | Loki·Tempo·Grafana·백업의 선행 조건 |
| 7 | Kafka·ES 3중화 | 7.0 | §12 시나리오 ① |
| 8 | Vault Raft(+auto-unseal) · Loki/Tempo 분리 · HDFS NN HA | 큼 | |

**1~4 는 합쳐 3 GiB 미만이고 대부분 설정 변경이다.** §15-3 의 자리 만들기
(`max-pods` 상향 + requests 정정)만 하면 지금 단일 노드에서도 세워 시험할 수
있다 — §15-1 의 "옮겨가는 것" 에 전부 해당한다.

## 17. 전 컴포넌트 HA 등급표 — 124개 (2026-09-05)

§16 은 손으로 적었고 30개쯤에서 멈췄다. **손으로 적은 목록은 반드시 빠진다.**
그래서 이 표는 살아 있는 클러스터에서 생성한다.

```
python3 scripts/ha-verification/ha-classify.py --md
```

규칙에 없는 컴포넌트는 `미분류` 로 나온다 — **빠진 것이 조용히 사라지지 않게
하는 것이 이 스크립트의 요점**이고, HA-4 가 GAP 을 세어 출력하는 것과 같은
발상이다(§14-4). 워크로드가 늘면 다시 돌릴 것.

### 17-1. 등급

| 등급 | 뜻 | 무엇을 해야 하나 |
|:-:|---|---|
| **R** | 복제만 하면 됨 | 상태가 외부(DB·ES·오브젝트)에 있다. `replicas` + PDB + anti-affinity |
| **C** | 클러스터링 구성 | 앱 고유 프로토콜이 필요 — RF·Raft·Galera·replSet·Infinispan·SolrCloud |
| **S** | 상태를 먼저 옮겨야 | **로컬 디스크에 상태가 있다.** 외부 저장소 전환이 선행 |
| **L** | 리더 선출 | 오퍼레이터·컨트롤러. `replicas 2` + leader election |
| **D** | DaemonSet | 구조상 노드당 1 — 이미 그 형태다 |
| **J** | Job/CronJob | HA 개념이 다르다. **멱등성·중복 실행 방지**가 관건 |
| **X** | 실익 없음/불가 | 단일 전제 설계이거나 상용 기능 |

### 17-2. 분포

```
합계 124 개 — R 53 · C 17 · S 6 · L 13 · D 8 · J 15 · X 12
```

읽는 법:

- **R 53개가 가장 큰 덩어리다.** 절반 가까이가 `replicas` 만 올리면 된다 —
  §16-7 의 우선순위 1~4 가 여기서 나온다. 다만 **R 이라고 공짜는 아니다**:
  2대가 되면 `kube-state-metrics` 는 지표가 이중이 되고 `keycloak` 은 세션이
  갈린다. 표의 "HA 구성 방법" 열에 그런 단서를 적어 두었다.
- **S 6개가 가장 위험하다**(Grafana·Loki·Tempo·Pyroscope·Redis·
  dependency-track-apiserver). 무상태처럼 생겼는데 로컬 상태가 있어
  `replicas` 를 올리면 조용히 갈라진다 — §11-3 과 같은 부류다.
- **J 15개는 지금까지 논의에서 통째로 빠져 있었다.** CronJob 에 HA 는
  "여러 개 띄우기" 가 아니라 **"두 번 돌아도 안전한가"** 다. 과금 계열
  (`openmeter-billing-*`·`-subscription-sync`·`-dlq-replay`)이 여기 있고
  중복 실행은 곧 **중복 청구**다(Gotcha 16 과 같은 줄기).
  실측해 보니 **15개 중 14개가 이미 `concurrencyPolicy: Forbid`** 다 —
  과금 넷도 전부 포함된다. 예외는 `efs-cleaner`(`Allow`) 하나이고 정리
  작업이라 중복이 무해하다. **이 축은 이미 갖춰져 있었다.**
  남는 것은 노드가 늘 때 kube-controller-manager 가 단일 스케줄러라는
  점인데, 그것은 제어평면 HA(§11-1)에 딸려 온다.
- **L 13개**는 대부분 차트가 리더 선출을 이미 지원한다. 싸다.
- **X 12개**는 손대지 않는다. GitLab·Jenkins·Trino 코디네이터처럼 구조상
  불가한 것과, `defectdojo-celery-beat`·`ranger-usersync` 처럼 **단일이어야
  옳은 것**이 섞여 있다. 후자를 늘리면 스케줄·동기화가 중복 발행된다.

### 17-3. 전체 표

| 등급 | 컴포넌트 | 종류 | 현재 | PVC | HA 구성 방법 |
|:-:|---|---|:-:|:-:|---|
| **R** | istiod `istio-system` | Deployment | 1 | - | replicas 2 |
| **R** | coredns `kube-system` | Deployment | 1 | - | replicas 2 + anti-affinity. DNS 는 전부의 의존성이다 |
| **R** | metrics-server `kube-system` | Deployment | 1 | - | 무상태 |
| **R** | admin | StatefulSet | 1 | - | 상태는 MariaDB/Mongo 에 있다 |
| **R** | akhq | StatefulSet | 1 | - | 무상태 UI |
| **R** | alerts-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | api-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | apicurio-registry | StatefulSet | 1 | - | 상태는 PG 에 있다 |
| **R** | apicurio-ui | Deployment | 1 | - | 무상태 UI |
| **R** | assets-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | assist-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | canvases-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | chalice-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | cmmn-api | StatefulSet | 1 | - | 상태는 MariaDB/Mongo 에 있다 |
| **R** | db-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | defectdojo-celery-worker | Deployment | 1 | Y | 큐 워커 |
| **R** | defectdojo-django | Deployment | 1 | Y | 상태는 PG 에 있다 |
| **R** | defectdojo-nginx | Deployment | 1 | - | 상태는 PG 에 있다 |
| **R** | dependency-track-frontend | Deployment | 1 | - | 무상태 |
| **R** | ender-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | falcosidekick | Deployment | 1 | - | 무상태 전달자 |
| **R** | frontend-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | glitchtip-web | Deployment | 1 | - | 상태는 PG/Redis 에 있다 |
| **R** | glitchtip-worker | Deployment | 1 | - | 큐 워커 — 늘리면 그대로 분산 |
| **R** | hadoop-datanode | StatefulSet | 1 | Y | 데이터 노드는 늘리면 그대로 분산된다 |
| **R** | hbase-regionserver | StatefulSet | 1 | - | 데이터 노드는 늘리면 그대로 분산된다 |
| **R** | heuristics-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | hive-metastore | StatefulSet | 1 | - | 상태는 PG 에 있다 — 싸다 |
| **R** | hive-server | StatefulSet | 1 | - | 메타스토어를 공유 |
| **R** | http-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | images-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | ingress-istio | Deployment | 1 | - | replicas 2 |
| **R** | integrations-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | kafka-bridge | Deployment | 1 | - | 무상태 |
| **R** | kibana-kb | Deployment | 1 | - | 상태는 ES 에 있다 |
| **R** | knox | Deployment | 1 | - | 무상태 게이트웨이 |
| **R** | kube-state-metrics | Deployment | 1 | - | 무상태. 2대면 지표가 이중이 되므로 Prometheus 쪽에서 제거 |
| **R** | lam | Deployment | 1 | - | 상태는 DS389 에 있다 |
| **R** | logstash | StatefulSet | 1 | - | Kafka 컨슈머 그룹이 분배. replicas 2 |
| **R** | nginx | Deployment | 1 | - | 무상태 |
| **R** | openmeter-api | Deployment | 1 | - | 상태는 PG/CH/Redis. ★ 과금 진입점이라 우선순위 높음 |
| **R** | openmeter-balance-worker | Deployment | 1 | - | Kafka 컨슈머 그룹이 분배 |
| **R** | openmeter-billing-worker | Deployment | 1 | - | Kafka 컨슈머 그룹이 분배 |
| **R** | openmeter-notification-service | Deployment | 1 | - | 무상태 |
| **R** | openmeter-sink-worker | Deployment | 1 | - | Kafka 컨슈머 그룹이 분배 |
| **R** | otel-gateway | Deployment | 1 | - | 무상태 수집기 |
| **R** | prometheus | StatefulSet | 1 | Y | 동일 설정 2대 병렬(HA 쌍). 중복은 Alertmanager 가 제거 |
| **R** | ranger-admin | StatefulSet | 1 | - | 상태는 DB 에 있다 |
| **R** | sink-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | sourcemapreader-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | spot-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | storage-openreplay | Deployment | 1 | - | OpenReplay 계층 — 대부분 무상태(상태는 PG·CH·Redis) |
| **R** | waypoint | Deployment | 1 | - | replicas 2 |
| **C** | alertmanager | Deployment | 1 | - | 네이티브 gossip 클러스터. 현재 --cluster.listen-address= 로 꺼져 있다 |
| **C** | clickhouse | StatefulSet | 1 | Y | ReplicatedMergeTree + Keeper 3 (§13-2) |
| **C** | ds389 | StatefulSet | 1 | Y | multi-supplier 복제. 복제본만 늘리면 갈라진다 |
| **C** | elasticsearch-es-default | StatefulSet | 1 | Y | ECK nodeSets 3 + 인덱스 복제본 >=1 |
| **C** | hadoop-namenode | StatefulSet | 1 | Y | JournalNode 3 + ZKFC + standby NN — 큰 작업 |
| **C** | hbase-master | StatefulSet | 1 | - | 마스터 여럿 + ZK 선출 |
| **C** | kafka | StatefulSet | 1 | Y | 브로커 3 + 토픽 RF>=2 + min.insync.replicas=2 |
| **C** | keycloak | StatefulSet | 1 | Y | 상태는 PG 에 있다. replicas 2 + JGroups DNS_PING(세션 복제) |
| **C** | mariadb | StatefulSet | 1 | Y | Galera 3중 (§13-2) |
| **C** | minio | StatefulSet | 1 | Y | 분산 모드는 엔드포인트 4개 이상. Loki·Tempo·Grafana·백업의 선행 |
| **C** | mongodb | StatefulSet | 1 | Y | 네이티브 replica set (§13-2) |
| **C** | postgresql | StatefulSet | 1 | Y | CloudNativePG — 스트리밍 복제 + 자동 페일오버 (§13-2) |
| **C** | solr | StatefulSet | 1 | Y | SolrCloud 로 전환 + ZK 앙상블 |
| **C** | vault | StatefulSet | 1 | Y | Raft 3노드. ★ auto-unseal 이 선행 — 없으면 무의미 |
| **C** | wazuh-indexer | StatefulSet | 1 | Y | OpenSearch 클러스터 3노드 |
| **C** | wazuh-manager | StatefulSet | 1 | Y | master/worker 클러스터 모드 — 매니페스트에 설정 없음 |
| **C** | zookeeper | StatefulSet | 1 | Y | 앙상블 3 |
| **S** | dependency-track-apiserver | Deployment | 1 | Y | PVC 를 쓴다 — 외부 저장소 전환 선행 |
| **S** | grafana | Deployment | 1 | - | SQLite on PVC → PostgreSQL 로 옮긴 뒤 replicas 2 |
| **S** | loki | StatefulSet | 1 | Y | filesystem → MinIO(S3) + 마이크로서비스 모드 |
| **S** | pyroscope | StatefulSet | 1 | Y | 로컬 저장 → 오브젝트 스토리지 필요 |
| **S** | redis | StatefulSet | 1 | Y | Sentinel 은 클라이언트 8곳이 미지원 → AOF 지속화만 (§13-2) |
| **S** | tempo | StatefulSet | 1 | Y | backend local → MinIO |
| **L** | cert-manager `cert-manager` | Deployment | 1 | - | replicas 2 + 리더 선출 |
| **L** | cert-manager-cainjector `cert-manager` | Deployment | 1 | - | replicas 2 + 리더 선출 |
| **L** | cert-manager-webhook `cert-manager` | Deployment | 1 | - | replicas 2 + 리더 선출 |
| **L** | elastic-operator `elastic-system` | StatefulSet | 1 | - | 리더 선출. 오퍼레이터가 죽어도 기존 ES 는 계속 돈다 |
| **L** | cilium-operator `kube-system` | Deployment | 1 | - | replicas 2 + 리더 선출. 죽어도 기존 데이터패스는 계속 돈다 |
| **L** | local-path-provisioner `kube-system` | Deployment | 1 | - | 리더 선출. ★ 다만 볼륨은 노드 로컬이다(§11-2-b) |
| **L** | kyverno-admission-controller `kyverno` | Deployment | 1 | - | replicas 2 + 리더 선출(차트 기본 지원) |
| **L** | kyverno-background-controller `kyverno` | Deployment | 1 | - | replicas 2 + 리더 선출(차트 기본 지원) |
| **L** | kyverno-cleanup-controller `kyverno` | Deployment | 1 | - | replicas 2 + 리더 선출(차트 기본 지원) |
| **L** | kyverno-reports-controller `kyverno` | Deployment | 1 | - | replicas 2 + 리더 선출(차트 기본 지원) |
| **L** | policy-reporter `policy-reporter` | Deployment | 1 | - | 리더 선출 |
| **L** | tetragon-operator `tetragon` | Deployment | 1 | - | 리더 선출 |
| **L** | trivy-operator `trivy-system` | Deployment | 1 | - | 리더 선출 |
| **D** | istio-cni-node `istio-system` | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | ztunnel `istio-system` | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | cilium `kube-system` | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | cilium-envoy `kube-system` | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | falco | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | filebeat | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | otel-agent | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **D** | tetragon `tetragon` | DaemonSet | 1 | - | 구조상 노드당 1 — 이미 그 형태다 |
| **J** | efs-cleaner | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | kubescape-scan | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | openmeter-billing-advance-invoices | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | openmeter-billing-collect-invoices | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | openmeter-dlq-replay | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | openmeter-subscription-sync | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-admin-passwords | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-elasticsearch-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-mariadb-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-minio-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-mongodb-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-postgresql-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotate-redis-password | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | rotation-git-sync | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **J** | trivy-image-scan | CronJob | - | - | HA 개념이 다르다 — 멱등성·중복 실행 방지가 관건 |
| **X** | caldera | Deployment | 1 | - | 랩 전용 단일 |
| **X** | defectdojo-celery-beat | Deployment | 1 | - | ★ beat 는 단일이어야 한다 — 여럿이면 스케줄이 중복 발행된다 |
| **X** | gitlab | StatefulSet | 1 | Y | Gitaly Cluster(Praefect) + Redis + 오브젝트 스토리지 필요 — 범위 밖 |
| **X** | jenkins | StatefulSet | 1 | Y | 컨트롤러 HA 는 상용 기능. 에이전트 확장 + 백업 |
| **X** | livy | StatefulSet | 1 | - | 단일 전제. 실익 작음 |
| **X** | ranger-usersync | Deployment | 1 | - | 단일 동기화기 — 여럿 돌리면 중복 동기화 |
| **X** | safeline | Deployment | 1 | Y | compose 태생 단일 |
| **X** | safeline-fvm | Deployment | 1 | - | compose 태생 단일 |
| **X** | safeline-luigi | Deployment | 1 | - | compose 태생 단일 |
| **X** | spark-connect | StatefulSet | 1 | - | 단일 전제. 실익 작음 |
| **X** | spark-history | StatefulSet | 1 | - | 단일 전제. 실익 작음 |
| **X** | trino | StatefulSet | 1 | - | 코디네이터 HA 가 Trino 에 없다. 워커만 늘어난다 |

### 17-4. 이 표로 무엇을 하나

1. **R 등급부터 훑는다** — §15-3 의 자리(파드·메모리)를 만든 뒤 `replicas` 를
   올리고 §14 의 HA-2 로 무중단을 확인한다. 53개 중 실익 있는 것부터
   (CoreDNS·istiod·게이트웨이·openmeter-api·hive-metastore·kibana)
2. **S 등급 6개는 저장소 전환이 먼저다.** 넷의 목적지가 MinIO 라 **MinIO
   분산화가 선행**이다(§16-0)
3. **J 등급 15개는 복제가 아니라 멱등성을 본다.** 과금 CronJob 넷이 우선
4. **C 등급 17개**가 §13 과 §16-4 의 본체다. 가장 비싸고 가장 늦다

## 18. HA 구성 시 컴포넌트별 메모리 (2026-09-05)

§17 의 등급대로 **전부** HA 로 만들면 얼마가 드는가. 같은 생성기가 계산한다.

```
python3 scripts/ha-verification/ha-classify.py --cost --md
```

목표 복제본은 등급 기본값(R 2 · C 3 · S 2 · L 2)에 이름별 예외를 덮어쓴다 —
MinIO 4(erasure), ClickHouse 2, Keycloak 2, Redis 1(Sentinel 미채택) 등.
**HA 를 구성해야 비로소 생기는 워크로드**(CNPG 오퍼레이터 · ClickHouse Keeper ·
HDFS JournalNode·ZKFC)는 인벤토리에 없으므로 스크립트에 따로 적어 두었다.

### 18-1. 결론부터 — 전면 적용은 불가능하다

```
등급별 증가분: C 20.45Gi · L 0.52Gi · R 13.64Gi · S 2.31Gi
비-DaemonSet 증가분 합계  36.92 GiB
DaemonSet 노드당          0.91 GiB  → 3노드면 2.73 GiB (지금보다 +1.82)
3노드 HA 전면 적용 시 총 증가  38.74 GiB
```

**현재 requests 38.0 GiB + 증가 38.74 = 약 77 GiB.** 가용은 47.6 GiB 다(§10-1-b).
§12 의 "완전 HA 56.28" 은 A급 3종과 B급 11종만 계산한 값이었다 — **전 컴포넌트로
넓히면 그보다 훨씬 크다.**

즉 **HA 는 전부/전무가 아니라 고르는 일**이다. 아래가 그 근거다.

### 18-2. 묶음별 누적 비용

| 묶음 | 내용 | 증가분 | 누적 |
|---|---|---:|---:|
| **1. 플랫폼 필수** | coredns 70 · istiod 256 · ingress 128 · waypoint 128 | 0.57 GiB | 0.57 |
| **2. 리더 선출 13종** | 오퍼레이터·컨트롤러 전부 | 0.52 | 1.09 |
| **3. Alertmanager 3중** | gossip 클러스터 — 설정 한 줄 | 0.13 | 1.22 |
| **4. 과금 경로(무상태)** | openmeter-api + 워커 4종 | 0.94 | 2.16 |
| **5. 과금 원장** | postgresql 3 + clickhouse 2 + Keeper 3 + CNPG | 2.87 | 5.03 |
| 6. 관측성 | prometheus 2 · logstash 2 · kibana 2 | 2.75 | 7.78 |
| 7. 나머지 DB | mariadb·mongodb 3중 | 2.00 | 9.78 |
| 8. Kafka·ES 3중 | | 7.00 | 16.78 |
| 9. MinIO 분산 4 | S급 6종의 선행 조건 | 1.88 | 18.66 |
| 10. 그 외 전부 | 레이크하우스·거버넌스·OpenReplay 17종 등 | 20.08 | **38.74** |

**1~5 가 합쳐 5.03 GiB 다.** 여기까지가 실익 대비 값이 가장 좋은 구간이고,
§15-3 의 자리 만들기(requests 정정 −6 GiB)만 해도 들어간다.

6번부터는 다중 노드가 있어야 의미가 산다 — 단일 노드에서 Prometheus 2대는
같은 커널 위에 있으므로 §15-2 의 "옮겨가지 않는 것" 이다.

### 18-3. 곁가지 발견 — requests 가 아예 없는 것들

비용을 계산하다 드러났다. **파드당 0Mi** 로 잡히는 컴포넌트가 있다.

```
cert-manager · cert-manager-cainjector · cert-manager-webhook
cilium-operator · local-path-provisioner · trivy-operator · policy-reporter
```

메모리 requests 가 **설정돼 있지 않다.** 전부 오퍼레이터 계층
(`local/install-operators.sh` 가 Helm 으로 렌더한 것)이라 Kustomize
`require-resources` 정책의 적용 범위 밖이다.

requests 가 없으면 **BestEffort QoS** 가 되어 **메모리 압박 시 가장 먼저
축출된다.** `local-path-provisioner` 가 축출되면 새 PVC 가 묶이지 않고,
`cert-manager` 가 축출되면 인증서 갱신이 멈춘다. HA 와 별개로 고쳐야 한다.

### 18-5. 메모리를 키우면 다음 병목은 무엇인가

"메모리가 256 GB 면 넉넉한가" 라는 물음에 답하려면 **메모리 말고 무엇이
먼저 걸리는지**를 봐야 한다. 같은 생성기의 `--limits` 가 센다.

```
python3 scripts/ha-verification/ha-classify.py --limits

파드 수 (DaemonSet·CronJob 제외)
  현재 101  →  HA 전면 210
  + DaemonSet 8종 × 3노드 = 24
  합계 234 파드 / 3노드 = 노드당 78   (k3s 기본 상한 110)

CPU requests
  현재 17.1 코어  →  HA 전면 35.7 코어  (+ DaemonSet 0.5 × 3노드)
  합계 37.1 코어
```

| 자원 | HA 전면 필요 | 이 호스트 | 판정 |
|---|---:|---|---|
| 메모리 | 약 98 GiB(워크로드 77 + 노드 오버헤드 + Windows·L0 랩) | 63.4 GiB | ❌ 현재 · ✅ **256 GB 면 38%** |
| 파드 | 234 (노드당 78) | 상한 110/노드 | ✅ 여유 |
| **CPU** | **37.1 코어 requests** | **물리 24 코어** | ⚠ **아래 참조** |
| 디스크 용량 | 116 GB × 복제 배수 | 1.8 TB(여유 1.35 TB) | ✅ 여유 |
| **디스크 I/O** | 복제본 수에 비례 | **NVMe 1장** | ⚠ **측정 필요** |

#### CPU — 스케줄은 통과하나 requests 가 과대하다

requests 37.1 코어가 물리 24 코어를 넘는다. 그러나 **CPU 는 메모리와 달리
오버커밋이 정상**이고 H1(동적 메모리 금지)의 제약도 받지 않는다(§12-4).
3노드에 각각 24 vCPU 를 주면 allocatable 이 72 코어가 되어 스케줄은 통과한다.
**VM 은 물리 코어를 시분할로 공유한다** — 메모리처럼 잘라 나누는 것이 아니다.

그리고 **실사용은 1.5 코어(6%)** 다. requests 17.1 대 실사용 1.5 — 즉 지금도
과대 산정이고, HA 로 늘려도 실제 소모는 그만큼 늘지 않는다.

#### 그래서 다음 병목은 디스크 I/O 일 가능성이 높다

메모리를 키우면 남는 것은 **물리 NVMe 한 장**이다. HA 는 쓰기를 곱한다 —
etcd 3중화 · PostgreSQL 스트리밍 복제 · Kafka RF 2 이상 · ES 복제본 ·
ClickHouse 복제본이 **전부 같은 디스크**로 간다. §11-1 이 지적한 etcd fsync
문제가 여기서 더 커진다.

**단 이것은 아직 측정하지 않았다.** 지금 클러스터는 HA 구성이 아니라
곱해질 쓰기가 없다. 메모리를 늘려 HA 를 세우게 되면 `iostat`·etcd 의
`backend_commit_duration_seconds` 로 먼저 확인할 것 — 추정을 단정으로 적지
않는다(§8-36 의 교훈).

#### 그리고 256 GB 로도 바뀌지 않는 것

§11-0 이 범위 밖으로 둔 것들이다 — **물리 디스크·호스트·전원 장애.**
메모리를 아무리 키워도 물리 호스트가 한 대인 사실은 그대로다. 늘어난
메모리가 사 주는 것은 **더 많은 노드와 더 완전한 HA 예행**이지 내구성이 아니다.

### 18-4. 전체 표

| 등급 | 컴포넌트 | 파드당 | 현재 | 목표 | **증가분** | 비고 |
|:-:|---|---:|:-:|:-:|---:|---|
| C | elasticsearch-es-default | 2048Mi | 1 | 3 | **+4096Mi** |  |
| C | kafka | 1536Mi | 1 | 3 | **+3072Mi** |  |
| C | postgresql | 1024Mi | 1 | 3 | **+2048Mi** |  |
| C | minio | 640Mi | 1 | 4 | **+1920Mi** | 분산 모드는 엔드포인트 4개 이상 |
| R | logstash | 1536Mi | 1 | 2 | **+1536Mi** |  |
| C | wazuh-indexer | 768Mi | 1 | 3 | **+1536Mi** |  |
| C | mariadb | 512Mi | 1 | 3 | **+1024Mi** |  |
| C | mongodb | 512Mi | 1 | 3 | **+1024Mi** |  |
| C | solr | 512Mi | 1 | 3 | **+1024Mi** |  |
| S | loki | 1024Mi | 1 | 2 | **+1024Mi** |  |
| R | hive-metastore | 768Mi | 1 | 2 | **+768Mi** |  |
| R | kibana-kb | 768Mi | 1 | 2 | **+768Mi** |  |
| C | hadoop-journalnode (신규) | 256Mi | 0 | 3 | **+768Mi** | NameNode HA 의 편집 로그 정족수 |
| R | defectdojo-django | 640Mi | 1 | 2 | **+640Mi** |  |
| R | hadoop-datanode | 640Mi | 1 | 2 | **+640Mi** |  |
| R | hive-server | 640Mi | 1 | 2 | **+640Mi** |  |
| R | ranger-admin | 640Mi | 1 | 2 | **+640Mi** |  |
| C | keycloak | 640Mi | 1 | 2 | **+640Mi** | 상태가 PG 에 있어 2로 충분 |
| S | dependency-track-apiserver | 640Mi | 1 | 2 | **+640Mi** |  |
| R | hbase-regionserver | 512Mi | 1 | 2 | **+512Mi** |  |
| R | prometheus | 512Mi | 1 | 2 | **+512Mi** | HA 쌍. 데이터가 이중으로 쌓인다 |
| C | clickhouse | 512Mi | 1 | 2 | **+512Mi** | 복제본 2 + Keeper 3(아래 신규 항목) |
| C | hadoop-namenode | 512Mi | 1 | 2 | **+512Mi** | active + standby (JournalNode 는 아래 신규 항목) |
| C | zookeeper | 256Mi | 1 | 3 | **+512Mi** |  |
| C | hbase-master | 448Mi | 1 | 2 | **+448Mi** | standby 1개면 족하다 |
| C | clickhouse-keeper (신규) | 128Mi | 0 | 3 | **+384Mi** | ReplicatedMergeTree 의 조정자 |
| R | defectdojo-celery-worker | 320Mi | 1 | 2 | **+320Mi** |  |
| R | knox | 320Mi | 1 | 2 | **+320Mi** |  |
| C | wazuh-manager | 320Mi | 1 | 2 | **+320Mi** | master + worker |
| R | istiod `istio-system` | 256Mi | 1 | 2 | **+256Mi** |  |
| R | admin | 256Mi | 1 | 2 | **+256Mi** |  |
| R | akhq | 256Mi | 1 | 2 | **+256Mi** |  |
| R | api-openreplay | 256Mi | 1 | 2 | **+256Mi** |  |
| R | apicurio-registry | 256Mi | 1 | 2 | **+256Mi** |  |
| R | assist-openreplay | 256Mi | 1 | 2 | **+256Mi** |  |
| R | chalice-openreplay | 256Mi | 1 | 2 | **+256Mi** |  |
| R | cmmn-api | 256Mi | 1 | 2 | **+256Mi** |  |
| R | glitchtip-web | 256Mi | 1 | 2 | **+256Mi** |  |
| R | glitchtip-worker | 256Mi | 1 | 2 | **+256Mi** |  |
| R | spot-openreplay | 256Mi | 1 | 2 | **+256Mi** |  |
| C | ds389 | 256Mi | 1 | 2 | **+256Mi** | multi-supplier 2 |
| C | vault | 128Mi | 1 | 3 | **+256Mi** |  |
| S | grafana | 256Mi | 1 | 2 | **+256Mi** |  |
| S | tempo | 256Mi | 1 | 2 | **+256Mi** |  |
| C | hadoop-zkfc (신규) | 128Mi | 0 | 2 | **+256Mi** | NameNode 자동 장애 전환 컨트롤러 |
| C | cnpg-operator (신규) | 200Mi | 0 | 1 | **+200Mi** | CloudNativePG 오퍼레이터 (§13-2) |
| R | kafka-bridge | 192Mi | 1 | 2 | **+192Mi** |  |
| R | openmeter-api | 192Mi | 1 | 2 | **+192Mi** |  |
| R | openmeter-balance-worker | 192Mi | 1 | 2 | **+192Mi** |  |
| R | openmeter-billing-worker | 192Mi | 1 | 2 | **+192Mi** |  |
| R | openmeter-notification-service | 192Mi | 1 | 2 | **+192Mi** |  |
| R | openmeter-sink-worker | 192Mi | 1 | 2 | **+192Mi** |  |
| R | otel-gateway | 192Mi | 1 | 2 | **+192Mi** |  |
| S | pyroscope | 192Mi | 1 | 2 | **+192Mi** |  |
| L | elastic-operator `elastic-system` | 150Mi | 1 | 2 | **+150Mi** |  |
| R | assets-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | canvases-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | db-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | ender-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | falcosidekick | 128Mi | 1 | 2 | **+128Mi** |  |
| R | frontend-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | http-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | images-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | ingress-istio | 128Mi | 1 | 2 | **+128Mi** |  |
| R | integrations-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | lam | 128Mi | 1 | 2 | **+128Mi** |  |
| R | nginx | 128Mi | 1 | 2 | **+128Mi** |  |
| R | sink-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | storage-openreplay | 128Mi | 1 | 2 | **+128Mi** |  |
| R | waypoint | 128Mi | 1 | 2 | **+128Mi** |  |
| C | alertmanager | 64Mi | 1 | 3 | **+128Mi** |  |
| L | kyverno-admission-controller `kyverno` | 128Mi | 1 | 2 | **+128Mi** |  |
| R | coredns `kube-system` | 70Mi | 1 | 2 | **+70Mi** |  |
| R | metrics-server `kube-system` | 70Mi | 1 | 2 | **+70Mi** |  |
| R | alerts-openreplay | 64Mi | 1 | 2 | **+64Mi** |  |
| R | apicurio-ui | 64Mi | 1 | 2 | **+64Mi** |  |
| R | defectdojo-nginx | 64Mi | 1 | 2 | **+64Mi** |  |
| R | dependency-track-frontend | 64Mi | 1 | 2 | **+64Mi** |  |
| R | heuristics-openreplay | 64Mi | 1 | 2 | **+64Mi** |  |
| R | kube-state-metrics | 64Mi | 1 | 2 | **+64Mi** |  |
| R | sourcemapreader-openreplay | 64Mi | 1 | 2 | **+64Mi** |  |
| L | kyverno-background-controller `kyverno` | 64Mi | 1 | 2 | **+64Mi** |  |
| L | kyverno-cleanup-controller `kyverno` | 64Mi | 1 | 2 | **+64Mi** |  |
| L | kyverno-reports-controller `kyverno` | 64Mi | 1 | 2 | **+64Mi** |  |
| L | tetragon-operator `tetragon` | 64Mi | 1 | 2 | **+64Mi** |  |
| L | cert-manager `cert-manager` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | cert-manager-cainjector `cert-manager` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | cert-manager-webhook `cert-manager` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | cilium-operator `kube-system` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | local-path-provisioner `kube-system` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | policy-reporter `policy-reporter` | 0Mi | 1 | 2 | **+0Mi** |  |
| L | trivy-operator `trivy-system` | 0Mi | 1 | 2 | **+0Mi** |  |

## 19. 메모리를 줄이는 법 — zram 은 이 문제를 못 푼다 (2026-09-05)

### 19-1. 먼저 — zram 과 스케줄 한계는 다른 문제다

§2 의 zram 설계는 잘 돌고 있다. 그런데 **부족의 종류가 다르다.**

```
allocatable   41.1 GiB      ← kubelet 이 MemTotal 에서 계산
requests      38.0 GiB (92%) ← 스케줄러가 보는 값
실사용        21.0 GiB      ← 파드 합계
zram          32G 중 DATA 7.1G → COMPR 1.9G
```

**스케줄링은 `requests` 로 한다.** 그 합이 `allocatable` 을 넘으면 파드가
`Pending` 이 되고, `allocatable` 은 **MemTotal 에서 나온다**. zram 은 스왑이지
MemTotal 이 아니다 — kubelet 은 스왑을 allocatable 로 세지 않는다.

> 즉 zram 이 막아 주는 것은 **실사용이 물리를 넘을 때의 OOM** 이고,
> 지금 걸리는 것은 **requests 가 allocatable 을 채운 것**이다. 두 벽은 다르고
> zram 은 앞의 벽만 민다. §14-3 에서 파드가 `Too many pods` 로 막힌 것과
> 같은 종류의 오해다 — 실제 여유는 있는데 장부상 자리가 없다.

### 19-2. 진짜 문제 — requests 의 45%가 여백이다

```
requests 38.0 GiB · 실사용 21.0 GiB · **낭비 17.0 GiB (45%)**
```

| 파드 | requests | 실사용 | 여백 |
|---|---:|---:|---:|
| `safeline` | 2368Mi | 266Mi | **2102Mi** |
| `trino-0` | 2048 | 823 | 1225 |
| `loki-0` | 1024 | 177 | 847 |
| `kafka-0` | 1536 | 704 | 832 |
| `postgresql-0` | 1024 | 349 | 675 |
| `minio-0` | 640 | 101 | 539 |
| `mariadb-0` | 512 | 104 | 408 |
| `elasticsearch-es-default-0` | 2048 | 1669 | 379 |

**ES 만 여백이 작다**(18%) — 실제로 쓰고 있다는 뜻이다. 나머지는 대부분
기본 권장값을 그대로 둔 것이고, `DEPLOYMENT.md §6` 머리말이 이미 그렇게
적고 있다: *"v1 매니페스트에는 리소스 정의가 없고 신규 스택은 각 프로젝트
기본 권장값을 사용했다. 실측 기반 재산정이 선행되어야 한다(ADR-058)."*

### 19-3. 줄이는 방법 — 효과 순

| | 레버 | 회수(추정) | 성격 |
|:-:|---|---|---|
| **①** | **requests 실측 정정** | **6.5~10.7 GiB** | 설정만. 전례 있음(2026-09-03, 6.7 GiB 회수). 산출은 §19-5 |
| **②** | **JVM 힙 명시** | 큼 | 12종 중 **9종이 미설정**(실측). 레포가 prod 산정에서 −48 GiB 로 잡은 레버다(§6-2 단계 2) |
| **③** | **프로파일 분리**(Kustomize Component) | **매우 큼** | 항상 다 띄울 필요가 없다 |
| ④ | 중복 스택 정리 | 중간 | 검토 필요 |
| ⑤ | zram ZSTD 전환 | 실사용만 | 커널 빌드. §7 에서 이미 보류 |

#### ① requests 정정 — ★ 다만 지금 값으로 깎지 말 것

위 표의 "실사용" 은 **한 시점의 유휴 값**이다. Trino·Kafka·ES 는 부하가
걸리면 오른다. `DEPLOYMENT.md §6-2` 가 못박아 둔 그대로다:

> **3·4단계는 클러스터를 실제로 띄우고 최소 2주 측정한 뒤에만 적용한다.
> 메모리는 CPU와 달리 throttle이 아니라 OOMKill이다.**

도구는 이미 갖춰져 있다 — **KRR**(Prometheus 기반, 별도 컨트롤러 불필요).
Prometheus 가 이미 돌고 있으므로 추가 비용이 0이다(§6-3). 피크 기준
백분위로 산정하고 여유를 얹는다.

#### ② JVM 힙 — 미설정 9종

```
미설정  trino · kafka · elasticsearch · ranger-admin · knox · jenkins ·
        livy · spark-connect · apicurio-registry · akhq
설정됨  solr(Xmx512m) · zookeeper(Xmx256m) · hbase · hive-metastore
```

힙을 명시하지 않으면 JVM 이 컨테이너 한도의 일정 비율을 잡아 **RSS 가 한도
근처까지 자란다.** 그러면 requests 를 낮출 수가 없다 — 낮추면 OOMKill 이다.
**힙을 먼저 고정해야 ①이 안전해진다.** 순서가 ② → ① 이다.

#### ③ 프로파일 분리 — 가장 큰 레버

`CLAUDE.md` 가 이미 적고 있다: *"64 GB에서는 Kustomize Component 기반
프로파일 전환이 필요"*. 지금은 전부를 항상 띄운다.

| 묶음 | requests | 언제 필요한가 |
|---|---:|---|
| OpenReplay 17종 | ~2.6 GiB | 세션 리플레이를 볼 때만 |
| lakehouse-v1(HDFS·HBase·Hive·ZK) | ~3.2 | v1 호환 검증할 때만 |
| SafeLine 3종 · Caldera | ~2.8 | 보안 시연할 때만 |
| DefectDojo 4종 · Dependency-Track 2종 | ~2.0 | 취약점 관리 볼 때만 |
| **합계** | **~10.6 GiB** | |

**HA 예행(§15)에 이 넷은 필요 없다.** 프로파일로 빼면 §15-3 의 자리 문제가
requests 정정 없이도 풀린다 — 그리고 파드 40여 개가 함께 빠져 **파드 상한
문제도 같이 해소된다**(§14-3).

#### ④ 중복 스택 — 검토 대상

단정하지 않고 항목만 남긴다. `elasticsearch`(2048Mi)와 `wazuh-indexer`
(768Mi)는 둘 다 Lucene 계열 검색 엔진이고, `defectdojo`와
`dependency-track`은 둘 다 취약점 관리다. 통합 가능 여부는 각각의 기능
의존성을 봐야 하므로 **여기서 결론 내지 않는다.**

### 19-5. 레버별 실행 방법

#### ① requests 실측 정정 — 6.5~10.7 GiB

**무엇을 하나.** 예약(`requests`)을 실측 기반으로 다시 잡는다. 스케줄러는
`requests` 로만 판단하므로, 예약 38.0 · 실사용 21.0 이면 **17 GiB 가 장부에만
잡혀 있다.**

**전례가 있고 방법도 남아 있다.** 2026-09-03 에 한 번 했다 —
`overlays/local/patches/requests-local.yaml`(53개 워크로드). 그 파일 머리말이
기준을 적어 두었다:

- Burstable 은 **실사용의 1.3~2배**. 기동 피크가 유휴보다 높은 JVM 은 넉넉히
- **Guaranteed 8종은 건드리지 않는다** — `requests == limits` 불변식이
  `qos-guaranteed.yaml` 에 있고 한쪽만 바꾸면 그 성질이 깨진다(§20-2)
- `istiod`·`ztunnel` 은 istioctl 이 설치하므로 kustomize 밖이다

**★ 순수 삭감이 아니다.** 그때 5건은 **예약이 실사용보다 적어서 올렸다** —
safeline(−804Mi) · logstash(−333) · loki(−288) · spark-history(−195).
requests 를 넘겨 쓰는 파드는 **압박 시 가장 먼저 축출된다.** 과대 예약보다
이쪽이 위험하다.

**★ 함정 — `request > limit` 이면 파드가 조용히 사라진다.** CrashLoop 도
Pending 도 아니고 `get pods` 에 아무것도 안 나온다. 같은 파일이 기록해 둔
실측이다.

**회수량 산출**(§19-3 의 "10~14 GiB" 를 여기서 정정한다):

```
실사용 21.0 GiB × 1.3 = 27.3   →  회수 10.7 GiB (공격적)
실사용 21.0 GiB × 1.5 = 31.5   →  회수  6.5 GiB (보수적)
```

앞서 적은 10~14 는 레포 자신의 기준(1.3~2배)을 적용하지 않은 낙관값이었다.

**그리고 정정 이후 들어온 8종이 패치 밖이다** — `openmeter-*` 5종 ·
`alertmanager` · `kube-state-metrics` · `falco`. 다음 정정에 포함할 것.

**★ 다만 지금 값으로 깎지 말 것**(§19-3 재확인). 표의 실사용은 유휴 한
시점이다. `DEPLOYMENT.md §6-2` 가 "최소 2주 측정 뒤에만" 이라 못박았고,
**메모리는 throttle 이 아니라 OOMKill** 이다. KRR(Prometheus 기반, 이미 있는
Prometheus 를 그대로 쓴다)로 백분위를 뽑는 것이 옳다.

#### ② JVM 힙 명시 — ①의 **선행 조건**

**왜 ①보다 먼저인가.** 힙을 명시하지 않으면 JVM 은 컨테이너 **한도**를 기준으로
힙 상한을 잡고, GC 가 돌기 전까지 RSS 가 그쪽으로 자란다. 그러면 ①이 재는
"실사용" 이 **실제 필요량이 아니라 한도의 함수**가 된다 — 기준선 자체가
흔들린다. 힙을 고정해야 실사용이 의미를 갖는다.

**미설정 9종**(실측): `trino` · `kafka` · `elasticsearch` · `ranger-admin` ·
`knox` · `jenkins` · `livy` · `spark-connect` · `apicurio-registry` · `akhq`
설정됨: `solr`(Xmx512m) · `zookeeper`(Xmx256m) · `hbase` · `hive-metastore`

**방법.** 각 워크로드의 env 에 `JAVA_OPTS`/`JAVA_TOOL_OPTIONS` 로 `-Xmx` 를
준다. 대략 **limits 의 50~70%** — 힙 밖에도 메타스페이스·스레드 스택·
다이렉트 버퍼가 있다. ES 는 예외로 자체 `jvm.options` 규약이 있고 ECK 가
관리하므로 CR 쪽에서 준다.

#### ③ 프로파일 분리 — ~10.6 GiB · 위험이 가장 낮다

**무엇을 하나.** 항상 켜 둘 필요가 없는 묶음을 Kustomize **Component** 로
빼서, 필요할 때만 오버레이에 포함한다.

```
kubernetes/components/openreplay/kustomization.yaml     (kind: Component)
kubernetes/components/lakehouse-v1/
kubernetes/components/security-demo/
kubernetes/components/vuln-mgmt/

overlays/local/kustomization.yaml:
  components:
    - ../../components/openreplay   # 필요할 때만 주석 해제
```

**레포에 Component 가 하나도 없다**(실측) — 신설이다. `CLAUDE.md` 는 이미
*"64 GB에서는 Kustomize Component 기반 프로파일 전환이 필요"* 라 적고 있다.

| 묶음 | 현재 requests | HA 시 | 파드 |
|---|---:|---:|---:|
| OpenReplay 17종 | ~2.6 GiB | ~5.2 | 17 |
| lakehouse-v1(HDFS·HBase·Hive·ZK) | ~3.2 | ~6.5 | 8 |
| SafeLine 3종 · Caldera | ~2.8 | ~2.8 | 4 |
| DefectDojo 4종 · Dependency-Track 2종 | ~2.0 | ~4.0 | 6 |
| **합계** | **~10.6** | **~18.5** | **35** |

**HA 예행(§15)에 이 넷은 필요 없다.** 그리고 파드 35개가 함께 빠져
§14-3 의 파드 상한(109/110)도 같이 풀린다 — **한 조치로 두 제약이 풀리는
유일한 레버**다.

**위험이 낮은 이유** — 삭제가 아니라 **오버레이에서 빼는 것**이다. 매니페스트는
그대로 남고 한 줄로 되돌린다. ①·②처럼 OOMKill 위험이 없다.

#### ③-1. 프로파일 전환이 실제로 뜻하는 것

**그 묶음의 파드가 아예 없다.** 렌더 결과에서 워크로드가 빠지므로 존재하지
않는다 — 축소(replicas 0)가 아니라 **미배포**다. 다시 켜려면 오버레이에서
한 줄을 되살리고 재적용한다.

| | 끄면 | 켜면 |
|---|---|---|
| 워크로드 | 없다 | 다시 뜬다(이미지 재적재·부트스트랩 시간 필요) |
| **PVC(volumeClaimTemplates)** | **남는다** | 같은 볼륨을 다시 문다 |
| 기능 | 못 쓴다 | 쓴다 |

PVC 가 남는 근거는 둘이다 — ⓐ `persistentVolumeClaimRetentionPolicy` 가
레포 어디에도 없어 기본값 **Retain** 이고, ⓑ `volumeClaimTemplates` 로 생기는
PVC 는 Git 매니페스트에 없어 **ArgoCD 가 추적하지 않으므로 prune 대상이
아니다.** 즉 데이터는 살아남는다.

#### ③-2. ★ 그런데 예외가 셋 있다 — 직접 선언된 PVC

```
defectdojo-media        4Gi   base/security/defectdojo/defectdojo-service.yaml
dependency-track-data   8Gi   base/security/dependency-track/...-service.yaml
safeline-data           4Gi   base/security/safeline/safeline-service.yaml
```

이 셋은 **매니페스트에 직접 선언된 PVC** 라 Git 에 있고, ArgoCD 가 추적한다.
그리고 dev·prod Application 이 **`prune: true`** 다(실측). 이 셋이 속한
묶음(vuln-mgmt · security-demo)을 Component 로 빼면 **PVC 가 함께 지워져
데이터가 사라진다.**

> **설계 규칙 — PVC 는 Component 에 넣지 않는다.** 워크로드(Deployment·
> StatefulSet·Service)만 옮기고 PVC 선언은 base 에 남긴다. 4~8Gi 짜리
> 빈 볼륨이 놀지만, 데이터가 사라지는 것보다 낫다.

#### ③-3. 의존성 확인 결과

| 묶음 | 밖에서 참조하는가 |
|---|---|
| **lakehouse-v1**(ZK·HDFS·HBase·hive-server) | **없다** — `lakehouse-local` 밖에서 참조 0건. 깨끗하게 뺄 수 있다 |
| **OpenReplay 17종** | 워크로드 참조는 없으나 **base 에 흔적이 있다** — `postgres-bootstrap`(DB 생성) · `clickhouse-configmap`·`-statefulset` · `database-netpol`. 남아도 무해하다(쓰지 않는 DB, 매칭되지 않는 allow 규칙) |
| SafeLine·Caldera · DefectDojo·Dependency-Track | 위 PVC 예외를 빼면 독립 |

#### ③-4. 대가 — 검증 커버리지가 준다

이것이 프로파일 전환의 진짜 비용이다. §8-64 가 남긴 교훈과 같은 자리다:

> **죽어 있는 구성요소는 그 하류 전체를 검증되지 않은 상태로 만든다.**

OpenReplay 를 늘 꺼 두면 그 17종에 대한 Kyverno 정책·NetworkPolicy·
AuthorizationPolicy·ambient 편입이 **한 번도 실행되지 않는다.** Falco 를
살리자 401·정책 누락·소켓 오설정 셋이 한꺼번에 나온 것이 바로 그 형태였다.

완화책은 **주기적으로 전부 켜서 한 번 돌리는 것**이다 — 상시가 아니라
검증 회차로. 그때는 메모리가 필요하므로 §15-3 의 자리 만들기가 함께 있어야
한다. "끄고 잊는다" 가 아니라 "평소엔 끄고 정기적으로 켠다" 로 운용할 것.

#### ④ 중복 스택 — 검토만

`elasticsearch`(2048Mi)와 `wazuh-indexer`(768Mi)는 둘 다 Lucene 계열이고,
`defectdojo`와 `dependency-track`은 둘 다 취약점 관리다. 통합 가능 여부는
각각의 기능 의존성을 봐야 한다 — **여기서 결론 내지 않는다.**

#### ⑤ zram ZSTD — 실사용만, 그리고 보류

`ZRAM_BACKEND_ZSTD` 로 압축률이 2.2 → 3.2 가 된다(§7). 그러나 ⓐ **커널을
직접 빌드해야 하고**(Microsoft config 문제라 `wsl --update` 로 안 된다)
ⓑ 커스텀 커널을 고정하면 보안 패치가 끊기며 ⓒ **무엇보다 requests 를 낮추지
않는다**(§20-6). §7 이 이미 보류로 정했다.

### 19-6. 순서와 이유

```
③ 프로파일 분리   위험 0 · 즉효 · 파드까지 회수     →  먼저
② JVM 힙 명시     ①의 기준선을 고정한다             →  다음
① requests 정정   KRR 2주 측정 후                   →  마지막
```

**①을 먼저 하면 안 되는 이유**가 ②에 있고, ③은 둘과 독립이라 지금 바로
할 수 있다. 셋 다 하드웨어를 사지 않는다.

### 19-4. 권하는 순서

```
③ 프로파일 분리        ~10.6 GiB  · 설정만 · 파드 40여 개도 함께 회수
② JVM 힙 명시 9종       ①의 안전 조건
① KRR 2주 측정 → 정정  10~14 GiB
```

**③만 해도 §15-3 의 두 제약(파드·메모리)이 동시에 풀린다.** 그리고 셋 다
하드웨어를 사지 않는다.

## 20. Hyper-V 풀 HA + zram — 컴포넌트별 메모리 표 (2026-09-05)

§18 은 "증가분" 만 냈다. 여기서는 **HA 구성 후의 절대값**을 컴포넌트별로
내고, zram 이 실제로 어디에 닿는지를 함께 표시한다.

### 20-1. 총계

> **★ 첫 판은 불완전했다.** CronJob 15종과 requests 가 0인 컴포넌트 9종을
> 건너뛰고 "전체" 라고 적었다. 값이 0이거나 성격이 달라도 **행은 남기고
> 그렇게 표시하는 것**이 맞다 — §16→§17 에서 이미 한 번 같은 실수를 했다.
> 아래는 **128행(기존 124 + 신규 4) 전부**다.

```
행 수 128 (신규 4 포함)  · BestEffort(requests 없음) 9 종
상시 비-DaemonSet   requests 74.0 GiB · limits 161.3 GiB
DaemonSet 노드당    requests 932Mi · limits 2688Mi  → 3노드 2.7 / 7.9 GiB
CronJob 전부 동시   requests 1.9 GiB · limits 6.3 GiB  (실제로는 겹치지 않는다)
────────────────────────────────────────────────────────────────────────
3노드 상시 합계     requests 76.7 GiB · limits 169.2 GiB
  + CronJob 최악    requests 78.7 GiB
```

```
3노드 VM 메모리 = requests 76.7 + 노드 예약 1.9×3 = 82.4 GiB
호스트 소요      = 82.4 + Windows 7 + L0 랩 8.8 = 98.2 GiB
```

현재 호스트 63.4 GiB 로는 불가하고 **256 GB 면 38%** 다(§18-5).

**CronJob 15종은 1.9 GiB** 지만 상시가 아니다 — `concurrencyPolicy: Forbid`
가 14종에 걸려 있어 같은 Job 이 겹치지 않고, 서로 다른 Job 이 동시에 뜨는
경우만 더해진다. 최악(전부 동시)을 더하면 78.7 GiB 다.

### 20-2. ★ zram 이 닿지 않는 곳 — Guaranteed 8종

§2-2 가 설계로 적어 둔 성질이 여기서 그대로 작동한다.

> **`LimitedSwap` 은 Burstable QoS 파드에만 스왑을 준다.
> Guaranteed(`requests == limits`)는 스왑을 0 받는다.**

실측 QoS 분포는 **Burstable 96 · Guaranteed 8** 이다. 그런데 그 8종이
하필 가장 큰 것들이다.

| Guaranteed(스왑 불가) | 파드당 | HA 복제본 | HA requests |
|---|---:|:-:|---:|
| `elasticsearch-es-default` | 2048Mi | 3 | 6144Mi |
| `kafka` | 1536 | 3 | 4608 |
| `postgresql` | 1024 | 3 | 3072 |
| `minio` | 640 | 4 | 2560 |
| `trino` | 2048 | 1 | 2048 |
| `mariadb` | 512 | 3 | 1536 |
| `mongodb` | 512 | 3 | 1536 |
| **합계** | | | **21.25 GiB** |

**76.7 GiB 중 21.25 GiB(28%)는 zram 이 손댈 수 없는 실 RAM 이다.**
나머지 55.5 GiB 만 Burstable 이고, 그쪽의 `limits − requests` 여유가
zram 으로 흘러갈 수 있는 몫이다.

> 이것은 결함이 아니라 **의도된 스위치**다 — 데이터 저장소를 스왑으로
> 밀어내면 지연이 예측 불가해진다. 다만 **"zram 이 있으니 메모리가 덜
> 든다" 는 계산이 큰 쪽에는 적용되지 않는다**는 것을 알고 써야 한다.

### 20-3. 세 층으로 읽기

| 층 | 값 | 뜻 |
|---|---:|---|
| **requests** | **76.7 GiB** | 스케줄러가 보는 값. **VM 메모리는 이것보다 커야 한다** |
| limits | 169.2 GiB | 오버커밋. Burstable 의 초과분이 zram 으로 간다 |
| 현재 실사용 기준 | 39.0 GiB | 지금 실사용을 HA 복제본 수로 곱한 값 |

**requests 76.7 대 실사용 39.0** — §19 에서 본 45% 여백이 HA 로 늘리면
그대로 두 배가 된다. §19-3 의 레버(프로파일 분리 · JVM 힙 · requests 정정)를
먼저 쓰면 이 표 전체가 내려간다.

### 20-4. zram 설정 권고

```
노드당 VM 메모리   27.5 GiB   (82.4 / 3)
zram disksize      20 GiB     (§2 의 비율 32G/43GiB ≈ 74% 를 적용)
압축률 실측        3.3~3.7x   (§8-26 3.31x · 현재 7.1G→1.9G = 3.7x)
최악 물리 점유     약 6 GiB
```

zram 이 실제로 하는 일은 **Burstable 96종의 순간 초과를 흡수해 OOMKill 을
막는 것**이고, 그 덕에 §19-3 의 ① requests 정정을 더 과감하게 할 수 있다.
**zram 의 값어치는 스케줄 공간이 아니라 정정의 안전마진이다.**

### 20-6. Hyper-V 에서 zram 을 써도 상시 합계는 같다 — 실측 증명

자주 나오는 물음이라 못박아 둔다. **같다.** 그리고 그 이유는 하이퍼바이저와
무관하다 — 지금 WSL2 노드에서 그대로 증명된다.

```
MemTotal            44,139 MiB
SwapTotal           40,959 MiB      ← zram 32G + 디스크 스왑 8G
MemTotal + Swap     85,099 MiB

kubelet capacity    44,139 MiB      ← **MemTotal 과 정확히 같다**
kubelet allocatable 42,091 MiB      ← capacity − 예약
```

**스왑 40.9 GiB 가 있는데 kubelet 은 한 바이트도 세지 않는다.** 게다가 지금
이 순간 스왑을 **8.4 GiB 실제로 쓰고 있다**(zram DATA 7.5G → COMPR 2.1G).
쓰고 있는데도 스케줄 가능 공간은 늘지 않는다.

| | 값 | zram 영향 |
|---|---|---|
| `capacity.memory` | MemTotal 그대로 | **없음** |
| `allocatable.memory` | capacity − 예약 | **없음** |
| 상시 합계(requests 76.7 GiB) | allocatable 안에 들어가야 한다 | **없음** |
| 실사용이 물리를 넘을 때 | zram 이 흡수 → OOM 회피 | **여기만** |

Hyper-V 로 옮겨도 구조가 같다. 게스트의 zram 은 게스트 안의 스왑이고,
VM 메모리(H1 로 정적)가 곧 MemTotal 이다. **VM 메모리 하한은 zram 유무와
무관하게 `requests + 예약` 이 정한다.**

```
3노드 VM 하한 = 76.7(requests) + 1.9×3(예약) = 82.4 GiB   ← zram 있어도 동일
```

#### 그럼 zram 은 무엇을 바꾸는가 — 간접적으로 바꾼다

§19-3 의 ① requests 정정을 **안전하게** 만든다. 정정은 본질적으로
"여유를 깎는" 일이고, 깎으면 순간 초과 시 OOMKill 위험이 오른다.
zram 이 그 순간을 받아 준다 — 단 **Burstable 에 한해서**다(§20-2).

| 시나리오 | 상시 합계 | 비고 |
|---|---:|---|
| 지금 값 그대로 3배 | **76.7 GiB** | 이 문서의 기준값 |
| 실사용 기준(참고) | 39.0 | 그대로 쓰면 안 된다 — 유휴 한 시점이다 |
| **정정 후(추정)** | **50~55** | KRR p95 + 여유. zram 이 뒷받침 |
| 정정 + 프로파일 분리(§19-3 ③) | **40~45** | OpenReplay·lakehouse-v1 등 제외 |

**즉 zram 은 76.7 을 직접 낮추지 않고, 76.7 을 50 대로 낮추는 작업의
안전마진이 된다.** 순서가 뒤바뀌면 안 된다 — zram 을 믿고 requests 를 먼저
깎으면 Guaranteed 8종(21.25 GiB)은 스왑을 못 받아 그대로 OOMKill 이다.

#### 게스트 쪽 확인 항목

Hyper-V 게스트(Ubuntu 24.04)에서 zram 을 쓰려면 `CONFIG_ZRAM` 이 있어야 한다.
WSL2 커널은 §1 에서 실측했으나 **Ubuntu 게스트는 아직 확인하지 않았다.**
이설 시 `modprobe zram && zramctl` 로 먼저 볼 것 — 표준 커널에는 있으나
확인하지 않은 것을 확인한 것처럼 적지 않는다(§8-36 의 교훈).

### 20-5. 전체 표 (128행)

`D` 는 노드당 1개이므로 `×N`, `J`(CronJob)는 상시가 아니므로 괄호로 적었다.
`BestEffort` 는 **requests 가 아예 없다**는 뜻이다(§18-3).

| 등급 | 컴포넌트 | 종류 | 파드당 req | 파드당 lim | 실사용 | QoS | HA 복제본 | **HA req** | HA lim |
|:-:|---|:-:|---:|---:|---:|:-:|:-:|---:|---:|
| C | `elasticsearch-es-default` | STS | 2048 | 2048 | 1667 | Guaranteed | 3 | **6144** | 6144 |
| C | `kafka` | STS | 1536 | 1536 | 410 | Guaranteed | 3 | **4608** | 4608 |
| C | `postgresql` | STS | 1024 | 1024 | 360 | Guaranteed | 3 | **3072** | 3072 |
| C | `minio` | STS | 640 | 640 | 101 | Guaranteed | 4 | **2560** | 2560 |
| C | `wazuh-indexer` | STS | 768 | 1536 | 681 | Burstable | 3 | **2304** | 4608 |
| C | `mariadb` | STS | 512 | 512 | 103 | Guaranteed | 3 | **1536** | 1536 |
| C | `mongodb` | STS | 512 | 512 | 252 | Guaranteed | 3 | **1536** | 1536 |
| C | `solr` | STS | 512 | 1024 | 290 | Burstable | 3 | **1536** | 3072 |
| C | `keycloak` | STS | 640 | 1536 | 477 | Burstable | 2 | **1280** | 3072 |
| C | `clickhouse` | STS | 512 | 2048 | 680 | Burstable | 2 | **1024** | 4096 |
| C | `hadoop-namenode` | STS | 512 | 1536 | 299 | Burstable | 2 | **1024** | 3072 |
| C | `hbase-master` | STS | 448 | 1280 | 205 | Burstable | 2 | **896** | 2560 |
| C | `zookeeper` | STS | 256 | 768 | 127 | Burstable | 3 | **768** | 2304 |
| C | `wazuh-manager` | STS | 320 | 1024 | 135 | Burstable | 2 | **640** | 2048 |
| C | `ds389` | STS | 256 | 512 | 15 | Burstable | 2 | **512** | 1024 |
| C | `vault` | STS | 128 | 512 | 58 | Burstable | 3 | **384** | 1536 |
| C | `alertmanager` | Dep | 64 | 192 | 20 | Burstable | 3 | **192** | 576 |
| S | `loki` | STS | 1024 | 3072 | 172 | Burstable | 2 | **2048** | 6144 |
| S | `dependency-track-apiserver` | Dep | 640 | 2048 | 343 | Burstable | 2 | **1280** | 4096 |
| S | `grafana` | Dep | 256 | 768 | 217 | Burstable | 2 | **512** | 1536 |
| S | `tempo` | STS | 256 | 768 | 28 | Burstable | 2 | **512** | 1536 |
| S | `pyroscope` | STS | 192 | 1536 | 88 | Burstable | 2 | **384** | 3072 |
| S | `redis` | STS | 256 | 256 | 32 | Guaranteed | 1 | **256** | 256 |
| R | `logstash` | STS | 1536 | 2048 | 1639 | Burstable | 2 | **3072** | 4096 |
| R | `kibana-kb` | Dep | 768 | 1536 | 972 | Burstable | 2 | **1536** | 3072 |
| R | `hive-metastore` | STS | 768 | 1280 | 382 | Burstable | 2 | **1536** | 2560 |
| R | `defectdojo-django` | Dep | 640 | 1536 | 411 | Burstable | 2 | **1280** | 3072 |
| R | `hadoop-datanode` | STS | 640 | 1536 | 308 | Burstable | 2 | **1280** | 3072 |
| R | `hive-server` | STS | 640 | 2560 | 477 | Burstable | 2 | **1280** | 5120 |
| R | `ranger-admin` | STS | 640 | 1536 | 671 | Burstable | 2 | **1280** | 3072 |
| R | `hbase-regionserver` | STS | 512 | 1536 | 266 | Burstable | 2 | **1024** | 3072 |
| R | `prometheus` | STS | 512 | 1536 | 435 | Burstable | 2 | **1024** | 3072 |
| R | `defectdojo-celery-worker` | Dep | 320 | 1280 | 74 | Burstable | 2 | **640** | 2560 |
| R | `knox` | Dep | 320 | 768 | 140 | Burstable | 2 | **640** | 1536 |
| R | `istiod` | Dep | 256 | 0 | 61 | Burstable | 2 | **512** | 0 |
| R | `api-openreplay` | Dep | 256 | 768 | 9 | Burstable | 2 | **512** | 1536 |
| R | `assist-openreplay` | Dep | 256 | 768 | 82 | Burstable | 2 | **512** | 1536 |
| R | `chalice-openreplay` | Dep | 256 | 768 | 56 | Burstable | 2 | **512** | 1536 |
| R | `glitchtip-web` | Dep | 256 | 768 | 205 | Burstable | 2 | **512** | 1536 |
| R | `glitchtip-worker` | Dep | 256 | 768 | 50 | Burstable | 2 | **512** | 1536 |
| R | `spot-openreplay` | Dep | 256 | 768 | 8 | Burstable | 2 | **512** | 1536 |
| R | `admin` | STS | 256 | 512 | 64 | Burstable | 2 | **512** | 1024 |
| R | `akhq` | STS | 256 | 768 | 103 | Burstable | 2 | **512** | 1536 |
| R | `apicurio-registry` | STS | 256 | 768 | 119 | Burstable | 2 | **512** | 1536 |
| R | `cmmn-api` | STS | 256 | 1024 | 724 | Burstable | 2 | **512** | 2048 |
| R | `kafka-bridge` | Dep | 192 | 512 | 117 | Burstable | 2 | **384** | 1024 |
| R | `openmeter-api` | Dep | 192 | 512 | 58 | Burstable | 2 | **384** | 1024 |
| R | `openmeter-balance-worker` | Dep | 192 | 512 | 31 | Burstable | 2 | **384** | 1024 |
| R | `openmeter-billing-worker` | Dep | 192 | 512 | 28 | Burstable | 2 | **384** | 1024 |
| R | `openmeter-notification-service` | Dep | 192 | 512 | 28 | Burstable | 2 | **384** | 1024 |
| R | `openmeter-sink-worker` | Dep | 192 | 512 | 31 | Burstable | 2 | **384** | 1024 |
| R | `otel-gateway` | Dep | 192 | 384 | 52 | Burstable | 2 | **384** | 768 |
| R | `assets-openreplay` | Dep | 128 | 384 | 13 | Burstable | 2 | **256** | 768 |
| R | `canvases-openreplay` | Dep | 128 | 384 | 7 | Burstable | 2 | **256** | 768 |
| R | `db-openreplay` | Dep | 128 | 384 | 7 | Burstable | 2 | **256** | 768 |
| R | `ender-openreplay` | Dep | 128 | 384 | 7 | Burstable | 2 | **256** | 768 |
| R | `falcosidekick` | Dep | 128 | 256 | 14 | Burstable | 2 | **256** | 512 |
| R | `frontend-openreplay` | Dep | 128 | 384 | 10 | Burstable | 2 | **256** | 768 |
| R | `http-openreplay` | Dep | 128 | 384 | 23 | Burstable | 2 | **256** | 768 |
| R | `images-openreplay` | Dep | 128 | 384 | 8 | Burstable | 2 | **256** | 768 |
| R | `ingress-istio` | Dep | 128 | 1024 | 38 | Burstable | 2 | **256** | 2048 |
| R | `integrations-openreplay` | Dep | 128 | 384 | 7 | Burstable | 2 | **256** | 768 |
| R | `lam` | Dep | 128 | 384 | 12 | Burstable | 2 | **256** | 768 |
| R | `nginx` | Dep | 128 | 256 | 9 | Burstable | 2 | **256** | 512 |
| R | `sink-openreplay` | Dep | 128 | 384 | 7 | Burstable | 2 | **256** | 768 |
| R | `storage-openreplay` | Dep | 128 | 384 | 12 | Burstable | 2 | **256** | 768 |
| R | `waypoint` | Dep | 128 | 1024 | 56 | Burstable | 2 | **256** | 2048 |
| R | `coredns` | Dep | 70 | 170 | 35 | Burstable | 2 | **140** | 340 |
| R | `metrics-server` | Dep | 70 | 0 | 42 | Burstable | 2 | **140** | 0 |
| R | `alerts-openreplay` | Dep | 64 | 192 | 28 | Burstable | 2 | **128** | 384 |
| R | `apicurio-ui` | Dep | 64 | 192 | 12 | Burstable | 2 | **128** | 384 |
| R | `defectdojo-nginx` | Dep | 64 | 192 | 7 | Burstable | 2 | **128** | 384 |
| R | `dependency-track-frontend` | Dep | 64 | 192 | 8 | Burstable | 2 | **128** | 384 |
| R | `heuristics-openreplay` | Dep | 64 | 192 | 16 | Burstable | 2 | **128** | 384 |
| R | `kube-state-metrics` | Dep | 64 | 192 | 18 | Burstable | 2 | **128** | 384 |
| R | `sourcemapreader-openreplay` | Dep | 64 | 192 | 31 | Burstable | 2 | **128** | 384 |
| L | `elastic-operator` | STS | 150 | 1024 | 57 | Burstable | 2 | **300** | 2048 |
| L | `kyverno-admission-controller` | Dep | 128 | 384 | 70 | Burstable | 2 | **256** | 768 |
| L | `kyverno-background-controller` | Dep | 64 | 128 | 37 | Burstable | 2 | **128** | 256 |
| L | `kyverno-cleanup-controller` | Dep | 64 | 128 | 39 | Burstable | 2 | **128** | 256 |
| L | `kyverno-reports-controller` | Dep | 64 | 128 | 63 | Burstable | 2 | **128** | 256 |
| L | `tetragon-operator` | Dep | 64 | 128 | 14 | Burstable | 2 | **128** | 256 |
| L | `cert-manager` | Dep | 0 | 0 | 38 | **BestEffort** | 2 | **0** | 0 |
| L | `cert-manager-cainjector` | Dep | 0 | 0 | 53 | **BestEffort** | 2 | **0** | 0 |
| L | `cert-manager-webhook` | Dep | 0 | 0 | 29 | **BestEffort** | 2 | **0** | 0 |
| L | `cilium-operator` | Dep | 0 | 0 | 71 | **BestEffort** | 2 | **0** | 0 |
| L | `local-path-provisioner` | Dep | 0 | 0 | 17 | **BestEffort** | 2 | **0** | 0 |
| L | `policy-reporter` | Dep | 0 | 0 | 54 | **BestEffort** | 2 | **0** | 0 |
| L | `trivy-operator` | Dep | 0 | 0 | 284 | **BestEffort** | 2 | **0** | 0 |
| D | `falco` | DS | 256 | 1024 | 230 | Burstable | 노드당 1 | **256×N** | 1024×N |
| D | `otel-agent` | DS | 192 | 640 | 91 | Burstable | 노드당 1 | **192×N** | 640×N |
| D | `ztunnel` | DS | 128 | 0 | 83 | Burstable | 노드당 1 | **128×N** | 0×N |
| D | `filebeat` | DS | 128 | 512 | 64 | Burstable | 노드당 1 | **128×N** | 512×N |
| D | `tetragon` | DS | 128 | 512 | 104 | Burstable | 노드당 1 | **128×N** | 512×N |
| D | `istio-cni-node` | DS | 100 | 0 | 81 | Burstable | 노드당 1 | **100×N** | 0×N |
| D | `cilium` | DS | 0 | 0 | 153 | **BestEffort** | 노드당 1 | **0×N** | 0×N |
| D | `cilium-envoy` | DS | 0 | 0 | 23 | **BestEffort** | 노드당 1 | **0×N** | 0×N |
| J | `kubescape-scan` | CJ | 384 | 1024 | — | Burstable | 실행 시에만 | **(384)** | (1024) |
| J | `trivy-image-scan` | CJ | 256 | 1024 | — | Burstable | 실행 시에만 | **(256)** | (1024) |
| J | `openmeter-billing-advance-invoices` | CJ | 192 | 512 | — | Burstable | 실행 시에만 | **(192)** | (512) |
| J | `openmeter-billing-collect-invoices` | CJ | 192 | 512 | — | Burstable | 실행 시에만 | **(192)** | (512) |
| J | `openmeter-subscription-sync` | CJ | 192 | 512 | — | Burstable | 실행 시에만 | **(192)** | (512) |
| J | `efs-cleaner` | CJ | 128 | 384 | — | Burstable | 실행 시에만 | **(128)** | (384) |
| J | `rotation-git-sync` | CJ | 128 | 512 | — | Burstable | 실행 시에만 | **(128)** | (512) |
| J | `openmeter-dlq-replay` | CJ | 64 | 192 | — | Burstable | 실행 시에만 | **(64)** | (192) |
| J | `rotate-admin-passwords` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-elasticsearch-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-mariadb-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-minio-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-mongodb-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-postgresql-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| J | `rotate-redis-password` | CJ | 64 | 256 | — | Burstable | 실행 시에만 | **(64)** | (256) |
| X | `safeline` | Dep | 2368 | 5632 | 116 | Burstable | 1 | **2368** | 5632 |
| X | `gitlab` | STS | 2304 | 4096 | 2110 | Burstable | 1 | **2304** | 4096 |
| X | `trino` | STS | 2048 | 2048 | 824 | Guaranteed | 1 | **2048** | 2048 |
| X | `livy` | STS | 768 | 1024 | 606 | Burstable | 1 | **768** | 1024 |
| X | `spark-history` | STS | 768 | 1024 | 612 | Burstable | 1 | **768** | 1024 |
| X | `spark-connect` | STS | 640 | 2048 | 338 | Burstable | 1 | **640** | 2048 |
| X | `jenkins` | STS | 448 | 1536 | 280 | Burstable | 1 | **448** | 1536 |
| X | `ranger-usersync` | Dep | 256 | 768 | 124 | Burstable | 1 | **256** | 768 |
| X | `caldera` | Dep | 192 | 1536 | 26 | Burstable | 1 | **192** | 1536 |
| X | `defectdojo-celery-beat` | Dep | 192 | 512 | 11 | Burstable | 1 | **192** | 512 |
| X | `safeline-luigi` | Dep | 128 | 384 | 34 | Burstable | 1 | **128** | 384 |
| X | `safeline-fvm` | Dep | 64 | 256 | 46 | Burstable | 1 | **64** | 256 |
| C | `cnpg-operator` (신규) | STS | 200 | 400 | — | Burstable | 1 | **200** | 400 |
| C | `clickhouse-keeper` (신규) | STS | 128 | 256 | — | Burstable | 3 | **384** | 768 |
| C | `hadoop-journalnode` (신규) | STS | 256 | 512 | — | Burstable | 3 | **768** | 1536 |
| C | `hadoop-zkfc` (신규) | STS | 128 | 256 | — | Burstable | 2 | **256** | 512 |

## 21. Proxmox 로 바꾸면 달라지는가 (2026-09-05 검토)

> **이 절은 실측이 아니다.** 이 호스트에 Proxmox 가 없으므로 구조로 따진
> 것이고, 숫자는 Hyper-V 쪽 실측값에서 **호스트 OS 몫만 바꿔 계산**했다.
> 실제로 옮기기 전에 다시 재야 한다.

### 21-1. 유일하게 확실히 달라지는 것 — 호스트 OS 몫

```
Hyper-V (Windows 11)   63.4 − Windows 7.0 − L0 랩 8.8 = 47.6 GiB
Proxmox VE (Debian)    63.4 − PVE 호스트 ~2 − L0 랩 8.8 = 52.6 GiB
                                                        ────────
                                                          +5.0
```

`.wslconfig` 주석이 정한 "Windows 데스크톱에 약 7 GB" 가 사라지고 PVE
호스트 서비스 몫만 남는다. **약 5 GiB 를 번다.**

### 21-2. 그래서 결론은 바뀌는가

| 구성 | 필요 VM | Hyper-V 47.6 | **Proxmox 52.6** |
|---|---:|---|---|
| 3노드 · HA 없음 | 43.7 | ✅ | ✅ |
| 3노드 · **실용 HA**(§12②) | 49.5 | ⚠ `L0-Target` 꺼야 | **✅ 그대로 들어감** |
| 3노드 · **풀 HA** | **82.4** | ❌ −34.8 | ❌ **−29.8** |

**풀 HA 는 여전히 안 된다.** 5 GiB 로는 30 GiB 부족을 메우지 못한다.
다만 **실용 HA 가 랩을 끄지 않고 들어간다** — 그것이 실질적 이득이다.

### 21-3. 기대할 수 없는 것들

| | 왜 도움이 안 되나 |
|---|---|
| **KSM**(페이지 중복 제거) | 호스트가 물리 RAM 을 아끼는 기법이다. **게스트의 MemTotal 은 그대로**이므로 allocatable·requests 계산이 바뀌지 않는다 — zram 과 정확히 같은 이유다(§20-6). 그리고 노드마다 워크로드가 달라 중복될 페이지는 DaemonSet 6종 정도다 |
| **KVM 벌루닝** | Hyper-V 동적 메모리와 같은 문제다. kubelet 은 기동 시점 총 메모리로 자원을 계산하므로 **H1 이 금지한다**. 하이퍼바이저가 바뀌어도 이유가 그대로다 |
| **호스트 오버커밋 + 스왑** | 게스트가 실제로 쓰면 호스트가 스왑한다. 게스트 zram 위에 호스트 스왑이 겹쳐 **이중 스왑**이 되고 지연이 예측 불가해진다 |
| **LXC 컨테이너 노드** | 커널을 공유하므로 노드별 오버헤드가 사라지는 것은 맞다. 그러나 이 스택은 **노드마다 eBPF 를 적재**한다(Cilium·ztunnel·Tetragon·Falco). 한 커널에서 여러 "노드" 가 netfilter·eBPF 상태를 두고 충돌한다 — §8-31 이 검증한 것이 **VM 안의** eBPF 였다 |

### 21-4. ★ 함정 하나 — ZFS ARC

Proxmox 를 ZFS 로 설치하면 **ARC 기본값이 물리 RAM 의 50%** 다. 63.4 GiB
호스트에서 31 GiB 를 캐시가 가져가면 §21-1 의 +5 GiB 이득이 통째로 사라지고
오히려 크게 손해다. ext4/LVM 을 쓰거나 `zfs_arc_max` 를 명시적으로 낮출 것.

### 21-5. 메모리 밖의 손익

- **얻는 것** — 스냅샷·백업이 하이퍼바이저 기본 기능이 된다(§13-5 의 백업
  작업이 쉬워진다). PCIe 패스스루. 그리고 §11-2-b 에서 막혔던 **공유 스토리지**가
  가능해진다(Ceph·ZFS over iSCSI) — 다만 **물리 디스크가 한 장인 한 내구성은
  그대로 §11-0 의 범위 밖**이다
- **잃는 것** — Windows 데스크톱. 이 호스트는 사용자의 작업 기기이기도 하다.
  기술적 판단만으로 정할 사안이 아니다

### 21-6. 판단

**메모리 증설 없이 풀 HA 를 하려는 목적이라면 Proxmox 는 답이 아니다**
(+5 GiB vs 부족분 34.8). 실용 HA 를 랩과 함께 돌리려는 목적이라면 맞는
수단이고, 그 경우에도 §19-3 의 레버(프로파일 분리·requests 정정)가
하이퍼바이저 교체보다 회수량이 크다(10~14 GiB vs 5 GiB).

## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [APP-INTEGRATION.md](./APP-INTEGRATION.md) — **애플리케이션 연동 가이드.** 앱 개발 시 여기부터 볼 것
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
