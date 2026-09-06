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
| [docs/LOCAL-DEPLOYMENT.md](docs/LOCAL-DEPLOYMENT.md) | **브랜치 `local`.** WSL2 단일 노드 k3s + zram (B안). **§8 에 실배포 기록** — WSL2 고유 블로커 3건, 결함 32건 해소. **§9 는 뒤로 미룬 일** — 지금 하지 않기로 **결정한** 목록이다(잊은 것이 아니다). 새 작업을 시작하기 전에 볼 것 |
| [local/ACCESS.md](local/ACCESS.md) | **Windows 에서 접근하는 법.** UI 40여 종의 port-forward·URL·계정 + DBeaver 용 DB 접속 정보. 비밀번호는 값이 아니라 **조회 명령**으로 적혀 있다 |
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
- `docker/` — 로컬 빌드 이미지 8종(`spark-iceberg`·`livy`·`ranger-usersync`·`hbase`·`jenkins`·`ranger-hdfs-plugin`·`ranger-hbase-plugin`·`ranger-hive-plugin`). `local/build-images.sh` 가 podman 으로 빌드해 k3s containerd 로 반입한다. 레지스트리에 없으므로 클러스터 재구축 시 먼저 돌려야 한다. **매니페스트가 참조하는 버전 태그를 반입 목록에 반드시 넣을 것** — `:latest` 만 넣으면 ImagePullBackOff 다(§8-72)
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
- **Istio Ambient** — ztunnel + waypoint. **현재 dev에서 비활성이고 mTLS는 `PERMISSIVE`다**. local 은 **1.31.0**, k3s 는 **v1.36.4+k3s1** 이다 — 이 둘은 **짝이 맞아야 한다**(§8-73, Gotcha 47)
- **ECK operator** — Elasticsearch/Kibana가 `elasticsearch.k8s.elastic.co/v1` CRD 사용. **설치 스크립트는 없다**
- **Redis** — **공식 `redis`** standalone 6 레플리카. 클러스터가 아니다
- **Multi-provider IaC** — `infra/modules/`가 count로 분기. **Vultr만 완성**

### Security Layers

0. **오퍼레이터 계층(ArgoCD 밖, `local/install-operators.sh`)** — Istio ambient · ECK · Kyverno · cert-manager · **Tetragon**(eBPF 런타임) · **Trivy Operator**(상시 취약점 스캔) · **Policy Reporter**(결과 집계). Tetragon 은 정적 매니페스트가 없어 `helm template | kubectl apply` 로 **렌더만** 한다 — 클러스터에 Helm 릴리스는 남지 않는다
1. **Admission** — Kyverno 6정책 (disallow-root, disallow-latest, disallow-privilege-escalation, require-labels, require-probes, require-resources). base는 Audit, prod는 4종만 Enforce
2. **Network** — default-deny **ingress**(egress 차단 없음) + allow 13종 + Istio AuthorizationPolicy 4종
3. **Runtime** — Falco DaemonSet(modern_ebpf) → Falcosidekick → Elasticsearch/Kafka. **L0 랩은 Suricata(인라인·ET Open 36,818 규칙) · Zeek(포트 미러링) · ntopng 셋을 동시에 돌린다** — Suricata 는 `suricata`, Zeek 는 `zeek` 인덱스로 들어온다(§8-51). **local 에서도 Falco 가 돈다(§8-64).** 오래도록 "WSL2 커널에서 modern_ebpf 가 `scap_init` 에 실패한다" 로 비활성돼 있었으나, 원인은 커널이 아니라 **이미지가 2024년판에 멈춰 있었던 것**이다 — `falcosecurity/falco-no-driver` 는 0.39.2(2024-11-21) 에서 버려졌고 유지되는 저장소는 `falcosecurity/falco`(0.44.1)다. Tetragon 도 계속 돈다(ADR-025) — 둘은 대체재가 아니라 병행이다. Slack 출력은 webhook URL 이 비어 있어 켜지지 않는다. **Falcosidekick 은 `args: ["-c", "/etc/falcosidekick/config.yaml"]` 이 없으면 설정을 읽지 못해 출력이 0개가 된다** — 파드는 Ready 로 보이고 단서는 기동 로그의 `Enabled Outputs: []` 뿐이다(§8-35)
4. **Supply Chain** — CI의 Trivy 3잡 + Cosign 서명. **서명 검증 정책은 없다**

## 환경별 차이

| 항목 | dev | prod |
|---|---|---|
| Namespace | `dev` | `prod` |
| Replicas | Kafka 1, Redis 1 (**ES는 3 그대로**) | PostgreSQL 2, MariaDB 2, MongoDB 3, Keycloak 2, Logstash 2, nginx 2 |
| 이미지 태그 | **차이 없음 — base 매니페스트가 전부 고정한다**(§8-72). `overlays/prod` 의 `images:` 블록은 제거했다 | 동일 |
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

   ★ **`.sh` 에도 같은 부류가 있다.** `local/build-images.sh` 안에 줄바꿈 대신 **문자 그대로의 `\n`** 이 두 곳 박혀 있었다(`podman build ... host \n  -t ...`). `bash -n` 은 **통과한다** — `\n` 이 `n` 으로 해석되어 문법적으로 완결된 다른 명령이 되기 때문이다(`n` 이 인자로 podman 에 넘어간다). 그 스크립트를 직접 돌린 적이 없어 오래 드러나지 않았다. 판정은 `grep -c -F \\n <file>` 로 한다 — §8-71

