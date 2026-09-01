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

### 8-6. 실측 메모리

22 파드 Running 시점:

```
Mem: 47 GiB total / 13 GiB used / 34 GiB available
zram: mem_used 2 MiB (disksize 32 GiB)   ← 사실상 미사용
vmstat si: 0                              ← 스왑인 없음
```

상위 소비: Elasticsearch 1,826 Mi · Logstash 930 Mi · Trino 836 Mi · Kibana 564 Mi · Keycloak 527 Mi

**§2 의 zram 설계는 아직 시험되지 않았다.** CrashLoop 중인 워크로드가 메모리를 잡지 않기 때문이며, 전 구성요소가 Running 이 되어야 §2-3 의 압축률 가정을 검증할 수 있다.


### 8-7. 최종 결과 (2026-09-01 배포 세션)

**25 Running · 5 Completed · 2 미해결**

부트스트랩 Job 5/5 완료 — `postgres-bootstrap` · `mariadb-bootstrap` · `minio-bootstrap` · `kafka-topics` · `hive-schematool`.

#### 남은 2건과 진단 (해소된 것은 취소선)

| 파드 | 마지막 오류 | 진단 |
|---|---|---|
| ~~cmmn-api~~ | — | **해소.** 소스(`oneinchmarket-cmmn-api`)를 확인한 결과 `application-kafka.yml` 의 `kafka-dev` 프로파일이 `spring.kafka.consumer.bootstrap-servers`·`producer.bootstrap-servers` 를 개별 지정한다. 더 구체적인 키가 우선하므로 `SPRING_KAFKA_BOOTSTRAP_SERVERS` 로는 덮이지 않았다. `SPRING_KAFKA_CONSUMER_/PRODUCER_BOOTSTRAP_SERVERS` 로 교체해 **재빌드 없이 해소** — G9 를 우회한다 |
| ~~apicurio-registry~~ | — | **해소.** health 엔드포인트가 관리 포트 9000 의 **`/health/*`** 에 있다(`/q` 접두사 없음). 포트포워딩 실측: `:9000/health/ready`→200, `:9000/q/health/ready`→404, `:8080/*`→404. base 의 `/health/*`(8080) 도 404 였다. 포트와 경로를 함께 고치고 `startupProbe` 를 추가했다 |
| **gitlab** | Chef `templatesymlink[Create a gitlab.yml]` 이후 핸들러 실패 | `max_locks_per_transaction` 상향으로 `out of shared memory` 는 넘겼으나 다음 단계에서 실패한다. GitLab Omnibus 초기화는 단계가 많아 추가 조사가 필요하다 |
| **spark-connect** | 종료 코드 없이 shutdown hook 만 남기고 종료 | `deletecollection` RBAC 과 Connect JAR 은 해소됐다. `start-connect-server.sh` + `SPARK_NO_DAEMONIZE` 로 전환했으나 여전히 조기 종료한다. client 모드 + `spark.master=k8s://` 조합의 추가 설정이 필요해 보인다 |

`elasticsearch-ilm-setup` 은 ES 기동 전에 실행되어 `Failed` 로 남아 있다 — 기존 매니페스트에 대기 루프가 없다.

#### 이 세션에서 해소한 결함 (커밋 20건)

| 계층 | 건수 | 대표 |
|---|--:|---|
| P0 블로커 | 5 | Secret · 오퍼레이터 · 부트스트랩 · SA · StorageClass |
| WSL2 고유 | 3 | 마운트 전파 · debugfs · Falco |
| 레포 기존 결함 | 9 | G23 · TODO-14 · SEC-512 · G13 · Apicurio 포트 · Logstash/Apicurio startupProbe · PostgreSQL 락 · Kafka quorum · Spark 버킷 |
| 작성 중 도입한 오류 | 8 | kubelet 플래그 2건 · 롤/DB 이름 2건 · `pg_isready` · SIGPIPE · NetworkPolicy · imagePullPolicy |

**"작성 중 도입한 오류" 8건은 실제로 배포하지 않았다면 전부 드러나지 않았을 것들이다.** 매니페스트가 `kustomize build` 를 통과하는 것과 클러스터에서 동작하는 것은 다른 문제다.

## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
