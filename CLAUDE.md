# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **주의**: 이 문서는 **현재 레포지토리의 실제 상태**를 기술한다. 설계 목표는 `docs/`를 참조하라.
> 매니페스트는 전부 작성되어 있으나 **현재 상태 그대로는 클러스터가 기동하지 않는다** — Gotchas 참조.

## 문서 인덱스

| 문서 | 내용 |
|---|---|
| [docs/PRD.md](docs/PRD.md) | 제품 요구사항, 목표·비목표, Phase 달성도, 미결정 사항 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 계층 구조, 데이터 흐름, 구현 vs 목표 갭(G1~G41), TODO 47건 |
| [docs/SECURITY.md](docs/SECURITY.md) | SEC-xxx 68건, 통제 인벤토리, 워크로드 커버리지 |
| [docs/COMPONENTS.md](docs/COMPONENTS.md) | 구성요소 카탈로그, v1↔v2 대조, 의존 관계 |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | INFRA-xxx 56건, 배포 절차, 배포 블로커, 용량·비용 |
| [docs/LOCAL-DEPLOYMENT.md](docs/LOCAL-DEPLOYMENT.md) | **브랜치 `local`.** WSL2 단일 노드 k3s + zram (B안). **§8 에 실배포 기록** — WSL2 고유 블로커 3건, 결함 32건 해소 |
| [docs/APP-INTEGRATION.md](docs/APP-INTEGRATION.md) | **애플리케이션 연동 가이드.** 앱을 이 플랫폼에 붙이는 법 — OTel·GlitchTip·Pyroscope·Kafka·계약, 새 워크로드 규약, 지금 안 되는 것 |
| [docs/ADR-CANDIDATES.md](docs/ADR-CANDIDATES.md) | 아키텍처 결정 기록 후보 60건 |
| `v2-architecture-plan.md` | **2026-02 작성 계획서.** 목표를 기술하며 현재 상태와 다른 부분이 있다 |
| `README.md` | **v1 내용 그대로다.** v2를 반영하지 않는다 |

## Project Overview

OneinchMarket Infrastructure (v2) — k3s 기반 데이터 레이크하우스 플랫폼. GitOps 관리, 보안 강화. `v2` 브랜치가 활성 개발 브랜치이며 `main`은 v1 레거시다.

**v1 → v2**: Hadoop/HBase/Hive/ZooKeeper → MinIO/Trino/Iceberg/Kafka KRaft. Raw YAML → Kustomize + ArgoCD. SOPS+age 시크릿 관리 도입(**단, 미작동**).

**클라우드**: dev는 **Vultr `icn`(서울)**, prod tfvars는 hetzner를 가리키나 **prod IaC는 provider 블록이 없어 배포 불가**하다. 설계상 **Vultr 단독**으로 확정되었다 (ADR-019).

## Key Commands

```bash
# 매니페스트 검증 (변경 확인의 주 수단)
kustomize build kubernetes/overlays/dev
kustomize build kubernetes/overlays/prod

# kustomize 미설치 시 — kubectl 내장 kustomize 사용
kubectl kustomize kubernetes/overlays/dev
kubectl kustomize kubernetes/overlays/prod

# 스키마 검증
kustomize build kubernetes/overlays/dev | kubeconform -strict -summary

# OpenTofu
cd infra/environments/dev && tofu init && tofu plan

# 보안 검증 스위트
cd scripts/security-verification && ./run-all.sh [namespace]
```

## Architecture

### Repository Layout