9. **Istio AuthorizationPolicy 의 principal 에 중간 `*` 를 쓰지 말 것.** Istio 문자열 매칭은 완전 일치·접두(`abc*`)·접미(`*abc`)·존재(`*`)만 지원한다. **중간 `*` 는 리터럴이다.** `cluster.local/ns/*/sa/keycloak` 은 아무것도 매칭하지 않는다. ALLOW 정책이 워크로드를 선택하면 매칭되지 않은 전부가 거부되므로, 네임스페이스를 ambient 에 편입하는 순간 해당 정책이 **전면 거부**로 바뀐다. 실측: 26곳 전부가 이 형태였고 편입 때마다 15개 파드가 동시에 무너졌다. base 는 네임스페이스를 모르므로 접미 매칭 `*/sa/<name>` 을 쓴다 — §8-47
10. **ambient 에서 ServiceAccount 는 곧 신원이다.** `default` SA 로 도는 워크로드는 서로 구분되지 않아 정책을 쓸 수 없다 — 하나에게 권한을 주면 그 SA 를 공유하는 전부에게 준다. 새 워크로드에는 반드시 전용 SA 를 줄 것. 메시 밖 네임스페이스에서 오는 트래픽은 **신원이 아예 없어** principal 규칙이 어느 것도 매칭되지 않는다(ECK 오퍼레이터가 그랬다) — §8-47

11. **Ranger 는 로그인 실패가 누적되면 계정을 영구히 잠근다.** 증상은 그냥 401 이고, `x_auth_sess` 의 연속 실패 기록에서 파생되므로 **파드를 재시작해도 풀리지 않는다.** `x_portal_user.status` 는 `1`(정상) 그대로라 사용자 테이블만 봐서는 알 수 없다. 단서는 로그의 `User account is locked` 한 줄뿐이고 **끄는 설정이 없다**(jar 에 관련 property 가 없다). 푸는 방법은 ranger DB 에서 해당 사용자의 `auth_status` 2·4 행을 지우는 것뿐이다. **Ranger 로그인을 두드리는 자동화를 두지 말 것** — 관리자가 잠긴다. ★ **그 자동화는 이미지 안에 있었다** — `create-ranger-services.py` 5번째 줄이 `('admin', 'rangerR0cks!')` 로 관리자 자격을 **하드코딩**한다. 우리는 자격을 분리해 실제 비밀번호를 쓰므로 데모 서비스 등록 9건이 전부 401 이고, 그 연속 실패가 계정을 잠근다. `.setupDone` 이 PVC 에 없어 setup 은 **파드를 새로 만들 때마다** 도니 **재기동할 때마다 잠겼다.** 기동 래퍼가 그 호출을 제거한다(제거하지 못하면 기동하지 않는다) — §8-48·§8-67

12. **성공 출력이 성공을 뜻하지 않는 경로가 반복해서 나온다.** `configctl ids update` 는 `OK` 를 출력하고 룰을 하나도 받지 않았다(config.xml 을 직접 고쳐 `configctl template reload OPNsense/IDS` 를 거치지 않으면 `rule-updater.config` 가 비어 있다). Suricata 알림이 Elasticsearch 로 가는 경로는 **파드를 재생성하면 `kubectl port-forward` 가 죽어** 14시간 조용히 끊겨 있었고, 방화벽 쪽에는 아무 오류도 나지 않았다. **파이프라인은 건수가 아니라 최신 문서 시각으로 확인할 것** — §8-50

13. **ambient 편입은 통신 경로를 15008(HBONE)로 바꾼다.** 목적지 포트를 NetworkPolicy 로 열어 두어도 15008 이 막히면 못 간다. 차단은 **거부가 아니라 타임아웃**이라 정책을 의심하기 어렵다. `allow-istio-hbone` 을 같은 네임스페이스로 좁히면 **네임스페이스를 넘는 메시 통신이 전부 끊긴다** — 실측으로 ECK 오퍼레이터가 Elasticsearch 를 관리하지 못했고(9200 은 열려 있었다), argo-events→Kafka 도 같은 상태였다. 15008 은 넓게 열 것: 그 포트는 메시의 전송 계층이고 **실제 인가는 ztunnel 이 AuthorizationPolicy 로 한다** — §8-52
14. **단일 노드 ES 에서 복제본 1 은 배포를 멈춘다.** 배정될 노드가 없어 클러스터가 영구히 yellow 이고, **ECK 는 green 이 아니면 파드를 롤링하지 않는다.** 증상은 "매니페스트를 고쳤는데 파드가 안 바뀐다" 이고 오류는 나지 않는다. local 오버레이가 `ES_REPLICAS=0` 으로 덮는다. `index_patterns: ["*"]` 인 catch-all 템플릿은 ES 가 거부하므로(패턴 충돌) 쓰는 이름을 명시할 것 — §8-52

15. **API 과금은 계량 지점이 있어야 성립하고, 그 지점은 L7 이어야 한다.** ztunnel 은 L4 라 요청 단위가 보이지 않고, waypoint 는 떠 있어도 `use-waypoint` 워크로드가 0이면 경로에 없는 것이다. 계량 지점을 나중에 바꾸면 이벤트 스키마와 **이미 청구한 이력**이 함께 흔들린다 — 청구는 소급 재해석이 불가능하다. 그래서 외부 트래픽 수용보다 게이트웨이가 먼저다(ADR-071·072). 액세스 로그 형식이 곧 계약이므로 `contracts/schemas/api-usage-event.json` 을 먼저 고치고 `local/configure-istio-usage-logging.sh` 가 따라오게 할 것. **`logFormat.labels` 를 쓰지 말 것** — 값이 전부 문자열이 되어 `status` 가 `"200"` 으로 나가고 스키마를 깬다. `text` 에 원시 JSON 을 넣어야 정수가 정수로 나간다
16. **Kafka 는 at-least-once 다 — 과금 이벤트에는 멱등성 키가 필수다.** 같은 이벤트가 반드시 두 번 이상 오고, 중복을 제거하지 않으면 **고객에게 과다 청구한다.** 키는 Envoy 의 `x-request-id`(요청당 유일)를 쓴다. 타임스탬프나 순번을 키로 쓰지 말 것. 그리고 `subject`(청구 대상) 헤더가 없으면 Envoy 가 `-` 를 넣는다 — 소비자는 그런 이벤트를 **청구하지 말고 격리**해야 한다

