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

**`bootstrap-wsl-k3s.sh`의 k3s 플래그** — NodeSwap은 kubelet 플래그라 **설치 시점에만 정할 수 있다.** 나중에 켜려면 systemd 유닛 편집 + 재시작 = 전 파드 재시작이다.

```
--flannel-backend=none --disable-network-policy   # Cilium 전제 (클라우드와 동일)
--disable traefik --disable servicelb
--kubelet-arg=fail-swap-on=false                  # 스왑 존재 시 kubelet 기동 거부 회피
--kubelet-arg=feature-gates=NodeSwap=true
--kubelet-arg=memory-swap.swap-behavior=LimitedSwap
--kubelet-arg=memory-throttling-factor=0.8        # memory.high 를 limit 의 80% -> OOMKill 전 회수
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

`bootstrap-wsl-k3s.sh`가 해소하는 것은 **#5 하나**다. 나머지는 별도 작업이다.

| # | 블로커 | 상태 |
|:-:|---|---|
| 1 | Secret 렌더링 0개 — `.enc.yaml` 12개가 kustomization 주석 처리 | 미해소 |
| 2 | 오퍼레이터 설치 경로 없음 (ECK·Kyverno·Gateway API·cert-manager·Argo Events·OTel·Trivy) | 절차 6 수동 |
| 3 | DB·롤·버킷·토픽 부트스트랩 Job 부재 | 미해소 |
| 4 | ServiceAccount 12개 부재 | 미해소 |
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

## 관련 문서

- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 배포 블로커, 용량·비용
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소별 메모리, 의존 관계
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 컴포넌트 경계, 갭(G1~G41), TODO
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-051~053(로컬 타깃), ADR-066(FreeIPA 제거)