- `kubernetes/base/` — 카테고리별 Kustomize base 매니페스트
- `kubernetes/overlays/dev/`, `overlays/prod/` — 환경별 패치
- `kubernetes/overlays/local/caldera/` — **local 전용.** ADR-030 이 Caldera 의 **prod 배포를 금지**한다(Sandcat 은 기능상 원격 제어 에이전트다). base 에 두면 prod 오버레이가 그대로 상속하므로 금지가 문서에만 남는다. egress 까지 막는 이 레포 유일의 정책이 함께 있다
- `kubernetes/overlays/local/lakehouse-local/` — **local 전용 리소스.** ZooKeeper·HDFS·HBase·HiveServer2 는 매니페스트가 단일 노드를 전제(`dfs.replication=1`·비-HA·`tez.local.mode=true`)해 base 에 두지 않는다. ConfigMap 안의 XML 값은 오버레이가 부분적으로 덮을 수 없기 때문이다. 승격 조건은 그 디렉터리의 `kustomization.yaml` 머리말에 있다
- `infra/` — OpenTofu IaC. `modules/`는 Hetzner/Vultr 이중 구조이나 **Hetzner는 미완성**
- `argocd/` — AppProject, Application, Argo Events
- **cert-manager 실사용처** — `kubernetes/base/security/wazuh/wazuh-certs.yaml`(selfsigned Issuer -> CA -> 노드·admin 인증서). TODO-02 의 첫 사례다
- `scripts/security-verification/` — 보안 검증 9종
- `contracts/` — **API 계약 원천**(계약 우선, ADR-067). `openapi/`·`asyncapi/`·`schemas/`. CI 가 Spectral 로 린트하고 Apicurio 에 게시한다
- `.spectral.yaml` — 계약 스타일·거버넌스 룰셋
- `docker/` — 로컬 빌드 이미지 5종(`spark-iceberg`·`livy`·`ranger-usersync`·`hbase`·`jenkins`). `local/build-images.sh` 가 podman 으로 빌드해 k3s containerd 로 반입한다. 레지스트리에 없으므로 클러스터 재구축 시 먼저 돌려야 한다
- `v1/` — 레거시 매니페스트. **배포 금지.** 단 CI가 이 경로의 Dockerfile을 참조한다(존재하지 않음)

### ArgoCD Sync Wave (실제 값)

| Wave | 카테고리 | 주요 서비스 |
|:---:|---|---|
| 0 | network-policies, service-mesh, security/kyverno | default-deny NetPol, Istio PeerAuth/AuthzPolicy/waypoint, Kyverno 6정책 |
| 1 | database | PostgreSQL, MariaDB, MongoDB, Redis |
| 2 | messaging | Kafka KRaft, Apicurio Registry + **Registry UI**, AKHQ |
| 3 | data-lakehouse | MinIO, Trino, Hive Metastore, Spark, Livy — **ZooKeeper·HDFS·HBase·HiveServer2 는 `overlays/local/lakehouse-local/` 로 분리**(단일 노드 전제) |
| **4** | **security/keycloak · security/vault · security/wazuh** | **Keycloak, Vault, Wazuh(manager·indexer)** |
| 5 | devops · **governance** | GitLab EE · **DS389, LAM, Solr, Ranger(admin·usersync), Knox** |
| 6 | application | admin, cmmn-api, nginx |
| 7 | observability · **security-full** | **Dependency-Track(apiserver·frontend) · DefectDojo(django·nginx·celery worker·beat)** · Elasticsearch(ECK 3노드), Kibana, Logstash, Filebeat, **Prometheus, Grafana, Loki, Tempo, OTel Collector(agent·gateway)**, Falco, Falcosidekick, Trivy CronJob |
| 8 | rotation · **security-full 일부** | 로테이션 CronJob 7종 + git-sync · **Kubescape CronJob · SafeLine(mgt·detector·tengine·chaos + fvm·luigi) · Caldera**(local 전용) |

`kubernetes/base/security/namespaces/`는 **어느 kustomization에도 포함되지 않는 고아 디렉터리**다. 네임스페이스는 오버레이가 각자 정의하며 두 정의가 서로 다르다.

### Key Technology Choices