17. **JWKS 를 가져오는 것은 게이트웨이가 아니라 istiod 다.** `RequestAuthentication.jwksUri` 에 단축 서비스명을 쓰면 `istio-system` 에서 풀리지 않아 실패한다 — **FQDN 이어야 한다.** `issuer` 는 토큰의 `iss` 와 맞춰야 하므로 두 필드의 값이 달라도 된다. 그리고 istiod 는 메시 밖이라 대상 서비스에 **평문으로** 접근하므로 NetworkPolicy 허용이 따로 필요하다(메시 안에서는 HBONE 15008 로 흘러 잘 되기 때문에 "규칙 없이도 된다" 로 오해하기 쉽다). 증상은 두 경우 모두 **유효한 토큰이 전부 401** 이고, 게이트웨이 로그에는 단서가 없고 istiod 로그에만 남는다. ★ 정책을 고친 뒤 **istiod 를 재시작해야 한다** — JWKS 실패를 캐시하고 곧바로 재시도하지 않는다 — §8-54
18. **RequestAuthentication 만으로는 인증이 강제되지 않는다.** 그것은 "토큰이 있으면 검증한다" 일 뿐이고 **토큰이 없는 요청은 그냥 통과한다.** 과금 대상 경로에서 그것은 무료 통행이다. `AuthorizationPolicy` 에 `requestPrincipals: ["*"]` 를 함께 두어야 한다. 그리고 그 ALLOW 정책이 게이트웨이를 선택하는 순간 **매칭되지 않은 다른 호스트가 전면 거부**되므로 `notHosts` 규칙을 함께 둘 것 — §8-54

19. **부트스트랩 Job 은 `default` SA 로 도는지 반드시 확인할 것.** 지금까지 **네 건**이 같은 결함이었다 — `elasticsearch-ilm-setup`(ES 9200) · `databases-migrate`(PostgreSQL·ClickHouse) · `kafka-topics`(Kafka 9092) · `hive-schematool`(PostgreSQL 5432, §8-71). ★ 네 번째에서 알게 된 것: **Job 안의 TCP 사전 검사는 통과한다** — ztunnel 은 15008 에서 끊으므로 포트 열림 검사로 드러나지 않고, 증상이 `PSQLException: The connection attempt failed` 라 DB·드라이버·자격을 의심하게 된다. **Job 은 평소에 돌지 않아 ambient 편입 시점에 드러나지 않고, 재실행할 때 비로소 ztunnel 이 거부한다.** 클러스터를 다시 세울 때가 그때다 — §8-52·§8-55
20. **OTel 수집기 설정 두 가지 함정.** ① 파이프라인을 `service.pipelines` 가 아니라 `service.telemetry` 아래에 넣으면 `'service.telemetry' has invalid keys` 로 기동하지 않는다(둘 다 `metrics:` 키를 갖고 있어 자동 편집 시 헷갈린다). ② 최신 contrib 의 Kafka exporter 는 `topic`·`encoding` 을 **신호별 블록**(`logs:`) 아래로 옮겼다. 최상위에 두면 `'kafkaexporter.Config' has invalid keys` 다. 파이프라인 동작 여부는 로그가 아니라 **`otelcol_receiver_accepted_log_records` 지표**로 판정할 것 — 수신기가 0건이어도 오류는 나지 않는다 — §8-55

21. **Istio 의 `envoyOtelAls`(Envoy OTel 액세스 로그)는 이 조합에서 동작하지 않는다.** Istio 1.24.2 + OTel 수집기 0.160 에서 gRPC 스트림이 `upstream reset: protocol error` 로 끊긴다. 설정은 정확하고(config_dump 확인) 클러스터 엔드포인트는 healthy 이며 ztunnel 구간도 무오류인데 **수신기가 한 건도 받지 못한다.** 게이트웨이·수집기를 ambient 에서 빼도 같다. 대신 **게이트웨이 stdout 을 겨냥한 전용 filelog 수신기**를 쓴다 — 일반 filelog 와 수신기 자체를 분리할 것(필터로 가르면 조용히 어긋날 때 청구 데이터가 오염된다) — §8-55
22. **Kafka exporter 의 `raw` 인코딩은 문자열 본문을 JSON 으로 한 번 더 감싼다.** 토픽의 첫 바이트가 `{` 가 아니라 `"` 가 되어 소비자가 두 번 파싱해야 한다. `encoding: text` 는 없다(`unrecognized logs encoding`). **`json_parser` 로 본문을 맵으로 만들면** `raw` 가 그대로 직렬화한다. 그리고 filelog 의 `container` 연산자가 실패하면(`Failed to process entry`) CRI 접두가 그대로 메시지에 남으므로 `regex_parser` 로 직접 뗄 것. 필터의 `expr` 은 자체 이스케이프 규칙이 있어 정규식에 백슬래시를 쓰면 수집기가 기동하지 않는다 — §8-55

