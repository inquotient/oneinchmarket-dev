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
3. **Runtime** — Falco DaemonSet(modern_ebpf) → Falcosidekick → Elasticsearch/Kafka. **L0 랩은 Suricata(인라인·ET Open 36,818 규칙) · Zeek(포트 미러링) · ntopng 셋을 동시에 돌린다** — Suricata 는 `suricata`, Zeek 는 `zeek` 인덱스로 들어온다(§8-51). **local 에서는 Falco 가 스케줄되지 않는다** — WSL2 커널에서 modern_ebpf 가 `scap_init` 에 실패해 `nodeSelector: oneinchmarket.local/falco-supported=true` 로 비활성했다(어떤 노드에도 그 레이블이 없다). 대신 Tetragon 이 돈다(ADR-025). Slack 출력은 webhook URL 이 비어 있어 켜지지 않는다. **Falcosidekick 은 `args: ["-c", "/etc/falcosidekick/config.yaml"]` 이 없으면 설정을 읽지 못해 출력이 0개가 된다** — 파드는 Ready 로 보이고 단서는 기동 로그의 `Enabled Outputs: []` 뿐이다(§8-35)
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

**의도된 예외 8건** — GitLab(root + capability 8종), Falco(privileged + hostNetwork), Filebeat(root + `DAC_READ_SEARCH`), otel-agent(root + `DAC_READ_SEARCH`), DS389(root + `CHOWN·DAC_OVERRIDE·FOWNER·SETGID·SETUID·NET_BIND_SERVICE`), LAM(root + 앞의 5종), wazuh-manager(root + 5종 + `KILL·SYS_CHROOT`). SafeLine(root + `CHOWN·SETUID·SETGID·DAC_OVERRIDE`, tengine 은 `NET_BIND_SERVICE` 추가 — detector·tengine 엔트리포인트가 작업 디렉터리를 chown 한다). 각각 매니페스트에 사유가 기록되어 있다. **Kyverno `disallow-root` 예외 목록이 정책에 있다**(`kyverno-disallow-root.yaml` 의 `exclude` — 이름 8종 + 시스템 네임스페이스 8개). 없으면 prod Enforce 에서 8건이 거부되고, **cilium·coredns 같은 플랫폼 파드의 재생성까지 막힌다.** **OpenReplay 는 예외가 필요 없다** — 17개 Deployment 는 이미 비-root(uid 1001·65532)였고 `runAsNonRoot` 선언만 없었다. 선언을 채워 정책 위반 0건이 됐다. 실제로 root 였던 마이그레이션 Job 하나는 `CAP_CHOWN` 으로 낮췄다(§8-49)

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
2. **오퍼레이터 설치 경로가 없었다 — 지금은 `local/install-operators.sh` 가 있다.** ECK·Kyverno·cert-manager·Tetragon 이 거기서 설치된다. **Gateway API CRD 5종과 GatewayClass(istio·istio-remote·istio-waypoint)는 이미 설치되어 있다** — Istio ambient 설치가 함께 넣는다. Argo Events 는 여전히 없다
3. **DB·롤·버킷·토픽 부트스트랩이 없다.** `postgresql-configmap.yaml`은 `oneinchmarket` DB만 만든다. Keycloak/GitLab/Apicurio/Hive Metastore가 존재하지 않는 DB에 접속한다
4. **ServiceAccount 12개가 없다.** 15개 워크로드가 존재하지 않는 SA를 지정한다
5. **storageClass `standard`가 없다.** k3s 기본은 `local-path`라 모든 PVC가 Pending에 머문다 — **로컬은 `local/storageclass-standard.yaml` 로 해소됨**(local-path 별칭). 그 SC 에 `is-default-class` 를 붙이지 않는다: k3s 내장 `local-path` 와 기본값이 둘이 되면 `storageClassName` 을 생략한 PVC 의 동작이 정의되지 않는다. 전 PVC 가 명시하도록 고쳐 두었다
6. **WSL 배포판이 유휴 시 종료된다 — 클러스터가 조용히 전멸한다.** 붙은 프로세스가 없으면 WSL 이 `systemctl poweroff` 를 넣어(`InitTerminateInstanceInternal`) k3s 가 정지하고, 다음 `wsl.exe` 명령에서 파드 110여 개가 전부 재시작한다. 증상은 "k3s 가 10분마다 크래시"로 보이나 원인은 k3s 가 아니다. **`local/keepalive.ps1` 을 먼저 띄울 것.** `.wslconfig` 의 `vmIdleTimeout` 으로는 부족하다 — 그것은 VM 유휴 타임아웃이고 이것은 배포판 종료다(그 키는 `[wsl2]` 섹션이 맞다. `[experimental]` 에 두면 조용히 무시된다)
7. **외부 진입점은 Istio Gateway 로 섰다(ADR-071).** `ingress` Gateway 가 NodePort 로 443·80 을 받고 cert-manager 가 TLS 를 발급한다. traefik·servicelb 는 여전히 비활성이므로 `networking.istio.io/service-type: NodePort` 가 필수다 — LoadBalancer 로 두면 Service 가 영원히 Pending 이다. **OpenReplay 의 Ingress 12개는 여전히 죽어 있다** — `ingressClassName: openreplay` 인데 그런 IngressClass 도 컨트롤러도 없다
8. **`.ps1` 은 BOM 없이 저장하면 코드가 조용히 사라진다.** PowerShell 5.1 은 BOM 이 없는 `.ps1` 을 시스템 ANSI(CP949)로 읽는다. 한글 주석이 잘못 디코딩되면서 따옴표 짝이 어긋나 **뒤따르는 코드가 문자열 리터럴로 흡수**된다. 실측: `setup-l0-lab.ps1` 이 VM 생성 40여 줄을 잃고도 **파싱 오류 0건**으로 "완료"를 출력했다. 문법적으로 완결된 다른 프로그램이 되므로 정적 검증 수단이 없다. 추가·수정 시 `head -c3 f.ps1 | od -An -tx1` 이 `efbbbf` 인지 볼 것 — §8-30

