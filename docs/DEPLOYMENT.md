# DEPLOYMENT — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> 표기 규칙은 [ARCHITECTURE.md](./ARCHITECTURE.md) 서두와 동일하다.
>
> **요구사항 ID 체계**
>
> | 대역 | 계층 |
> |---|---|
> | `INFRA-0xx` | IaC · 프로비저닝 |
> | `INFRA-1xx` | 클러스터 부트스트랩 |
> | `INFRA-2xx` | 네트워크 · 진입점 |
> | `INFRA-3xx` | 스토리지 |
> | `INFRA-4xx` | GitOps · 배포 |
> | `INFRA-5xx` | 가용성 · DR |
> | `INFRA-6xx` | 관측성 · 용량 |

---

## 목차

1. [현재 배포 블로커](#1-현재-배포-블로커)
2. [사전 요구 도구](#2-사전-요구-도구)
3. [배포 순서](#3-배포-순서)
4. [로컬 배포 (Hyper-V)](#4-로컬-배포-hyper-v) — *WSL2 경로는 [LOCAL-DEPLOYMENT.md](./LOCAL-DEPLOYMENT.md)*
5. [프로파일 전환](#5-프로파일-전환)
6. [용량 산정 및 비용](#6-용량-산정-및-비용)
7. [검증 절차](#7-검증-절차)
8. [인프라 요구사항 (INFRA-xxx)](#8-인프라-요구사항-infra-xxx)

---

## 1. 현재 배포 블로커

**신규 클러스터에 현재 상태 그대로 배포하면 실패한다.**

| 우선 | 블로커 | 증상 | 근거 |
|:-:|---|---|---|
| **P0** | **Secret이 하나도 배포되지 않음** (G2 · SEC-403) | `secretKeyRef` 참조 워크로드 8개+ 가 `CreateContainerConfigError` | 12개 `*.enc.yaml` 전부 kustomization 주석 처리 |
| **P0** | **오퍼레이터 설치 경로 없음** (TODO-03) | ECK·Kyverno·Gateway API·Argo Events CRD 부재 → wave 0·7 sync 불가 | `infra/scripts/`에 설치 스크립트 없음 |
| **P0** | **DB·롤·버킷·토픽 부트스트랩 없음** (G22) | Keycloak·GitLab·Apicurio·Hive MS가 없는 DB에 접속. Trino가 없는 버킷 조회 | `postgresql-configmap.yaml:10-11`은 `oneinchmarket` DB만 생성 |
| **P0** | **ServiceAccount 12개 부재** (G18) | 15개 워크로드가 없는 SA를 지정 → Pod 생성 실패 | 커밋 `f08512f` 이후 |
| **P1** | **AppProject 화이트리스트 누락** (G17) | `service-mesh/` 전체 sync 거부. NetworkPolicy·PDB도 위험 | `projects/oneinchmarket.yaml:24-46` |
| **P1** | **CMP 플러그인 이름 불일치** (G3) | Application은 `kustomize-sops`, 스크립트는 `ksops` 등록. 사이드카도 없음 | `install-argocd.sh:30` |
| **P1** | **NetworkPolicy 커버리지 공백** (G13) | MinIO·Trino·Hive MS·Keycloak·Apicurio·GitLab 인바운드 전면 차단 | `network-policies/kustomization.yaml` |
| **P1** | **Kafka 9093 규칙 부재** (G23) | prod 3브로커 KRaft quorum 형성 불가 | `messaging-netpol.yaml` |
| **P1** | **storageClass `standard` 부재** (TODO-07) | PVC가 Pending으로 정체. k3s 기본은 `local-path` | 전 volumeClaimTemplate |
| **P2** | **외부 진입점 없음** (TODO-01) | Ingress/Gateway/NodePort/LB 객체 0개. traefik·servicelb 비활성 | `bootstrap-k3s.sh:126-132` |
| **P2** | **TLS 전략 없음** (TODO-02) | cert-manager·Issuer·Certificate 없음 | — |
| **P2** | **prod IaC 인증 불가** (G5) | `prod/main.tf`에 provider 블록·토큰 변수 없음 | `environments/prod/main.tf` |
| **P2** | **CI build 실패** (G9) | 참조 Dockerfile 2개가 존재하지 않음 | `.gitlab-ci.yml:56,65` |
| **P3** | Kafka `KAFKA_LOG_DIRS` 미설정 (G23) | PVC 미사용 → 재시작 시 데이터 유실 | `kafka-configmap.yaml` |
| **P3** | prod GitLab VCT 이름 불일치 (G16) | volumeMount에 대응하는 claim 없음 | `storage-prod.yaml:42` |

---

## 2. 사전 요구 도구

| 도구 | 최소 버전 | 용도 | 이 환경 |
|---|---|---|:-:|
| `tofu` | 1.6.0 | IaC | ❌ |
| `kubectl` | 1.31+ | 클러스터 조작 (kustomize 내장) | ✅ v1.36.1 |
| `kustomize` | 5.0+ | 매니페스트 빌드 (`kubectl kustomize`로 대체 가능) | ❌ |
| `kubeconform` | 최신 | 스키마 검증 | ❌ |
| `helm` | 3.x | Sentry 배포 시에만 (ADR-036 ⓑ) | ❌ |
| `cilium` CLI | 최신 | Cilium 설치·검증 | ❌ |
| `istioctl` | 1.24+ | Istio Ambient | ❌ |
| `argocd` CLI | 2.13+ | 동기화·상태 확인 | ❌ |
| `vault` CLI | 최신 | Vault 초기화·unseal (ADR-024) | ❌ |
| `wg` | — | WireGuard 클라이언트 | ❌ |
| `sops`, `age` | — | Vault 미채택 시에만 | ❌ |
| `gitleaks`, `checkov`, `syft` | — | CI 전용 | ❌ |

> **이 환경에서는 `kubectl`만 사용 가능하다.** IaC·스키마 검증 관련 서술은 `[UNVERIFIED]`.

---

## 3. 배포 순서

```
┌─ Phase A ─ IaC 프로비저닝 ────────────────────────────────┐
│  cd infra/environments/{dev|prod}                         │
│  export TF_VAR_vultr_api_key=...                          │
│  tofu init && tofu plan && tofu apply                     │
│  → bastion · master · worker × N · VPC · 방화벽 그룹 2종   │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase B ─ 클러스터 부트스트랩 ───────────────────────────┐
│  ./infra/scripts/bootstrap-k3s.sh --mode=cloud \          │
│      <BASTION_IP> <MASTER_PRIVATE_IP> <WORKER_IPs...>     │
│  → WireGuard 서버 구성 + 클라이언트 설정 생성              │
│  → k3s server/agent 설치 · kubeconfig 회수                 │
│  ※ Cilium 전제 플래그 (설치 시점에만 지정 가능):           │
│     --flannel-backend=none --disable-network-policy       │
│     --disable traefik --disable servicelb                 │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase C ─ 플랫폼 계층 (ArgoCD 밖, wave −1) ──────────────┐
│  ./install-cilium.sh      # M1 socketLB.hostNamespaceOnly │
│                           # M2 cni.exclusive=false        │
│  ./install-istio.sh       # M3 istio-cni 포함              │
│  ./install-operators.sh   # ECK · Kyverno · Gateway API   │
│                           # cert-manager · Argo Events    │
│                           # OTel Operator · Trivy Operator│
│  ./install-argocd.sh      # 플러그인 이름 정합 필요 (G3)   │
│  ./install-reloader.sh                                    │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase D ─ 시크릿 시딩 ───────────────────────────────────┐
│  Vault 채택 시 (ADR-024):                                  │
│    vault operator init / unseal / Kubernetes auth 설정     │
│  SOPS 유지 시:                                             │
│    kubectl create secret generic sops-age \                │
│      -n argocd --from-file=keys.txt=keys.txt               │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase E ─ GitOps 등록 ───────────────────────────────────┐
│  kubectl apply -f argocd/projects/oneinchmarket.yaml       │
│  kubectl apply -f argocd/applications/oneinchmarket-*.yaml │
│  → wave 0 → 13 순차 동기화                                  │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase F ─ 메시 활성화 ───────────────────────────────────┐
│  1. ambient 레이블 활성화 (dev)                             │
│  2. ambient 우회 탐지 검증 (SEC-108)      ← 배포 게이트      │
│  3. PeerAuthentication PERMISSIVE → STRICT                 │
└──────────────────────────┬────────────────────────────────┘
┌─ Phase G ─ 검증 ──────────────────────────────────────────┐
│  cd scripts/security-verification && ./run-all.sh <ns>     │
└────────────────────────────────────────────────────────────┘
```

### 3-1. 부트스트랩 순환 문제 (TODO-22)

**ArgoCD가 GitLab에서 매니페스트를 가져오는데, GitLab은 ArgoCD가 wave 8에 배포한다.** 최초 시드 경로가 정의되어 있지 않다.

선택지: ⓐ 외부 Git 미러에서 부트스트랩 후 GitLab으로 소스 전환, ⓑ 일회성 `kubectl apply -k`로 GitLab만 먼저 배포, ⓒ GitLab을 클러스터 밖으로 분리.

### 3-2. 프로바이더 전환

**ADR-019에 따라 Vultr 단독이므로 전환 절차는 존재하지 않는다.** 타 클라우드로 이동할 경우 `infra/modules/`를 새로 작성한다 — 멀티 프로바이더 추상화를 유지하는 것이 이동을 쉽게 만들지 않는다는 것이 이 레포의 실증 사례다 (ADR-011 Superseded 사유).

---

## 4. 로컬 배포 (Hyper-V)

> **WSL2 단일 노드 경로는 [LOCAL-DEPLOYMENT.md](./LOCAL-DEPLOYMENT.md) 참조** (브랜치 `local`).
> 이 절은 Hyper-V 3-VM 을 전제한다.

### 4-1. 호스트 요구사항

| 목표 | RAM | CPU | 디스크 |
|---|---|---|---|
| 프로파일 전환 방식 | **64 GB** | 8코어/16스레드 | 512 GB NVMe |
| **전 구성요소 동시 배포** | **128 GB (권장)** | **16코어/32스레드** | **1 TB NVMe** |
| HA 검증 (레플리카 3) | 256 GB | 24코어+ | 1.5 TB |

> **96 GB는 여유 2.8 GB로 비권장**이다. 예상치 못한 사용량 증가 시 즉시 OOM이 발생한다.

### 4-2. Hyper-V 필수 설정

| # | 항목 | 조치 |
|---|---|---|
| **H1** | **동적 메모리 비활성 필수** | kubelet은 기동 시점 총 메모리로 자원을 계산한다. 벌루닝은 예측 불가한 OOM·축출을 유발한다. `Set-VMMemory -DynamicMemoryEnabled $false` |
| **H2** | Generation 2 + Secure Boot | Ubuntu는 `-SecureBootTemplate MicrosoftUEFICertificateAuthority` 또는 Secure Boot 비활성 |
| **H3** | **Default Switch 사용 금지** | 서브넷이 재부팅마다 바뀐다. **Internal 스위치 + `New-NetNat`** 으로 고정 서브넷 구성 |
| **H4** | 정적 MAC 주소 | 노드 IP가 바뀌면 k3s 클러스터가 깨진다 |
| **H5** | Cilium XDP 미지원 | Hyper-V 합성 NIC(`hv_netvsc`)에서 XDP 오프로드 불가. 기능은 정상이나 **성능 기준선으로 쓰지 말 것**. `[VERIFIED 2026-09-04]` — 랩 VM 에서 실측했다(커널 6.8.0-138 · k3s v1.31.4+k3s1 · Cilium 1.16.5, 클러스터와 동일 플래그). Cilium 기동 · socketLB 경유 Service 통신 · **NetworkPolicy 강제와 제거 후 복귀**까지 12/12 통과. XDP 는 예상대로 `Device Mode: veth` 다. 절차와 함정은 `LOCAL-DEPLOYMENT.md §8-31` |
| **H6** | Docker Desktop 자원 경합 | WSL2와 Hyper-V VM이 호스트 메모리를 두고 경합. Docker Desktop 종료 또는 `.wslconfig` 메모리 상한 설정 |

**H1과 H3이 가장 흔한 실패 원인**이므로 부트스트랩 스크립트에 사전 점검을 넣는다.

### 4-3. VM 할당안

**128 GB 호스트 — 전체 배포**

```
물리 메모리                        128 GB
  − Windows 11 + Hyper-V           −6 GB
  − 버퍼 (Docker Desktop 등)      −14 GB
                                ─────────
  VM 할당                          108 GB

  local-master-1   4 vCPU / 16 GB
  local-worker-1   8 vCPU / 46 GB
  local-worker-2   8 vCPU / 46 GB
                  ───────────────
                  20 vCPU / 108 GB

  워크로드 가용 = 108 − 4.5(OS·k3s) − 4.8(DaemonSet) = 98.7 GB
  실제 소요                                          = 77.9 GB
  여유                                               = 20.8 GB  ✅
```

**64 GB 호스트 — 프로파일 전환**

```
물리 메모리                         64 GB
  − Windows 11 + Hyper-V           −6 GB
  − 버퍼                           −8 GB
                                ─────────
  VM 할당                          50 GB
  local-master-1   2 vCPU / 12 GB
  local-worker-1   4 vCPU / 19 GB
  local-worker-2   4 vCPU / 19 GB

  워크로드 가용 = 50 − 4.5 − 4.8 = 40.7 GB
```

**64 GB로는 전체 배포가 불가능하다.**

| 구성 | VM 할당 | 오버헤드 | 워크로드 가용 | 77.9 GB 대비 |
|---|--:|--:|--:|---|
| 3 VM, 버퍼 8 GB (권장) | 50 GB | 9.3 | 40.7 GB | ❌ −37.2 |
| 3 VM, 버퍼 0 (위험) | 58 GB | 9.3 | 48.7 GB | ❌ −29.2 |
| 2 VM, 버퍼 0 (극단) | 58 GB | 6.2 | 51.8 GB | ❌ −26.1 |

H1(동적 메모리 비활성) 때문에 하이퍼바이저 오버커밋도 쓸 수 없다.

### 4-4. 로컬 DaemonSet — 6종 / 1.6 GB per node

| 포함 | 제외 (사유) |
|---|---|
| Cilium agent 0.5 · ztunnel 0.3 · istio-cni 0.1 · Tetragon 0.3 · OTel agent 0.3 · node-exporter 0.1 | Suricata·Zeek (L0 OPNsense 전용, 로컬 NAT에서 검증 가치 없음) · Kubescape node-agent · Wazuh agent · Filebeat |

**Suricata·Zeek는 클라우드에서도 DaemonSet이 아니라 OPNsense 전용이다** (ADR-055). 동-서 가시성은 Cilium/Hubble이 제공한다.

### 4-5. VM 이미지 — 골든 VHDX

cloud-init seed ISO는 Windows에서 `oscdimg`(Windows ADK) 같은 별도 도구를 요구한다. 더 단순한 경로를 채택한다.

1. Ubuntu 24.04 VM을 한 번 수동 구성 (SSH 공개키 주입, `cloud-init` 설치, 일반화)
2. VHDX를 **골든 템플릿**으로 보관
3. OpenTofu가 VM마다 템플릿을 복사 후 호스트명·IP만 설정

### 4-6. 디스크 산정 (~640 GB)

| 대상 | 용량 |
|---|--:|
| MinIO (레이크하우스 + Tempo blocks + Loki chunks) | 100 GB |
| Elasticsearch ×1 · Wazuh Indexer ×1 | 100 GB |
| HDFS DataNode ×1 · GitLab | 100 GB |
| DB 4종 · Kafka ×1 | 80 GB |
| Loki + Prometheus (보존 3일) | 30 GB |
| 기타 (Dependency-Track · DefectDojo · Jenkins · HBase) | 70 GB |
| **PVC 소계** | **480 GB** |
| VM OS 디스크 (3 × 40 GB) + 골든 템플릿 | 160 GB |
| **총계** | **~640 GB** |

### 4-7. 로컬의 검증 범위

| 검증 가능 | 검증 불가 |
|---|---|
| **Cilium + Istio 공존 설정(M1 socketLB 우회)** — 클라우드 재구축 전 선검증 | 노드 간 실제 네트워크 성능 (H5) |
| Kustomize 빌드·오버레이·sync wave 순서 | OPNsense 경계 통제, Suricata/Zeek 남-북 IDS |
| Kyverno 정책, Trivy Operator, Tetragon 규칙 | Wazuh 상관분석 (인덱서 규모) |
| DB/버킷/토픽 부트스트랩 Job | HA 페일오버 (레플리카 1) |
| OTel 파이프라인, Grafana 상관조회 | 실제 부하·용량 산정 |
| ArgoCD GitOps 동작 | |

---

## 5. 프로파일 전환

### 5-1. 방식 A — 오버레이 전환 (정식)

```bash
argocd app set oneinchmarket-local --path kubernetes/overlays/local-lakehouse
argocd app sync oneinchmarket-local --prune

# 또는 직접 적용
kubectl kustomize kubernetes/overlays/local-lakehouse | kubectl apply -f -
```

`prune: true`가 이전 프로파일 리소스를 제거한다. 선언적이고 Git이 단일 진실 원천으로 유지된다. 소요 3~10분.

### 5-2. 방식 B — 레플리카 0 스케일 (빠른 반복)

```bash
kubectl scale sts,deploy -l app.kubernetes.io/component=governance --replicas=0 -n local
kubectl scale sts,deploy -l app.kubernetes.io/component=governance --replicas=1 -n local
```

수십 초 만에 메모리가 회수된다. 단, ArgoCD `selfHeal: true`가 원복시키므로 로컬에서는 `selfHeal: false` 또는 `ignoreDifferences`에 `/spec/replicas` 추가가 필요하다. **임시 수단으로만 사용한다.**

### 5-3. PVC 보존

StatefulSet을 제거해도 **PVC는 자동 삭제되지 않는다.** 프로파일을 오가도 데이터가 보존된다. 다만 PVC가 디스크를 계속 점유하므로 640 GB 산정을 넘어설 수 있다. 로컬에서는 PVC에 `argocd.argoproj.io/sync-options: Prune=false`를 붙이는 것이 안전하다.

### 5-4. 프로파일별 소요 (64 GB 예산 40.7 GB 기준)

| 오버레이 | 컴포넌트 | 소요 | 판정 |
|---|---|--:|:-:|
| `local-core` | core 19.9 + observability(최소) 12.2 | 32.1 | ✅ 여유 8.6 |
| `local-lakehouse` | core 19.9 + lakehouse-v1 9.2 | 29.1 | ✅ 여유 11.6 |
| `local-governance` | core 19.9 + governance 5.9 + devops 4.0 | 29.8 | ✅ 여유 10.9 |
| `local-apm` | core 19.9 + observability(최소) 12.2 + apm(GlitchTip) 3.5 | 35.6 | ✅ 여유 5.1 |
| `local-security-min` | core 19.9 + observability(최소) 12.2 + security-min 5.0 | 37.1 | ✅ 여유 3.6 |
| ~~`local-security-full`~~ | core + observability + security-full | 51.3 | ❌ **초과 10.6** |

~~**`security-full`은 128 GB 이상에서만 검증 가능하다.**~~

> **2026-09-03 실측으로 무효화.** 54.9 GiB + zram 에서 5종 전부 기동했다.
> 실사용 **3.49 GiB**(산정 13.7 GB), 여유 23.5 GiB. 산정이 벤더 권장값을
> 그대로 더해 4배 과대였다 — 예: Dependency-Track 권장 힙 4 GB vs 실사용 459Mi.
> 근거는 [LOCAL-DEPLOYMENT.md §8-26](./LOCAL-DEPLOYMENT.md).

---

## 6. 용량 산정 및 비용

> **모든 수치는 추정이다.** v1 매니페스트에는 리소스 정의가 없고(계획서 §2 이슈 #5), 신규 스택은 각 프로젝트 기본 권장값을 사용했다. 실측 기반 재산정이 선행되어야 한다 (ADR-058).

### 6-1. 노드 수 산정

```
사이징 기준: MEM limits ÷ 가용 메모리 ≤ 85%   (계획서 §9 자체 기준)
16C/64GB 노드 가용분 = 64 − 1.5 = 62.5 GB
필요 가용 = 소요 ÷ 0.85
```

### 6-2. 최적화 단계별 노드 수

| 단계 | 조치 | 소요 | 노드 |
|:-:|---|--:|--:|
| 0 | 초기 산정 | 329 Gi | 7 |
| 1 | **DaemonSet 정정** (Suricata/Zeek는 OPNsense 전용) | 303 Gi | **6** |
| 2 | + **JVM 힙 명시 설정** + **GlitchTip** | 255 Gi | **5** |
| 3 | + 빈 패킹 스케줄러 (여유율 85%→90%) | 255 Gi | 5 |
| 4 | + **KRR 실측 기반 right-sizing (−15%)** | 217 Gi | **4** |
| — | anti-affinity 하한 (ES×3·Kafka×3·Wazuh Idx×3 + N+1) | — | **4 (하한)** |

**3·4단계는 클러스터를 실제로 띄우고 최소 2주 측정한 뒤에만 적용한다.** 메모리는 CPU와 달리 throttle이 아니라 OOMKill이다.

### 6-3. 배치 최적화 레버

| 레버 | 내용 |
|---|---|
| **실측 기반 right-sizing** | **KRR**(Prometheus 기반, 컨트롤러 불필요 — Prometheus가 이미 설계에 있어 추가 비용 0) 또는 VPA recommendation + Goldilocks |
| **빈 패킹 스케줄러** | k3s 기본은 `LeastAllocated`(분산). `NodeResourcesFit.scoringStrategy: MostAllocated`로 조밀 배치. `--kube-scheduler-arg=config=<path>` — **부트스트랩 시점에만 적용** |
| **Descheduler** | `HighNodeUtilization` 전략으로 저사용 노드를 비운다 |
| **PriorityClass** | 로테이션 CronJob·Trivy·Kubescape·Caldera·부트스트랩 Job에 낮은 우선순위 → **상시 용량 산정에서 제외**. 야간 Job이 자원을 못 잡는 부작용도 방지 |
| **anti-affinity 최소화** | 상태 저장 HA 서비스에만 적용. 현재 규칙이 아예 없어 정의가 선행되어야 한다 |
| **노드 형상** | 메모리가 실질 제약(CPU 절반 이상 여유). 메모리 최적화 형상(1:8) 단가 대조 필요 `[UNVERIFIED]` |

### 6-4. 프로바이더별 월 비용 (prod 6노드, 추정)

단가 출처: `v2-architecture-plan.md` §9 (2026-02 기준) + 공개 자료. 환율 1 EUR ≈ 1.09 USD 가정.

| 프로바이더 | 리전 | 컴퓨트 | 스토리지 | **월** | **연** |
|---|---|--:|--:|--:|--:|
| Hetzner EU | 독일 | $727 | 로컬 NVMe | **~$727** | ~$8,700 |
| Hetzner SG | 싱가포르 | $1,251 | 로컬 NVMe | **~$1,251** | ~$15,000 |
| OVH SG (12개월 약정) | 싱가포르 | $1,733 | **포함** | **~$1,733** | ~$20,800 |
| OVH SG (온디맨드) | 싱가포르 | $2,475 | **포함** | **~$2,475** | ~$29,700 |
| **Vultr (채택)** | 서울/싱가포르 | $2,526 | 로컬 NVMe 시 $0 | **~$2,526** | ~$30,300 |
| Vultr + 블록 스토리지 2.25 TB | | $2,526 | $225 | ~$2,751 | ~$33,000 |

**OVHcloud 주의** — 2026년 10월 1일부로 언번들 과금 전환. 로컬 스토리지 €0.11/GB/월, IPv4 €1.97/월이 분리 과금되어 b3-64는 €299 → **€343**(+14.9%), b3-32는 €149 → **€173**(+15.6%). 싱가포르는 EU와 동일 단가이며 b3-64에 400 GB NVMe가 포함되어 **6노드 = 2.4 TB로 스토리지 요구를 충족**한다.

**Oracle Cloud Ampere(ARM)은 이 스택에 부적합**하다. v1 복원분에 로컬 빌드 이미지 2종(`hbase:2.6.3`·`knox-gateway:2.1.0`)이 있고 Hadoop/HBase/Ranger/Knox/ClickHouse/Wazuh의 arm64 지원을 전수 검증해야 한다.

### 6-5. 스토리지 산정 (~2.25 TB)

| 대상 | 용량 |
|---|--:|
| MinIO (레이크하우스 + Tempo + Loki) | 300 GB |
| Elasticsearch ×3 | 300 GB |
| Wazuh Indexer ×3 | 300 GB |
| HDFS DataNode ×3 | 300 GB |
| ClickHouse (Sentry 채택 시) | 200 GB |
| DB 4종 | 200 GB |
| Kafka (레이크하우스 150 + Sentry 100) | 250 GB |
| GitLab · Prometheus · HBase · 기타 | 400 GB |

**TODO-07(storageClass)은 비용 결정이기도 하다** — 블록 스토리지 $225/월 vs 로컬 NVMe $0 vs 데이터 이동성.

### 6-6. 즉시 적용 가능한 절감 (Vultr 기준)

| 조치 | 절감 |
|---|--:|
| JVM 힙 명시 설정 + GlitchTip 채택 → 7 → 6노드 | −$384/월 |
| **dev 클러스터를 로컬 Hyper-V(128 GB)로 대체** | **−$1,400/월** |
| 로컬 NVMe 사용 (TODO-07 결정) | −$225/월 |
| **합계** | **−$2,009/월 (−$24,100/년)** |

**128 GB 메모리 증설 비용은 1개월분 미만으로 회수된다.**

---

## 7. 검증 절차

```bash
# 1) 매니페스트 빌드 — 모든 오버레이
for o in kubernetes/overlays/*/; do kustomize build "$o" > /dev/null; done
# kustomize 미설치 시: kubectl kustomize "$o" > /dev/null

# 2) 스키마 검증
kustomize build kubernetes/overlays/prod | kubeconform -strict -summary

# 3) IaC
cd infra/environments/dev && tofu init && tofu validate && tofu plan

# 4) 보안 검증 스위트
cd scripts/security-verification && ./run-all.sh <namespace>
```

### 7-1. CI 확장 `[목표]`

```yaml
kustomize-validate:
  script:
    - for o in kubernetes/overlays/*/; do kustomize build "$o" > /dev/null; done

memory-budget-check:      # 로컬 프로파일이 예산을 넘는 변경 차단
  script:
    - |
      for o in kubernetes/overlays/local-*/; do
        total=$(kustomize build "$o" \
          | yq -N '.spec.template.spec.containers[].resources.requests.memory' \
          | numfmt --from=iec | awk '{s+=$1} END {print s}')
        [ "$total" -le $((40*1024*1024*1024)) ] || { echo "FAIL: $o"; exit 1; }
      done
```

`kubeconform-validate`는 현재 kubeconform 이미지 안에서 `kustomize`를 실행하고 `allow_failure: true`이므로 **스키마 게이트가 무력화되어 있다** (TODO-24).

---

## 8. 인프라 요구사항 (INFRA-xxx)

`상태`: ✅ 충족 · 🔶 부분 · ❌ 미충족 · 🎯 목표

### INFRA-0xx — IaC · 프로비저닝

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-001 | 프로비저닝은 OpenTofu로 코드화한다 | ✅ | `infra/` |
| INFRA-002 | Vultr 단일 프로바이더로 통일한다 | 🎯 | ADR-019 — Hetzner 11개 파일 삭제 |
| INFRA-003 | 모듈을 평탄화하여 count 분기를 제거한다 | 🎯 | tf 42 → 19 파일 |
| INFRA-004 | prod 환경은 provider 블록과 API 토큰 변수를 갖는다 | ❌ | G5 — 현재 인증 불가 |
| INFRA-005 | storage 모듈은 `worker_ids`를 compute 출력에서 받는다 | ❌ | `prod/main.tf:41`이 `[]` |
| INFRA-006 | 리전 매핑(`kor→icn`)을 단일 locals로 통합한다 | ❌ | storage 모듈이 매핑 없이 전달 |
| INFRA-007 | 죽은 모듈을 제거한다 | 🎯 | `modules/bastion/` |
| INFRA-008 | tfstate는 원격 백엔드에 잠금과 함께 저장한다 | ❌ | `backend "local"` |
| INFRA-009 | Hyper-V 로컬 타깃을 별도 루트 모듈로 제공한다 | 🎯 | ADR-051·052 |
| INFRA-010 | Hyper-V 프로비저닝 방식을 확정한다 | 🎯 | `taliesins/hyperv` vs PowerShell `local-exec` (ADR-053) `[UNVERIFIED]` |
| INFRA-011 | IaC 코드에 정적 분석(Checkov)을 적용한다 | 🎯 | SEC-506 |

### INFRA-1xx — 클러스터 부트스트랩

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-101 | k3s 설치를 스크립트로 자동화한다 | ✅ | `bootstrap-k3s.sh` 7단계 |
| INFRA-102 | 노드명을 환경 변수로 파라미터화한다 | ❌ | `dev-master-1` 하드코딩 |
| INFRA-103 | `--mode=cloud\|local` 분기를 제공한다 | 🎯 | 로컬은 bastion 경유 없음 |
| INFRA-104 | Cilium 전제 k3s 플래그를 적용한다 | 🎯 | **설치 시점에만 지정 가능 → 클러스터 재구축 필요** |
| INFRA-105 | 오퍼레이터 설치 스크립트를 제공한다 | ❌ | ECK·Kyverno·Gateway API·Argo Events·cert-manager·OTel·Trivy Operator |
| INFRA-106 | Cilium 설치 시 M1·M2 설정을 강제한다 | 🎯 | ADR-043 |
| INFRA-107 | `istio-cni` DaemonSet을 배포한다 | 🎯 | ambient 필수 |
| INFRA-108 | H1~H6 Hyper-V 사전 점검을 부트스트랩에 포함한다 | 🎯 | 동적 메모리·스위치 종류 검증 |
| INFRA-109 | prod 컨트롤플레인 토폴로지를 확정한다 | 🎯 | 단일 서버+SQLite vs `--cluster-init` 3서버 |

### INFRA-2xx — 네트워크 · 진입점

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-201 | bastion + VPC + 공인 IP deny-all 모델을 적용한다 | ✅ | Vultr |
| INFRA-202 | 외부 진입점(Ingress 또는 Gateway)을 제공한다 | ❌ | TODO-01. **v1에 ingress-nginx가 있었다** |
| INFRA-203 | TLS 인증서를 자동 발급·갱신한다 | ❌ | TODO-02. **v1에 cert-manager가 있었다** |
| INFRA-204 | DNS 레코드는 실제 도달 가능한 주소를 가리킨다 | 🔶 | dev는 master **사설 IP** — VPN 전용 설계 |
| INFRA-205 | nginx upstream은 네임스페이스에 독립적이다 | ❌ | `*.dev.svc.cluster.local` 하드코딩 |
| INFRA-206 | dev/prod 주소 대역 계획을 확정한다 | ❌ | 동일 `10.0.0.0/16` |
| INFRA-207 | OPNsense 경계 방화벽을 프로비저닝한다 | 🎯 | Vultr 배치 실현성 `[UNVERIFIED]` |
| INFRA-208 | WireGuard 피어를 개인별로 발급·회수한다 | ❌ | 단일 하드코딩 피어 |
| INFRA-209 | Kafka Bridge에 세션 어피니티를 구성한다 | 🎯 | Service `ClientIP` + Ingress cookie |

### INFRA-3xx — 스토리지

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-301 | 모든 PVC가 존재하는 StorageClass를 참조한다 | ❌ | `standard` 미생성. k3s 기본은 `local-path` |
| INFRA-302 | StorageClass 유형을 확정한다 | 🎯 | 로컬 NVMe(무료·노드 고정) vs 블록($225/월·이동 가능) |
| INFRA-303 | 모든 volumeClaimTemplate이 storageClassName을 명시한다 | ❌ | Keycloak·GitLab 누락 |
| INFRA-304 | 오버레이 storage 패치의 VCT 이름이 base와 일치한다 | ❌ | prod GitLab (G16) |
| INFRA-305 | Tempo·Loki는 MinIO를 오브젝트 백엔드로 사용한다 | 🎯 | 신규 스토리지 불필요 |
| INFRA-306 | Kafka는 마운트한 PVC를 실제로 사용한다 | ❌ | `KAFKA_LOG_DIRS` 미설정 (G23) |
| INFRA-307 | 로컬 배포는 640 GB 이상의 디스크를 확보한다 | 🎯 | §4-6 |

### INFRA-4xx — GitOps · 배포

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-401 | 환경별 ArgoCD Application으로 배포한다 | ✅ | dev·prod |
| INFRA-402 | AppProject는 사용하는 모든 API 그룹을 화이트리스트한다 | ❌ | G17 |
| INFRA-403 | CMP 플러그인 이름이 Application 정의와 일치한다 | ❌ | G3 |
| INFRA-404 | ClusterPolicy는 단일 Application이 소유한다 | ❌ | G25 |
| INFRA-405 | prod 배포는 사람의 승인을 거친다 | ❌ | **ArgoCD `automated{prune,selfHeal}`이 CI 수동 게이트를 우회** (G26) |
| INFRA-406 | 최초 부트스트랩 시드 경로를 정의한다 | ❌ | TODO-22 순환 |
| INFRA-407 | Kustomize Component로 프로파일을 조립한다 | 🎯 | ADR-054 |
| INFRA-408 | 서비스 디렉터리마다 kustomization.yaml을 둔다 | 🎯 | 약 40개 신규 |
| INFRA-409 | sync-wave를 서비스 단위로 지정한다 | 🎯 | ADR-062 |
| INFRA-410 | `commonLabels` 대신 `labels:`를 사용한다 | ❌ | deprecated 경고 8건 (ADR-063) |
| INFRA-411 | CI가 모든 오버레이를 빌드 검증한다 | ❌ | 현재 dev·prod만 |
| INFRA-412 | 로컬 프로파일의 메모리 예산을 CI가 검증한다 | 🎯 | §7-1 |
| INFRA-413 | CI가 참조하는 Dockerfile이 존재한다 | ❌ | G9 |

### INFRA-5xx — 가용성 · DR

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-501 | prod 상태 저장 서비스에 PDB를 정의한다 | ✅ | 8개 |
| INFRA-502 | PDB `minAvailable`이 실제 replicas와 정합한다 | ❌ | `redis-pdb minAvailable: 4` vs 축소 시 1 → **모든 축출 차단** |
| INFRA-503 | 데이터베이스는 실제 복제 토폴로지를 구성한다 | ❌ | replicas만 증가, 복제 없음 |
| INFRA-504 | 백업·복원 절차를 갖춘다 | ❌ | Velero·논리 덤프·ES 스냅샷·MinIO 복제 전무 |
| INFRA-505 | RPO/RTO를 정의하고 소유자를 지정한다 | ❌ | TODO-08 |
| INFRA-506 | anti-affinity를 상태 저장 HA 서비스에 적용한다 | ❌ | 규칙 자체가 없음 |

### INFRA-6xx — 관측성 · 용량

| ID | 요구사항 | 상태 | 비고 |
|---|---|:-:|---|
| INFRA-601 | 메트릭 수집·대시보드를 제공한다 | ❌ | Prometheus/Grafana 부재 |
| INFRA-602 | 리소스 요청·제한을 실측 기반으로 산정한다 | 🎯 | KRR — 배포 후 2주 측정 (ADR-058) |
| INFRA-603 | 빈 패킹 스케줄러 프로파일을 적용한다 | 🎯 | ADR-059 — 부트스트랩 시점 |
| INFRA-604 | PriorityClass 체계를 정의한다 | 🎯 | ADR-060 — 4단계 |
| INFRA-605 | JVM 워크로드는 힙을 명시 설정한다 | 🎯 | ADR-057 — 노드 1대 절감 |
| INFRA-606 | 로그·메트릭·트레이스 보존 정책을 정의한다 | 🔶 | ES ILM만 존재 |
| INFRA-607 | 클라우드 단가를 최소 분기 1회 재검증한다 | 🎯 | OVH 2026-10 개편 사례 |
| INFRA-608 | 로컬 호스트 사양을 목표별로 명시한다 | 🎯 | 64 GB(프로파일) / **128 GB(전체)** / 256 GB(HA) |

**총 요구사항 56건 — 충족 6 · 부분 3 · 미충족 24 · 목표 23.**

---

## 관련 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 데이터 흐름, 갭 목록, TODO
- [SECURITY.md](./SECURITY.md) — SEC-xxx 보안 요구사항
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소 카탈로그
- [PRD.md](./PRD.md) — 제품 요구사항, Phase 달성도
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — 결정 기록 후보