23. **과금 토픽에 대고 실험하지 말 것.** 인코딩을 `otlp_json` 으로 잠깐 바꿔 시험했더니 OTLP 봉투가 씌워진 메시지 2건이 토픽에 영구히 남아 계약 검증이 29건 중 2건 실패했다. 랩이라 토픽을 재생성했지만 운영에서는 그럴 수 없다. **별도 토픽에서 검증하고 옮길 것.** 그리고 소비자는 계약을 만족하지 않는 메시지를 **청구하지 말고 격리**해야 한다(`subject` 가 `-` 인 이벤트와 같은 취급) — §8-56
24. **stanza 연산자의 필드 표기는 OTTL 과 다르다.** filelog 의 `copy`/`move` 등에서 `resource["tenant"]` 는 **오류 없이 조용히 빗나간다** — `resource.tenant` 가 맞다. 붙었는지는 `debug` exporter(`verbosity: detailed`)로 `Resource attributes` 를 직접 볼 것. 참고로 `partition_logs_by_resource_attributes` 는 최상위에서만 유효하지만(신호 블록 아래면 기동 실패), **최상위에 두어도 raw·otlp_json 어느 인코딩에서도 메시지 key 가 생기지 않았다** — §8-56

25. **컨테이너 로그 회전을 `mv`+`touch` 로 흉내내지 말 것.** 프로세스의 fd 는 `mv` 를 따라가지 않아 새 파일이 0바이트로 남는다. 실측에서 "회전 시 4건 유실" 로 보였으나 **그 4건은 애초에 새 파일에 쓰이지 않았다** — 파이프라인 결함이 아니라 시험 방법의 결함이었다. 실제 kubelet 회전은 컨테이너 런타임이 파일 전환까지 처리하므로 다르다. **측정값이 이상하면 측정 방법부터 의심할 것** — §8-57

26. **OpenMeter 는 설정 파일이 유일한 경로다 — 환경변수 오버라이드가 먹지 않는다.** 네 가지 표기법을 실측했고 전부 무시됐다. 차트에 `extraEnv` 도 secret 마운트도 없다. 평문 비밀번호를 ConfigMap 에 두지 않으려면 **ranger-usersync 와 같은 자리표시자+initContainer 치환**을 쓸 것(`local/render-openmeter.py`). 그리고 **`ingest.kafka.broker`(단수)와 `sink.kafka.brokers`(복수)는 다른 키다** — ingest 만 설정하면 sink-worker 가 기본값 `127.0.0.1:29092` 로 붙어 CrashLoop 하고 오류는 그 파드 로그에만 나온다 — §8-58
27. **ClickHouse 의 `default` 사용자가 이 인스턴스에는 없다.** 로컬 `clickhouse-client` 가 자격 없이 붙는 것에 속기 쉬운데, 원격 접속은 `system.users` 에 있는 실제 사용자가 필요하다(`code: 516 ... there is no user with such name`). 새 소비자에게는 전용 사용자를 만들고 `GRANT ALL ON <db>.*` 로 범위를 좁힐 것 — §8-58

28. **Logstash `http` 출력에서 `format => "message"` 는 Content-Type 을 `text/plain` 으로 강제한다.** `headers => { "Content-Type" => ... }` 로 넣어도 덮인다 — 전용 `content_type` 설정을 써야 한다. OpenMeter 는 `400 header Content-Type has unexpected value "text/plain"` 으로 거부한다. 원문을 그대로 보내야 할 때(CloudEvents 등) `format => json` 을 쓰면 Logstash 가 `@timestamp`·`@version`·`tags` 를 덧붙여 계약이 깨지므로 `plain` 코덱 + `message` 형식이 맞다 — §8-59

29. **OpenMeter 미터의 JSONPath 기준점은 이벤트 전체가 아니라 `data` 내부다.** `$.data.route` 로 쓰면 **오류 없이 조용히 빈 문자열**이 되어 groupBy 가 전부 `""` 로 뭉개진다 — 그 상태로 인보이스를 내면 5xx 를 제외할 수 없다. `$.route` 가 맞다. 미터 정의는 **PostgreSQL 에 저장**되어 설정만 바꿔서는 갱신되지 않고, 불일치 시 OpenMeter 가 **기동을 거부한다**(`group by mismatch`) — DB 행을 지우고 재기동할 것 — §8-60
30. **Logstash `mutate` 의 `add_field` 는 기존 필드에 배열로 덧붙는다.** 값을 바꾸려면 `replace` 를 써야 한다. `[@metadata][pipeline]` 같은 분기 키에 `add_field` 를 쓰면 조건이 조용히 어긋난다 — §8-60

31. **전달 실패를 분기하려면 `http` 출력이 아니라 `http` 필터를 쓸 것.** 출력 플러그인은 재시도 후 영구 실패 시 이벤트를 버리고 로그 한 줄만 남긴다 — 파이프라인에 실패를 돌려주지 않아 dead-letter 분기를 만들 수 없다. 과금처럼 유실이 곧 매출 누락인 경로에서는 필터로 POST 하고 `tag_on_request_failure` 태그로 분기해 DLQ 인덱스에 남길 것. **DLQ 는 재처리 가능한 원문(`message`)을 담아야 한다** — 담지 않으면 기록일 뿐 복구 수단이 아니다. 필터에는 `target_response_code`·`retryable_codes` 가 없다(후자는 출력 전용) — 쓰면 기동 실패한다 — §8-61