9. **Istio AuthorizationPolicy 의 principal 에 중간 `*` 를 쓰지 말 것.** Istio 문자열 매칭은 완전 일치·접두(`abc*`)·접미(`*abc`)·존재(`*`)만 지원한다. **중간 `*` 는 리터럴이다.** `cluster.local/ns/*/sa/keycloak` 은 아무것도 매칭하지 않는다. ALLOW 정책이 워크로드를 선택하면 매칭되지 않은 전부가 거부되므로, 네임스페이스를 ambient 에 편입하는 순간 해당 정책이 **전면 거부**로 바뀐다. 실측: 26곳 전부가 이 형태였고 편입 때마다 15개 파드가 동시에 무너졌다. base 는 네임스페이스를 모르므로 접미 매칭 `*/sa/<name>` 을 쓴다 — §8-47
10. **ambient 에서 ServiceAccount 는 곧 신원이다.** `default` SA 로 도는 워크로드는 서로 구분되지 않아 정책을 쓸 수 없다 — 하나에게 권한을 주면 그 SA 를 공유하는 전부에게 준다. 새 워크로드에는 반드시 전용 SA 를 줄 것. 메시 밖 네임스페이스에서 오는 트래픽은 **신원이 아예 없어** principal 규칙이 어느 것도 매칭되지 않는다(ECK 오퍼레이터가 그랬다) — §8-47

11. **Ranger 는 로그인 실패가 누적되면 계정을 영구히 잠근다.** 증상은 그냥 401 이고, `x_auth_sess` 의 연속 실패 기록에서 파생되므로 **파드를 재시작해도 풀리지 않는다.** `x_portal_user.status` 는 `1`(정상) 그대로라 사용자 테이블만 봐서는 알 수 없다. 단서는 로그의 `User account is locked` 한 줄뿐이고 **끄는 설정이 없다**(jar 에 관련 property 가 없다). 푸는 방법은 ranger DB 에서 해당 사용자의 `auth_status` 2·4 행을 지우는 것뿐이다. **Ranger 로그인을 두드리는 자동화를 두지 말 것** — 관리자가 잠긴다 — §8-48