- **No Helm** — 전부 수기 YAML + Kustomize
- **Kafka KRaft** — ZooKeeper 없음. 단 `KAFKA_LOG_DIRS` 미설정으로 마운트한 PVC를 쓰지 않는다
- **Istio Ambient** — ztunnel + waypoint. **현재 dev에서 비활성이고 mTLS는 `PERMISSIVE`다**
- **ECK operator** — Elasticsearch/Kibana가 `elasticsearch.k8s.elastic.co/v1` CRD 사용. **설치 스크립트는 없다**
- **Redis** — **공식 `redis`** standalone 6 레플리카. 클러스터가 아니다
- **Multi-provider IaC** — `infra/modules/`가 count로 분기. **Vultr만 완성**

### Security Layers

0. **오퍼레이터 계층(ArgoCD 밖, `local/install-operators.sh`)** — Istio ambient · ECK · Kyverno · cert-manager · **Tetragon**(eBPF 런타임) · **Trivy Operator**(상시 취약점 스캔) · **Policy Reporter**(결과 집계). Tetragon 은 정적 매니페스트가 없어 `helm template | kubectl apply` 로 **렌더만** 한다 — 클러스터에 Helm 릴리스는 남지 않는다
1. **Admission** — Kyverno 6정책 (disallow-root, disallow-latest, disallow-privilege-escalation, require-labels, require-probes, require-resources). base는 Audit, prod는 4종만 Enforce
2. **Network** — default-deny **ingress**(egress 차단 없음) + allow 13종 + Istio AuthorizationPolicy 4종
3. **Runtime** — Falco DaemonSet(modern_ebpf) → Falcosidekick → Elasticsearch/Slack/Kafka
4. **Supply Chain** — CI의 Trivy 3잡 + Cosign 서명. **서명 검증 정책은 없다**

## 환경별 차이

| 항목 | dev | prod |
|---|---|---|
| Namespace | `dev` | `prod` |
| Replicas | Kafka 1, Redis 1 (**ES는 3 그대로**) | PostgreSQL 2, MariaDB 2, MongoDB 3, Keycloak 2, Logstash 2, nginx 2 |
| 이미지 태그 | `latest` | 핀닝 17종 (`overlays/prod/kustomization.yaml` `images:`) |
| Kyverno | 전부 Audit | disallow-root · disallow-latest · disallow-privilege-escalation · require-resources만 Enforce |
| PSS | **`enforce: privileged`** | `enforce: restricted` |
| Istio ambient | **비활성** (주석 처리) | 활성 |
| PDB | 없음 | 8종 |
| CI 배포 | `v2` 브랜치 자동 | `when: manual` — **단 ArgoCD `automated{prune,selfHeal}`이 이 게이트를 우회한다** |

## Manifest Conventions

### File Naming

서비스 디렉터리마다: `<service>-statefulset.yaml`(또는 `-deployment.yaml`/`-daemonset.yaml`), `<service>-headless.yaml`, `<service>-service.yaml`, `<service>-configmap.yaml`, `<service>-secret.enc.yaml`, `kustomization.yaml`.

> 현재 대부분의 서비스 디렉터리에는 `kustomization.yaml`이 **없다** (예외: `security/keycloak`, `security/kyverno`, `security/namespaces`). 카테고리 레벨에서 개별 파일을 나열한다.

### Required Labels

```yaml
app.kubernetes.io/name: <service>
app.kubernetes.io/component: <category>
app.kubernetes.io/part-of: oneinchmarket
app.kubernetes.io/managed-by: kustomize
```

### Required Security Context

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault
containers:
  - securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