32. **경보 수단이 없으면 Job 실패를 신호로 쓸 것 — 다만 그것이 밀어내는 경보가 아님을 알고 쓸 것.** ~~이 클러스터에는 alertmanager·Prometheus 경보 규칙이 하나도 없다~~ — **§8-63 에서 생겼다(Gotcha 33). 아래 서술은 그 이전 상태다.** elasticsearch exporter 는 여전히 없다. `openmeter-dlq-replay` CronJob 은 재처리 후 남은 건수가 임계를 넘으면 `exit 1` 해서 Job 실패로 드러낸다. ★ 그런 Job 을 짤 때는 **연결 오류를 반드시 잡을 것** — 미처리 예외로 죽으면 Job 은 실패하지만 이미 처리한 건의 정리도, 임계 판정 로그도 남지 않는다(실측: `ConnectionResetError`). 재처리 중복은 OpenMeter 의 `id` 기반 중복 제거가 잡으므로 **"확실하지 않으면 다시 보낸다" 가 옳다** — 유실은 매출 누락이지만 중복은 잡힌다 — §8-62

33. **Alertmanager 는 receiver 가 비어 있어도 오류를 내지 않는다.** Slack·SMTP 가 없다고 receiver 를 비워 두면 경보가 **조용히 사라진다** — Falcosidekick `Enabled Outputs: []`(§8-35), Envoy ALS 수신 0건(§8-55)과 같은 부류다. 이 클러스터는 webhook 으로 Logstash(5142)를 거쳐 Elasticsearch `alerts` 인덱스에 남긴다. webhook 페이로드는 **alerts 배열**이므로 `split` 하지 않으면 "몇 건이 울렸나"를 셀 수 없다. 그리고 `@timestamp` 를 수신 시각으로 두지 말 것 — Alertmanager 는 `group_wait`·`group_interval` 만큼 늦춰 보내고 같은 경보를 `repeat_interval`(4h)마다 **다시** 보내므로 재전송분이 전부 "새 경보"로 보인다. `[alerts][startsAt]` 을 쓸 것 — §8-63
34. **Logstash 가 즉석 생성하는 인덱스는 전부 클러스터를 yellow 로 묶는다.** Gotcha 14 의 반복이다 — 템플릿이 없으면 ES 기본값인 복제본 1 이 붙고 단일 노드에는 배정될 곳이 없다. yellow 면 **ECK 가 파드를 롤링하지 않는다.** 실측으로 `alerts`·`api-usage-dlq`·`api-usage-quarantine` 셋이 그랬다. 새 인덱스 이름을 쓸 때는 `elasticsearch-ilm-setup` 에 함께 넣을 것. **템플릿은 생성 시점에만 적용되므로** 이미 만들어진 인덱스에는 `_settings` 를 따로 한 번 더 밀어야 한다 — §8-63

35. **prod 의 `replicas: 2`·`3` 은 DB 3종에서 HA 가 아니라 데이터 분기다.** `postgresql`·`mariadb`·`mongodb` 는 StatefulSet + `volumeClaimTemplates` 라 **파드마다 별도 PVC** 를 받고, 복제 설정이 **하나도 없다**(`wal_level`·patroni·repmgr·`wsrep`·`replSet` 전무). 서비스는 헤드리스라 DNS 가 두 파드 IP 를 모두 준다. 소비자는 실측 **34곳 전부가 서비스 이름**으로 붙고 특정 파드를 지정한 곳은 0곳이다. 즉 올리는 순간 **빈 DB 가 하나 더 생기고 쓰기가 둘로 갈린다** — 접속은 성공하므로 오류가 나지 않는다. prod 는 배포된 적이 없어 드러난 적도 없다. 고치기 전까지 **DB 3종의 replicas 를 올리지 말 것**. 근본 원인은 ADR-015(스토리지)가 `Open` 이라는 것이다 — 분산 스토리지 없이는 상태 있는 워크로드의 HA 가 성립하지 않는다 — §11-3

36. **Ranger 정책 다운로드는 자격으로 뚫는 경로가 아니다.** 플러그인이 `{"statusCode":400,"msgDesc":"Unauthenticated access not allowed"}` 를 받으면 자격 문제로 읽히지만 **아니다.** `security-applicationContext.xml` 이 `/service/plugins/policies/download/*` 를 `security="none"` 으로 빼서 Spring Security 가 아예 돌지 않고, `RangerBizUtil.failUnauthenticatedDownloadIfNotAllowed()` 는 **UserSession 이 null 이면 무조건 던진다.** 즉 basic auth 로는 **관리자 자격으로도** 통과할 수 없다(실측: admin 도 같은 400, 반면 `/service/xusers/...` 는 200 — 대조군을 꼭 넣을 것). 원래 이 자리는 Kerberos SPNEGO 가 막고, 비-Kerberos 에서 남는 스위치는 `ranger.admin.allow.unauthenticated.download.access` 하나다. 이 값을 켜면 **읽기 전용 다운로드 3종**만 열리고(정책 변경·관리 API 는 그대로 인증을 요구한다), ambient 에서는 6080 NetworkPolicy 가 우회되므로(Gotcha 13) 사실상 메시 안 누구나 정책 전문을 읽는다. 설정 파일은 `conf/` 가 아니라 **`conf.dist/`** 를 고칠 것 — `conf/` 는 setup.sh 가 나중에 만든다 — §8-67
37. **플러그인을 넣을 때 감사(audit) 설정 하나가 스토리지 전체를 내린다.** Ranger 2.9 에는 `Log4JAuditDestination` 이 **없다**(감사가 `ranger-audit-dest-hdfs`·`-solr` 로 쪼개지며 빠졌다). 관례대로 `xasecure.audit.destination.log4j=true` 를 켜면 NameNode 가 `ClassNotFoundException` 으로 CrashLoop 하고 HDFS 가 죽으면서 HBase master·REST 까지 함께 무너진다(실측 70분). 그리고 Java 의 `dir/*` 는 **하위 디렉터리를 포함하지 않으므로** `HADOOP_CLASSPATH` 에 `/ranger/*` 만 적으면 구현체 23개가 든 `ranger-hdfs-plugin-impl/` 이 빠져 같은 증상이 난다. 시험 단계에서는 `xasecure.add-hadoop-authorization=true` 로 둘 것 — Ranger 에 정책이 없을 때 HDFS POSIX 로 폴백해서, 정책을 0건 받은 상태가 **전면 거부**가 되지 않는다 — §8-67