12. **성공 출력이 성공을 뜻하지 않는 경로가 반복해서 나온다.** `configctl ids update` 는 `OK` 를 출력하고 룰을 하나도 받지 않았다(config.xml 을 직접 고쳐 `configctl template reload OPNsense/IDS` 를 거치지 않으면 `rule-updater.config` 가 비어 있다). Suricata 알림이 Elasticsearch 로 가는 경로는 **파드를 재생성하면 `kubectl port-forward` 가 죽어** 14시간 조용히 끊겨 있었고, 방화벽 쪽에는 아무 오류도 나지 않았다. **파이프라인은 건수가 아니라 최신 문서 시각으로 확인할 것** — §8-50

13. **ambient 편입은 통신 경로를 15008(HBONE)로 바꾼다.** 목적지 포트를 NetworkPolicy 로 열어 두어도 15008 이 막히면 못 간다. 차단은 **거부가 아니라 타임아웃**이라 정책을 의심하기 어렵다. `allow-istio-hbone` 을 같은 네임스페이스로 좁히면 **네임스페이스를 넘는 메시 통신이 전부 끊긴다** — 실측으로 ECK 오퍼레이터가 Elasticsearch 를 관리하지 못했고(9200 은 열려 있었다), argo-events→Kafka 도 같은 상태였다. 15008 은 넓게 열 것: 그 포트는 메시의 전송 계층이고 **실제 인가는 ztunnel 이 AuthorizationPolicy 로 한다** — §8-52
14. **단일 노드 ES 에서 복제본 1 은 배포를 멈춘다.** 배정될 노드가 없어 클러스터가 영구히 yellow 이고, **ECK 는 green 이 아니면 파드를 롤링하지 않는다.** 증상은 "매니페스트를 고쳤는데 파드가 안 바뀐다" 이고 오류는 나지 않는다. local 오버레이가 `ES_REPLICAS=0` 으로 덮는다. `index_patterns: ["*"]` 인 catch-all 템플릿은 ES 가 거부하므로(패턴 충돌) 쓰는 이름을 명시할 것 — §8-52

15. **API 과금은 계량 지점이 있어야 성립하고, 그 지점은 L7 이어야 한다.** ztunnel 은 L4 라 요청 단위가 보이지 않고, waypoint 는 떠 있어도 `use-waypoint` 워크로드가 0이면 경로에 없는 것이다. 계량 지점을 나중에 바꾸면 이벤트 스키마와 **이미 청구한 이력**이 함께 흔들린다 — 청구는 소급 재해석이 불가능하다. 그래서 외부 트래픽 수용보다 게이트웨이가 먼저다(ADR-071·072). 액세스 로그 형식이 곧 계약이므로 `contracts/schemas/api-usage-event.json` 을 먼저 고치고 `local/configure-istio-usage-logging.sh` 가 따라오게 할 것. **`logFormat.labels` 를 쓰지 말 것** — 값이 전부 문자열이 되어 `status` 가 `"200"` 으로 나가고 스키마를 깬다. `text` 에 원시 JSON 을 넣어야 정수가 정수로 나간다
16. **Kafka 는 at-least-once 다 — 과금 이벤트에는 멱등성 키가 필수다.** 같은 이벤트가 반드시 두 번 이상 오고, 중복을 제거하지 않으면 **고객에게 과다 청구한다.** 키는 Envoy 의 `x-request-id`(요청당 유일)를 쓴다. 타임스탬프나 순번을 키로 쓰지 말 것. 그리고 `subject`(청구 대상) 헤더가 없으면 Envoy 가 `-` 를 넣는다 — 소비자는 그런 이벤트를 **청구하지 말고 격리**해야 한다