```

**의도된 예외 8건** — GitLab(root + capability 8종), Falco(privileged + hostNetwork), Filebeat(root + `DAC_READ_SEARCH`), otel-agent(root + `DAC_READ_SEARCH`), DS389(root + `CHOWN·DAC_OVERRIDE·FOWNER·SETGID·SETUID·NET_BIND_SERVICE`), LAM(root + 앞의 5종), wazuh-manager(root + 5종 + `KILL·SYS_CHROOT`). SafeLine(root + `CHOWN·SETUID·SETGID·DAC_OVERRIDE`, tengine 은 `NET_BIND_SERVICE` 추가 — detector·tengine 엔트리포인트가 작업 디렉터리를 chown 한다). 각각 매니페스트에 사유가 기록되어 있다. **Kyverno `disallow-root` 예외 목록이 정책에 있다**(`kyverno-disallow-root.yaml` 의 `exclude` — 이름 8종 + 시스템 네임스페이스 8개). 없으면 prod Enforce 에서 8건이 거부되고, **cilium·coredns 같은 플랫폼 파드의 재생성까지 막힌다.** OpenReplay 18건은 아직 예외가 아니다 — ADR-069 승격 조건 참조

### Annotations

- `reloader.stakater.com/auto: "true"` — Secret/ConfigMap 변경 시 자동 재시작
- `argocd.argoproj.io/sync-wave: "<N>"` — 카테고리 `kustomization.yaml`의 `commonAnnotations`로 설정

## Secret Management

**현재 작동하지 않는다.**

- `.sops.yaml`의 age 수신자가 플레이스홀더(`age1xxxxx…`)다
- `*.enc.yaml` 12개가 평문 `PLACEHOLDER_ENCRYPT_WITH_SOPS` 또는 가짜 암호문(`ENC[...PLACEHOLDER...]`, `age: []`)이다
- **12개 전부 kustomization에서 주석 처리되어 렌더링 결과에 Secret이 0개다**
- `install-argocd.sh`는 CMP 플러그인을 `ksops`로 등록하는데 Application은 `kustomize-sops`를 요구한다

```bash
# 암호화 (키 생성 후)
sops --encrypt --age <PUBLIC_KEY> --input-type yaml --output-type yaml \
  input.dec.yaml > output.enc.yaml