38. **Ranger 2.9 의 Hive 플러그인은 Hive 4 에서 동작하지 않는다 — 단 그것은 릴리스 이야기다(§8-70 에서 백포트로 해결).** `java.lang.NoSuchFieldError: PREEXECHOOKS` — Hive 4 가 `HiveConf.ConfVars` 상수를 개명했고 플러그인은 Hive 3 API 로 빌드돼 있다. 설정 오류가 아니라 **바이너리 비호환**이라 고칠 방법이 없다(2.9.0 이 최신 배포판이다). 플러그인은 정책까지 정상적으로 내려받은 뒤 그 다음 단계에서 죽으므로 "잘 되는 줄" 알기 쉽다. ★ **HiveServer2 는 예외를 stdout 에 내지 않는다** — `kubectl logs` 에는 `Hive Session ID = ...` 만 반복되고 파드는 startupProbe 예산을 넘겨 조용히 kill 된다. 진짜 예외는 `/tmp/hive/hive.log` 에 있다. HDFS·HBase 는 같은 절차로 **동작한다** — §8-67
39. **강제하는 플러그인이 없는 Ranger 리포지토리를 남기지 말 것.** Ranger UI 에 서비스가 보이면 "통제되고 있다" 로 읽히지만 정책을 강제하는 것은 Admin 이 아니라 각 서비스의 플러그인이다. Hive 플러그인이 비호환으로 빠졌을 때 `oim-hive` 리포지토리를 함께 지운 이유다. 그리고 **HBase 에는 HDFS 같은 POSIX 폴백이 없다** — `hbase.security.authorization=true` 를 켜는 순간 Ranger 정책이 유일한 판단자가 되므로, 기본 정책이 덮지 않는 사용자로 도는 워크로드는 **그 즉시 끊긴다**(HDFS 는 `xasecure.add-hadoop-authorization=true` 로 폴백이 있다) — §8-67

40. **Hadoop 3.5 는 Jersey 1 을 걷어냈다 — Ranger 2.9 플러그인은 그대로는 못 쓴다.** 3.4.3 은 `jersey-core/-client 1.19.4` 를 lib 에 두었지만 3.5.0 은 `org.glassfish.jersey 2.46` 으로 이관하며 1.x 를 뺐다. `RangerAdminRESTClient` 가 `com.sun.jersey` 를 쓰므로 `NoClassDefFoundError: com/sun/jersey/api/client/ClientHandlerException` 로 NameNode 가 죽는다. ★ **Jersey 1 jar 를 런타임에 보충하는 우회를 쓰지 말 것** — 두 번 다 실패한다: `jsr311-api` 까지 넣으면 `javax.ws.rs` 가 두 벌이 되어 `LinkageError`(클래스로더가 `javax.*` 를 부모에 위임해 격리되지 않는다), 구현만 넣으면 **기동은 하는데** `Client.create()` 의 provider 초기화가 깨져 정책 버전이 `-1` 에 머문다. 후자가 최악이다 — `add-hadoop-authorization` 폴백 때문에 HDFS 는 멀쩡히 돌고 파드는 `1/1 Running` 이라 **인가만 조용히 사라진다.** 되돌릴 때 보충 블록을 함께 걷어내지 않으면 3.4.3 에서도 같은 상태가 된다. **판정은 파드 상태가 아니라 로그의 `Switched policy engine to [N]` 이 Admin 의 `policyVersion` 과 일치하는지로 한다.** 해법은 `docker/ranger-hdfs-plugin` — Ranger 2.9 소스의 REST 클라이언트를 Jersey 2 로 포팅해 빌드한다(upstream 이 master 에서 한 수정의 백포트). Ranger 3.0.0 이 나오면 지울 것 — §8-68