17. **JWKS 를 가져오는 것은 게이트웨이가 아니라 istiod 다.** `RequestAuthentication.jwksUri` 에 단축 서비스명을 쓰면 `istio-system` 에서 풀리지 않아 실패한다 — **FQDN 이어야 한다.** `issuer` 는 토큰의 `iss` 와 맞춰야 하므로 두 필드의 값이 달라도 된다. 그리고 istiod 는 메시 밖이라 대상 서비스에 **평문으로** 접근하므로 NetworkPolicy 허용이 따로 필요하다(메시 안에서는 HBONE 15008 로 흘러 잘 되기 때문에 "규칙 없이도 된다" 로 오해하기 쉽다). 증상은 두 경우 모두 **유효한 토큰이 전부 401** 이고, 게이트웨이 로그에는 단서가 없고 istiod 로그에만 남는다. ★ 정책을 고친 뒤 **istiod 를 재시작해야 한다** — JWKS 실패를 캐시하고 곧바로 재시도하지 않는다 — §8-54
18. **RequestAuthentication 만으로는 인증이 강제되지 않는다.** 그것은 "토큰이 있으면 검증한다" 일 뿐이고 **토큰이 없는 요청은 그냥 통과한다.** 과금 대상 경로에서 그것은 무료 통행이다. `AuthorizationPolicy` 에 `requestPrincipals: ["*"]` 를 함께 두어야 한다. 그리고 그 ALLOW 정책이 게이트웨이를 선택하는 순간 **매칭되지 않은 다른 호스트가 전면 거부**되므로 `notHosts` 규칙을 함께 둘 것 — §8-54

19. **부트스트랩 Job 은 `default` SA 로 도는지 반드시 확인할 것.** 지금까지 세 건이 같은 결함이었다 — `elasticsearch-ilm-setup`(ES 9200) · `databases-migrate`(PostgreSQL·ClickHouse) · `kafka-topics`(Kafka 9092). **Job 은 평소에 돌지 않아 ambient 편입 시점에 드러나지 않고, 재실행할 때 비로소 ztunnel 이 거부한다.** 클러스터를 다시 세울 때가 그때다 — §8-52·§8-55
20. **OTel 수집기 설정 두 가지 함정.** ① 파이프라인을 `service.pipelines` 가 아니라 `service.telemetry` 아래에 넣으면 `'service.telemetry' has invalid keys` 로 기동하지 않는다(둘 다 `metrics:` 키를 갖고 있어 자동 편집 시 헷갈린다). ② 최신 contrib 의 Kafka exporter 는 `topic`·`encoding` 을 **신호별 블록**(`logs:`) 아래로 옮겼다. 최상위에 두면 `'kafkaexporter.Config' has invalid keys` 다. 파이프라인 동작 여부는 로그가 아니라 **`otelcol_receiver_accepted_log_records` 지표**로 판정할 것 — 수신기가 0건이어도 오류는 나지 않는다 — §8-55

21. **Istio 의 `envoyOtelAls`(Envoy OTel 액세스 로그)는 이 조합에서 동작하지 않는다.** Istio 1.24.2 + OTel 수집기 0.160 에서 gRPC 스트림이 `upstream reset: protocol error` 로 끊긴다. 설정은 정확하고(config_dump 확인) 클러스터 엔드포인트는 healthy 이며 ztunnel 구간도 무오류인데 **수신기가 한 건도 받지 못한다.** 게이트웨이·수집기를 ambient 에서 빼도 같다. 대신 **게이트웨이 stdout 을 겨냥한 전용 filelog 수신기**를 쓴다 — 일반 filelog 와 수신기 자체를 분리할 것(필터로 가르면 조용히 어긋날 때 청구 데이터가 오염된다) — §8-55
22. **Kafka exporter 의 `raw` 인코딩은 문자열 본문을 JSON 으로 한 번 더 감싼다.** 토픽의 첫 바이트가 `{` 가 아니라 `"` 가 되어 소비자가 두 번 파싱해야 한다. `encoding: text` 는 없다(`unrecognized logs encoding`). **`json_parser` 로 본문을 맵으로 만들면** `raw` 가 그대로 직렬화한다. 그리고 filelog 의 `container` 연산자가 실패하면(`Failed to process entry`) CRI 접두가 그대로 메시지에 남으므로 `regex_parser` 로 직접 뗄 것. 필터의 `expr` 은 자체 이스케이프 규칙이 있어 정규식에 백슬래시를 쓰면 수집기가 기동하지 않는다 — §8-55

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