# 복호화 (로컬 확인 전용 — .dec.yaml은 절대 커밋 금지)
sops --decrypt secret.enc.yaml > secret.dec.yaml
```

설계상 **Vault 전환이 검토되고 있다** (ADR-024). 채택 시 로테이션 CronJob 8종·git-sync·`.enc.yaml` 12개가 제거된다.

## CI/CD Pipeline (.gitlab-ci.yml)

Stages: `validate` → `build` → `scan` → `sign` → `mirror` → `deploy`

- **validate** — `kustomize build` + `kubeconform`. **kubeconform 잡은 kubeconform 이미지 안에서 `kustomize`를 실행하고 `allow_failure: true`라 게이트가 무력하다**
- **build** — `inquotient/admin`·`inquotient/cmmn-api` 빌드. **참조하는 `v1/admin/Dockerfile`·`v1/cmmn-api/Dockerfile`이 존재하지 않는다**
- **scan** — Trivy image/config/filesystem
- **sign** — Cosign (Trivy 통과 후)
- **mirror** — Skopeo (schedule 전용)
- **deploy** — ArgoCD sync. dev 자동, prod `when: manual`

Registry: `registry.oneinchmarket.co.kr` — **어떤 매니페스트도 이 레지스트리를 참조하지 않고 `imagePullSecrets`도 없다**

## Gotchas

### 배포 전 반드시 알아야 할 것

1. **Secret이 0개 렌더된다.** `secretKeyRef`를 참조하는 워크로드 8개 이상이 `CreateContainerConfigError`로 기동 실패한다
2. **오퍼레이터 설치 경로가 없다.** ECK·Kyverno·Gateway API CRD·Argo Events가 설치되지 않아 wave 0·7이 sync되지 않는다
3. **DB·롤·버킷·토픽 부트스트랩이 없다.** `postgresql-configmap.yaml`은 `oneinchmarket` DB만 만든다. Keycloak/GitLab/Apicurio/Hive Metastore가 존재하지 않는 DB에 접속한다
4. **ServiceAccount 12개가 없다.** 15개 워크로드가 존재하지 않는 SA를 지정한다
5. **storageClass `standard`가 없다.** k3s 기본은 `local-path`라 모든 PVC가 Pending에 머문다 — **로컬은 `local/storageclass-standard.yaml` 로 해소됨**(local-path 별칭). 그 SC 에 `is-default-class` 를 붙이지 않는다: k3s 내장 `local-path` 와 기본값이 둘이 되면 `storageClassName` 을 생략한 PVC 의 동작이 정의되지 않는다. 전 PVC 가 명시하도록 고쳐 두었다
6. **WSL 배포판이 유휴 시 종료된다 — 클러스터가 조용히 전멸한다.** 붙은 프로세스가 없으면 WSL 이 `systemctl poweroff` 를 넣어(`InitTerminateInstanceInternal`) k3s 가 정지하고, 다음 `wsl.exe` 명령에서 파드 110여 개가 전부 재시작한다. 증상은 "k3s 가 10분마다 크래시"로 보이나 원인은 k3s 가 아니다. **`local/keepalive.ps1` 을 먼저 띄울 것.** `.wslconfig` 의 `vmIdleTimeout` 으로는 부족하다 — 그것은 VM 유휴 타임아웃이고 이것은 배포판 종료다(그 키는 `[wsl2]` 섹션이 맞다. `[experimental]` 에 두면 조용히 무시된다)
7. **외부 진입점이 없다.** Ingress/Gateway/NodePort/LoadBalancer 객체 0개, traefik·servicelb 비활성
8. **`.ps1` 은 BOM 없이 저장하면 코드가 조용히 사라진다.** PowerShell 5.1 은 BOM 이 없는 `.ps1` 을 시스템 ANSI(CP949)로 읽는다. 한글 주석이 잘못 디코딩되면서 따옴표 짝이 어긋나 **뒤따르는 코드가 문자열 리터럴로 흡수**된다. 실측: `setup-l0-lab.ps1` 이 VM 생성 40여 줄을 잃고도 **파싱 오류 0건**으로 "완료"를 출력했다. 문법적으로 완결된 다른 프로그램이 되므로 정적 검증 수단이 없다. 추가·수정 시 `head -c3 f.ps1 | od -An -tx1` 이 `efbbbf` 인지 볼 것 — §8-30

### 매니페스트 작업 시

- `v1/` 매니페스트는 **배포 금지**. 단 CI가 이 경로의 Dockerfile을 참조한다는 모순이 있다
- prod 이미지는 태그를 핀닝해야 한다 (Kyverno `disallow-latest` Enforce). **로테이션·스캔 이미지 6종도 2026-09-01 에 `images:` 블록에 추가되었다**
- **`overlays/dev/secrets/` 디렉터리는 존재하지 않는다.** 시크릿은 base 레벨에 있다
- `*.dec.yaml`, `keys.txt`, `*.age`, TLS 인증서, `*.tfstate`를 커밋하지 말 것. **단 `v1/cluster/tls.key`에 개인키가 이미 커밋되어 있다 — SEC-401**
- ArgoCD 레포 URL은 `https://gitlab.oneinchmarket.co.kr/infra/oneinchmarket-infra.git`, 브랜치 `v2`
- `commonLabels`는 kustomize v5.8에서 deprecated다. 빌드 시 경고 8건이 발생한다
- **ArgoCD AppProject가 `security.istio.io`·`gateway.networking.k8s.io`를 화이트리스트하지 않아 `service-mesh/` 전체가 sync 거부된다**
- dev/prod 두 Application이 동일한 클러스터 범위 ClusterPolicy를 서로 다른 `validationFailureAction`으로 소유해 충돌한다

### 검증 스크립트

- `07-netpol-test.sh`는 존재하지 않는 `default-deny-all`을 찾는다 (실제 이름은 `default-deny-ingress`)
- `08-age-key-backup.sh`는 오늘 실행하면 `.sops.yaml`과 `.enc.yaml` 12건을 전부 FAIL 처리한다

### 로컬 개발

로컬 타깃(Hyper-V + k3s)은 설계 단계다 (ADR-051). 전 구성요소 동시 배포에는 **128 GB RAM**이 필요하고, 64 GB에서는 Kustomize Component 기반 프로파일 전환이 필요하다. 자세한 산정은 [docs/DEPLOYMENT.md §4](docs/DEPLOYMENT.md).