41. **HBase 3 은 Ranger 플러그인을 이식해야만 쓸 수 있다 — 그리고 그것은 백포트가 아니다.** 업스트림 Ranger 2.9 플러그인을 그대로 쓰면 `NoClassDefFoundError: .../AccessControlProtos$AccessControlService$Interface` 로 **마스터가 ABORT** 한다(HBase 는 코프로세서를 못 붙이면 아예 뜨지 않는다). ★ Gotcha 40 의 Jersey 건과 달리 **미출시 master 에도 수정이 없다** — Ranger master 의 pom 이 여전히 `<hbase.version>2.6.0</hbase.version>` 이다. 그래서 `docker/ranger-hbase-plugin` 은 **우리가 만든 이식본이고 대조할 upstream 구현이 없다.** `docker/hbase` 의 `HBASE_VERSION` 을 바꾸면 반드시 그 이미지도 함께 손볼 것 — 짝이 어긋나면 HBase 가 통째로 죽는다. 이식에서 배운 것 셋: ① `ObserverContext` 와일드카드는 **메서드마다 다르다**(RegionObserver 는 `<? extends E>`, MasterObserver 는 대체로 `<E>`) — 일괄 치환하면 오류가 오히려 늘어난다(실측 166건). `javap` 로 실제 시그니처를 읽어 규칙을 생성할 것. ② **HBase 3 은 Java 17 로 컴파일**돼 있고(`class file has wrong version 61.0`) Ranger 2.9 의 `agents-common` 은 Nashorn 때문에 **JDK 15+ 에서 컴파일되지 않는다** — 배타적이므로 2단계 빌드가 필요하다. ③ 같은 `javax/ws/rs` 누락이라도 **처방이 반대다** — Hadoop 3.5 는 평문 `javax.ws.rs` 가 이미 있어 Jersey 1 을 넣으면 중복으로 깨지지만, HBase 3 은 shade 해서 없으므로 **jar 보충으로 충분**하다. ★ 검증은 `scan` 으로 끝내지 말 것 — 인자 목록이 바뀐 8개가 전부 DDL 훅이라 **`create`/`drop` 을 권한 없는 사용자로 시험**해야 한다. 남는 공백은 `preEndpointInvocation` 하나(HBase 3 에 대체 훅 없음) — §8-69

42. **Ranger 플러그인을 새 버전에 맞출 때, "master 파일을 떼어 온다" 와 "2.9.0 을 고친다" 중 어느 쪽이 좁은지는 컴포넌트마다 다르다.** HBase 는 전자가 맞았고(§8-69) **Hive 는 후자가 맞았다**(§8-70) — master 의 `RangerHiveAuthorizer` 는 master 의 `RangerHiveAccessRequest`·`HiveAccessType` 과 함께 진화해서 그 파일만 가져오면 생성자·타입이 89건 어긋난다. 게다가 2.9.0 은 `HiveObjectType`·`HiveAccessType` 을 그 파일 맨 아래 **패키지 전용 top-level enum** 으로 선언해 두어, 갈아끼우면 같은 패키지의 다른 파일이 타입을 잃는다(`package HiveAccessType does not exist`). Hive 는 결국 **두 곳만** 고치면 됐다 — `ConfVars.PREEXECHOOKS` → `HiveConf.getConfVars("hive.exec.pre.hooks")`(upstream 의 수정, 키 이름은 3·4 공통), 그리고 Hive 4 가 없앤 인덱스 연산 case 라벨 제거(그 연산 자체가 없으므로 인가 공백이 아니다. ★ `CREATEINDEX` 는 **두 곳**에 있고 한쪽은 블록째 지워야 한다). ★ **HiveServer2 는 예외를 stdout 에 내지 않는다** — `kubectl logs` 에는 `Hive Session ID = ...` 만 반복되고 파드는 startupProbe 예산을 넘겨 조용히 kill 된다. 진짜 예외는 `/tmp/hive/hive.log` 에 있다 — §8-70

43. **컴포넌트 버전을 올리면 플러그인의 "컴파일 대상"과 "빌드 JDK"가 함께 움직인다 — 그리고 후자는 오류 메시지가 거짓말을 한다.** Hive 4.0.1 -> 4.2.1 에서 `RangerHiveAuthorizer.java:[44,36] error: cannot access FileUtils` 가 났다. "클래스가 없다" 로 읽히지만 실제로는 **읽을 수 없는 클래스 파일 버전**이고, `maven-compiler-plugin 3.3` 이 **사유 줄을 삼켜** 원인이 드러나지 않는다(HBase 3 에서 61 로 겪은 것과 같다, Gotcha 41). **추측하지 말고 바이트코드에 물을 것** — `javap -verbose <class> | grep major` (52=8 · 55=11 · 61=17 · 65=21). Hive 4.0.1 은 52 였고 4.2 는 **65(Java 21)** 다. ★ 그리고 §8-69 에서 세운 "agents-common 은 Nashorn 때문에 JDK 15+ 에서 컴파일되지 않는다" 는 **Hive 경로에서는 성립하지 않았다** — JDK 21 이 `-am` 으로 상위 10개 모듈을 전부 통과시켰다. 같은 모양의 2단계 빌드라도 **같은 이유는 아니다**(HBase 는 필수, Hive 는 캐시 이득뿐). ★ 이미지 태그와 Maven 아티팩트가 어긋날 수 있다 — `apache/hive:4.2.1` 은 있으나 **Central 에 4.2.1 아티팩트가 없어** 4.2.0 으로 컴파일해 4.2.1 위에서 돌린다 — §8-71
44. **Hive 메타스토어 스키마는 세 갈래로 다뤄야 하고, "최신에 도달한 것" 자체가 새 실패 모드다.** ① `schematool -info` 의 실패를 "스키마가 없다" 로 읽지 말 것 — **스키마가 바이너리보다 낡아도 실패한다.** 그대로 `-initSchema` 를 걸면 데이터가 든 메타스토어를 덮는다. 실패 출력에서 버전을 읽어냈는지로 갈라 `-upgradeSchema` 를 태울 것(hive 이미지에는 psql 이 없어 DB 로 가를 수 없다). ② **`apache/hive` 엔트리포인트의 `-initOrUpgradeSchema` 는 스키마가 이미 최신이면 실패한다**(`Unknown version specified for upgrade 4.2.0` -> `Schema initialization failed!`). 4.0.1 처럼 스키마가 낮을 때는 드러나지 않고 **업그레이드를 성공시킨 순간** 메타스토어가 CrashLoop 한다. 스키마 소유자는 부트스트랩 Job 이므로 메타스토어·HiveServer2 에서는 각각 `SKIP_SCHEMA_INIT=true`·`IS_RESUME=true` 로 끌 것. ③ 업그레이드는 **되돌릴 수 없다** — 실행 전에 `pg_dump` 를 뜰 것 — §8-71

45. **버전 태그는 불변이 아니다 — `apache/hive:4.2.1` 이 한 세션 안에서 내용이 바뀌었다.** 번들 Hadoop 이 3.3.6 -> 3.4.1, AWS SDK 가 v1 -> v2 로 갈렸고, 매니페스트의 `HADOOP_CLASSPATH` 가 **jar 파일명을 하드코딩**하고 있어 S3A 가 `ClassNotFoundException: S3AFileSystem` 으로 깨졌다. ★ 증상이 원인과 멀다 — probe 가 TCP 라 파드는 `1/1 Running` 이고 **DDL 을 실행해야 비로소** 드러난다(메타스토어는 같은 결함을 안고도 아무 오류를 내지 않았다). ★★ 처방은 파일명을 새 버전으로 고치는 것이 **아니다** — 그러면 다음에 또 깨진다. **이미지를 다이제스트로 고정해야 비로소 파일명 하드코딩이 안전해진다.** 같은 이유로 `apache/knox:3.0`(RC 추종)·`inquotient/*`(버전 태그 없음)도 다이제스트다. Hive 는 `hive-schematool`·`hive-metastore`·`hive-server` 셋이 **같은 다이제스트**여야 한다 — 갈리면 스키마 검사가 어긋난다 — §8-72
46. **`:latest` 를 "그 시점의 최신 버전" 으로 바꾸는 것은 무해하지 않고, 그 반대도 참이다.** ① Dependency-Track 의 `latest` 는 **4.x** 였다 — 5.1.0 으로 핀하자 `IllegalStateException: Legacy Dependency-Track v4 configuration properties are no longer supported` 로 기동조차 못 했다(v5 는 `alpine.*` -> `dt.*` 이관 + DB 스키마 변경). ② 반대로 **올리면 안 되는 것**이 있다 — `docker/spark-iceberg` 의 `hadoop-aws`·`aws-java-sdk-bundle` 은 베이스 이미지(`apache/spark:3.5.6`)가 번들한 `hadoop-client-api-3.3.4` 가 상한을 정한다. **상한을 정하는 것은 레지스트리가 아니라 베이스 이미지다.** ③ 데이터 보유 워크로드는 **지금 도는 버전**으로 고정할 것 — `percona/percona-server-mongodb:latest` 가 가리키는 것은 8.3 이 아니라 **8.0 LTS** 였고, prod 가 핀한 8.3.8 은 메이저가 다른 값이었다. ④ 불변 필드 드리프트는 apply 를 해봐야 드러난다 — `gitlab`·`jenkins`·`keycloak`·`pyroscope` 는 `volumeClaimTemplates.storageClassName` 이 비어 있어 **어떤 매니페스트 변경도 반영된 적이 없었다**(해소: `kubectl delete sts --cascade=orphan` 후 재적용, 파드·PVC 유지). `kubectl diff -k` 를 정기적으로 돌릴 것 — §8-72

47. **Istio 와 Kubernetes 는 서로 상한·하한을 걸어서, 한쪽을 먼저 끝까지 올릴 수 없다.** 실측 출발점이 Istio 1.24.2 + k8s 1.31.4 였는데 **Istio 1.24 는 k8s ≤1.31, Istio 1.31 은 k8s ≥1.32** 다. k3s 를 먼저 올리면 그 순간 메시가 지원 밖으로 나가고, Istio 를 먼저 올리면 1.30 부터 막힌다. **겹치는 구간을 밟으며 번갈아 올려야 한다** — 실제로 12단계였다(Istio 1.24→1.29, k3s 1.31→1.35, Istio 1.29→1.31, k3s 1.35→1.36). 마이너는 **하나도 건너뛰지 말 것** — 둘 다 한 단계씩만 지원하고, 이 레포는 접미 매칭 AuthorizationPolicy 26곳이 ztunnel 해석에 얹혀 있다(§8-47). ★ 지원 표를 **추측하지 말 것** — 문서 페이지의 표는 shortcode 로 렌더돼 긁어도 값이 없다. 원천은 `istio.io` 의 `data/compatibility/supportStatus.yml` 의 `k8sVersions` 필드다. ★ `istioctl install` 은 **기존과 같은 프로파일·리소스 오버라이드**로 재실행할 것(빠뜨리면 istiod 2Gi·ztunnel 512Mi 기본값이 돌아와 단일 노드에서 스케줄되지 않는다). k3s 는 설치 스크립트를 **같은 서버 인자**로 재실행할 것(빠뜨리면 systemd 유닛이 새로 쓰이며 `--flannel-backend=none` 이 사라져 Cilium 과 충돌한다). ★ 관찰: **k3s 업그레이드는 파드를 재시작시키지 않지만**(API 만 잠깐 내려가 그 사이 CronJob 이 실패한다), **Istio 업그레이드는 ztunnel 재시작으로 장기 TCP 연결을 끊어** 재연결하지 않는 앱이 CrashLoop 에 들어간다(`pgConn.Ping() error: unexpected EOF`, 90초 내 자가 복구). 판정은 파드 상태가 아니라 **`istioctl ztunnel-config policy` 의 건수가 유지되는지**로 한다 — §8-73

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
