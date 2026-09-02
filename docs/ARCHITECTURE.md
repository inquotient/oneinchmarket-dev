# ARCHITECTURE — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> **표기 규칙**
> - `[구현됨]` — 레포지토리 파일로 확인된 사실. 파일 경로를 근거로 첨부한다.
> - `[목표]` — 설계로 확정했으나 아직 레포지토리에 없는 것.
> - `[UNVERIFIED]` — 이 환경에서 검증할 수 없었던 것. 임의로 결정하지 않는다.
> - `[TODO-nn]` — 사람의 아키텍처 결정이 필요한 지점.
>
> 검증 수단: `kubectl kustomize`(내장 kustomize v5.8.1)로 dev/prod 오버레이 빌드 성공을 확인했다.
> `kustomize` · `kubeconform` · `tofu` · `sops` 바이너리는 이 환경에 없어 스키마 검증과 `tofu plan`은 **미검증**이다.

---

## 목차

1. [배포 타깃](#1-배포-타깃)
2. [계층 아키텍처](#2-계층-아키텍처)
3. [텔레메트리 파이프라인](#3-텔레메트리-파이프라인)
4. [관측·분석 도메인](#4-관측분석-도메인)
5. [데이터 흐름](#5-데이터-흐름)
6. [네트워크 아키텍처](#6-네트워크-아키텍처)
7. [배포 구성 — 컴포넌트 × 오버레이](#7-배포-구성--컴포넌트--오버레이)
8. [ArgoCD Sync Wave](#8-argocd-sync-wave)
9. [구현 현황 vs 설계 목표](#9-구현-현황-vs-설계-목표)
10. [아키텍처 결정 필요 항목 (TODO)](#10-아키텍처-결정-필요-항목-todo)
11. [ADR 색인](#11-adr-색인)

---

## 1. 배포 타깃

| 타깃 | 기반 | IaC | 용도 | 상태 |
|---|---|---|---|---|
| **local** | Hyper-V (Windows 11 Pro) | `infra/environments/local` + `infra/modules-local/` | 개발·기능 검증 | `[목표]` |
| **dev** | Vultr `icn`(서울) | `infra/environments/dev` + `infra/modules/` | 통합 검증 | `[구현됨]` — `infra/environments/dev/terraform.tfvars:6-7` |
| **prod** | Vultr | `infra/environments/prod` + `infra/modules/` | 운영 | `[목표]` — provider 블록 부재로 현재 배포 불가 (G5) |

### 1-1. 프로바이더 정책

**Vultr 단독**이다. Hetzner는 제거한다 (ADR-019).

현재 레포에는 Hetzner/Vultr 이중 구현이 있으나 **Hetzner 경로가 미완성**이다 — bastion·master 없음, VPC 미연결, 방화벽 미부착, `bastion_ip` 출력이 worker[0] 공인 IP를 반환(`infra/modules/compute/hetzner/outputs.tf:5-11`). 이 불일치는 count 기반 멀티 프로바이더 추상화가 **두 구현의 어긋남을 가려준 결과**다. 추상화를 폐기하고 모듈을 평탄화한다 (ADR-011 Superseded → ADR-019).

**Hyper-V는 통합하지 않는다.** VPC·방화벽 그룹·DNS 존·블록스토리지 API가 없는 근본적으로 다른 기반이므로 별도 루트 모듈로 분리한다 (ADR-052).

> **이식성의 실제 경계는 IaC가 아니라 Kubernetes 계층이다.** Kustomize + ArgoCD는 이미 완전히 기반 무관하며, 그것이 실제로 작동하는 부분이다.

### 1-2. 목표 디렉터리 구조 `[목표]`

```
infra/
├── environments/
│   ├── local/          # Hyper-V
│   ├── dev/            # Vultr (icn)
│   └── prod/           # Vultr
├── modules/            # Vultr 전용 (평탄화 — 하위 vultr/ 없음)
│   └── compute · network · dns · storage
├── modules-local/      # Hyper-V 전용
│   └── vm · network
└── scripts/
    ├── bootstrap-k3s.sh        # --mode=cloud|local
    ├── install-operators.sh    # [목표] ECK·Kyverno·Gateway API·Argo Events·cert-manager·OTel·Trivy
    ├── install-cilium.sh       # [목표]
    ├── install-istio.sh
    ├── install-argocd.sh
    └── install-reloader.sh
```

**tf 파일 42개 → 19개.** `infra/modules/bastion/`는 삭제한다 — 어느 환경에서도 호출되지 않는 죽은 코드이며, `bootstrap-k3s.sh` 1/7 단계가 같은 일을 더 완전하게 수행한다.

---

## 2. 계층 아키텍처

```
                            [ 인터넷 ]
                                 │
┌────────────────────────────────▼────────────────────────────────┐
│ L0  네트워크 경계 — 클러스터 외부 VM                     [목표]  │
│     OPNsense (방화벽 · 라우팅 · NAT · VPN 종단)                  │
│       ├─ Suricata  인라인 IPS   (남-북 트래픽)                   │
│       └─ Zeek      패시브 프로토콜 분석 · 메타데이터              │
│     ※ Vultr 배치 실현성 [UNVERIFIED] → TODO-28                   │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L1  애플리케이션 진입점                                  [목표]  │
│     SafeLine WAF → ingress-nginx (TLS 종단, cert-manager)        │
│       → oauth2-proxy (Keycloak OIDC 검증)                        │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L2  클러스터 데이터플레인                                        │
│     Cilium (CNI · eBPF · kube-proxy 대체 · WireGuard)    [목표]  │
│       └─ Hubble (플로우 관측 · 서비스 맵 · 드롭 원인)            │
│     CiliumNetworkPolicy — L3/L4/L7 · FQDN egress                 │
│     ──────────────────────────────────────────────────────────   │
│     Istio Ambient (ztunnel + waypoint)          [구현됨/부분]    │
│     PeerAuthentication(mTLS) · AuthorizationPolicy(L7 ID 인가)   │
│     ※ 범위 상이: Cilium=클러스터 전체, Istio=메시 가입 NS        │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L3  어드미션 · 포스처                                            │
│     Kyverno 6정책                                       [구현됨] │
│     Kubescape (CIS · NSA-CISA · MITRE ATT&CK)            [목표]  │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L4  런타임 보안                                                  │
│     Tetragon (탐지 + 차단)                               [목표]  │
│     ※ 현재는 Falco + Falcosidekick             [구현됨] → ADR-025│
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L5  시크릿                                                       │
│     HashiCorp Vault (동적 자격증명 · Transit · PKI)      [목표]  │
│     ※ SOPS+age는 설계만 존재, 실제 미작동      [미구현] → ADR-024│
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L6  공급망                                                       │
│     Trivy (CI 3잡)                                      [구현됨] │
│     Trivy Operator · Cosign verifyImages · Syft ·        [목표]  │
│     Dependency-Track · DefectDojo · Gitleaks · Checkov           │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L7  관측성                                                       │
│     OpenTelemetry Collector (Agent DS + Gateway ×3)      [목표]  │
│     Prometheus · Grafana · Loki · Tempo · Jaeger         [목표]  │
│     Elasticsearch(ECK) · Kibana · Logstash · Filebeat   [구현됨] │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L8  SIEM · 상관분석                                              │
│     Wazuh (Manager · Indexer · Dashboard)                [목표]  │
└────────────────────────────────┬────────────────────────────────┘
┌────────────────────────────────▼────────────────────────────────┐
│ L9  검증 (dev/local 전용)                                        │
│     MITRE Caldera + security-verification 스위트         [목표]  │
│     ※ prod 배포 금지 — ADR-030                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 텔레메트리 파이프라인

**OpenTelemetry를 계측 표준으로 채택한다** (ADR-039). 애플리케이션은 OTLP로만 계측하고 백엔드 라우팅은 Collector 설정으로 관리한다. 백엔드 교체가 운영 결정 사항이 되고 앱 코드는 불변이다.

```
┌─ 애플리케이션 ──────────────────────────────────────────┐
│  admin (Node) / cmmn-api (Java)                         │
│   └─ OTel Operator 자동 계측 (코드 변경 없음)             │
│      instrumentation.opentelemetry.io/inject-{java,nodejs}│
│      로그에 trace_id · span_id 주입                       │
└──────────────────┬──────────────────────────────────────┘
                   │ OTLP (gRPC 4317 / HTTP 4318)
                   ▼
┌─ Collector Agent (DaemonSet) ───────────────────────────┐
│  receivers   otlp · filelog · hostmetrics · kubeletstats │
│  processors  k8sattributes · resourcedetection · batch   │
│  exporters   loadbalancing (trace_id 기준 → Gateway)     │
└──────────────────┬──────────────────────────────────────┘
                   ▼
┌─ Collector Gateway (Deployment ×3) ─────────────────────┐
│  processors  tail_sampling · filter · transform          │
│              · redaction (PII·자격증명 스크러빙)          │
│  exporters   otlp/tempo · otlp/jaeger                    │
│              · prometheusremotewrite · loki · sentry     │
└───┬──────┬──────┬──────┬──────┬─────────────────────────┘
    ▼      ▼      ▼      ▼      ▼
  Tempo  Jaeger  Prom   Loki  Sentry/GlitchTip
```

**테일 샘플링은 반드시 Gateway 계층에 둔다.** 한 트레이스의 모든 스팬이 같은 인스턴스에 모여야 하므로 Agent는 `loadbalancing` exporter로 trace_id 기준 라우팅을 해야 한다 (ADR-040).

**OTel Operator 자동 계측의 부수 효과**: 코드 변경 없이 계측이 가능하므로, `.gitlab-ci.yml`이 참조하는 Dockerfile이 존재하지 않는 문제(G9)가 해소되기 전에도 트레이스 수집을 시작할 수 있다 (ADR-042).

---

## 4. 관측·분석 도메인

**6개 도메인을 의도적으로 분리한다.** 중복이 아니라 데이터 수명주기·조회 주체·규제 요건이 다르기 때문이다 (ADR-026).

| 도메인 | 저장소 | 담당 데이터 | 조회 주체 |
|---|---|---|---|
| **운영 관측성** | Elasticsearch(ECK) ×3 + Kibana | 애플리케이션·인프라 로그(장기 보존·전문 검색), Trivy 리포트 | 운영 |
| **보안 관제** | Wazuh Indexer ×3 + Dashboard | 런타임 위협, 네트워크 IDS, HIDS, 컴플라이언스, 포스처 | 보안 |
| **메트릭·플로우** | Prometheus + Loki + Grafana | 시계열, 네트워크 플로우(Hubble), 단기 로그(7~14d) | 운영/SRE |
| **분산 추적** | Tempo(MinIO, 장기) + Jaeger(ES, 단기) | 요청 스팬, 서비스 의존성 | 개발/SRE |
| **애플리케이션 오류** | Sentry 또는 GlitchTip | 예외·스택트레이스·릴리스 회귀 | 개발 |
| **취약점 관리** | DefectDojo · Policy Reporter · Dependency-Track | CVE·SBOM·정책 위반 트리아지 | 보안 엔지니어링 |

### 4-1. Loki ↔ Elasticsearch 경계 (ADR-027)

**보존기간 기반 분리.** Loki는 컨테이너 stdout 7~14일(Grafana 메트릭↔로그 상관), ES는 애플리케이션·인프라 로그 장기 보존(ILM 10GB/7d rollover 기존 설정 유지).

### 4-2. Jaeger ↔ Tempo 경계 (ADR-041)

| | Jaeger + Elasticsearch | Tempo + MinIO |
|---|---|---|
| 보존 | 단기 3~7일 | 장기 30일+ |
| 용도 | 개발자 디버깅, 서비스 의존성 그래프 | Grafana 상관분석, TraceQL |
| 비용 | ES 인덱싱 | **인덱스 없음 — 최저.** MinIO 재사용 |

Collector가 동일 트레이스를 양쪽으로 fan-out 한다.

### 4-3. Logstash 역할 재정의 (ADR-031)

현재 Logstash는 `beats:5044` 입력만 열어두고 Filebeat가 ES로 직결하는 바람에 **아무것도 처리하지 않는 고아 상태**다(`filebeat-configmap.yaml:21-25` vs `logstash-configmap.yaml:19-21`, 문제 G11).

**보안 이벤트 정규화·라우팅 계층으로 재배치한다.**

```
Tetragon ─→ Falcosidekick ─→ Kafka(falco-alerts) ─┐
Suricata (EVE JSON) ──────────────────────────────┤
Zeek (conn/dns/http/ssl) ─────────────────────────┼→ Logstash ─→ Wazuh Indexer
Wazuh Agent ─→ Wazuh Manager ─────────────────────┤
Kubernetes Audit Log ─────────────────────────────┤
Kubescape 포스처 결과 ────────────────────────────┘
```

Falcosidekick이 이미 Kafka `falco-alerts` 토픽으로 전송하도록 설정되어 있어(`falcosidekick-configmap.yaml:42`) 기존 설정을 그대로 활용한다.

> Wazuh Indexer는 OpenSearch 계열이므로 Logstash `opensearch` output 플러그인 사용이 일반적이다. **플러그인·버전 호환은 [UNVERIFIED]** — 대안으로 Wazuh Manager syslog 수집기 경유 경로가 있다.

**보안 관제 경로는 OTel을 경유하지 않는다.** 보안 이벤트는 유실·지연이 허용되지 않고 샘플링 대상도 아니다.

---

## 5. 데이터 흐름

### 5-1. 메시징 · 이벤트

```
cmmn-api ──(SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka-headless:9092)──→ Kafka KRaft
Kafka(0..2) ←──9093 controller quorum──→ Kafka(0..2)
AKHQ ──9092──→ Kafka ; AKHQ ──8080/apis/ccompat/v7──→ Apicurio ──5432──→ PostgreSQL
외부 HTTP 클라이언트 ──→ Kafka Bridge :8080 ──9092──→ Kafka        [목표]
Argo Events EventSource ──9092 keycloak-events──→ Sensor ──→ Job
Falcosidekick ──9092 falco-alerts──→ Kafka ──→ Logstash
```

**검증됨** — `cmmn-api-statefulset.yaml:60-61`, `akhq-configmap.yaml:15-17`, `apicurio-statefulset.yaml:42`, `falcosidekick-configmap.yaml:42`.

**문제**
- `[UNVERIFIED]` `keycloak-events` 토픽에 **프로듀서가 없다.** Keycloak에 event-listener SPI 설정(`KC_SPI_EVENTS_LISTENER_*`)이 없다. Argo Events EventSource와 Logstash Kafka 입력이 모두 이 토픽에 의존한다. **v1에는 토픽 생성 Job이 있었다**(`v1/kafka/kafka-job.yaml`).
- `messaging-netpol.yaml:17-32`가 Kafka:9092 접근을 `component: application`·`akhq`·`kafka-rest`·`schema-reg`에만 허용한다. **9093 규칙이 없어 prod 3브로커 KRaft quorum이 default-deny에 막힌다**(G23). `schema-reg`는 죽은 규칙이다.
- `KAFKA_LOG_DIRS` 미설정 → **PVC를 마운트해놓고 브로커는 기본 경로에 쓴다.** 재시작 시 데이터 유실. `CLUSTER_ID`도 없다.

**Kafka Bridge** `[목표]` — Confluent REST Proxy를 대체한다 (ADR-032). Apache 2.0 라이선스(Apicurio와 일관), **브로커를 직접 노출하지 않고 HTTP 단일 지점으로 외부 접근 수용**(ADR-035), Prometheus 메트릭 내장. v1/v2 전체에서 8082 API를 호출하는 내부 소비자가 없어 **교체 비용이 0**이다.

### 5-2. 레이크하우스 질의

```
client ──8080──→ Trino (coordinator, 단일 노드)
   ├── catalog iceberg  (iceberg.catalog.type=hive_metastore)
   ├── catalog hive
   ├──9083 thrift──→ Hive Metastore ──5432──→ PostgreSQL/hive_metastore
   └──9000 s3──────→ MinIO (path-style, region us-east-1)
Hive Metastore ──s3a://warehouse/tables──→ MinIO
```

**검증됨** — `trino-configmap.yaml:31-50`, `hive-metastore-configmap.yaml:16-32`, `hive-metastore-statefulset.yaml:76-81`.

**문제**
- `default-deny-ingress`가 전 파드에 적용되는데 **MinIO:9000·Hive:9083·Trino:8080 allow 정책이 없다.** 렌더링 상태 그대로면 Trino→Hive, Trino→MinIO, Hive→MinIO가 전부 차단된다(G13). Istio AuthorizationPolicy만 MinIO를 커버하는데 ambient가 dev에서 비활성이다.
- **선행 조건 부재** — MinIO `warehouse` 버킷, PostgreSQL `hive_metastore` DB·롤, Hive `schematool` 초기화가 없다. PostgreSQL은 `oneinchmarket` DB만 생성한다(`postgresql-configmap.yaml:10-11`). `keycloak`·`gitlab`·`apicurio` DB와 MariaDB `cmmn` DB도 동일(G22).
- Trino가 `node.data-dir=/data/trino`를 설정하지만 해당 경로에 볼륨이 없다(`trino-statefulset.yaml:81-83`).
- Hive Metastore가 **기동 시 인터넷에서 JDBC 드라이버를 다운로드**한다(`hive-metastore-statefulset.yaml:33-48`). 체크섬 고정 없음, 런타임 외부 egress 의존.

### 5-3. 관측성

```
Filebeat DS (hostPath /var/log, /var/lib/docker/containers)
    └──→ Elasticsearch https://elasticsearch-es-http:9200      [직결 — Logstash 우회]
Tetragon/Falco ──→ Falcosidekick ──→ ES(falco-alerts) + Kafka(falco-alerts)
Trivy CronJob ──→ ES(trivy-reports)
ES ILM PostSync Job ──→ logstash|falco-alerts|keycloak-events|trivy-reports 별칭·정책
```

**문제**
- **자격증명 분열** — Filebeat·Logstash·ILM Job은 ECK 생성 `elasticsearch-es-elastic-user`를, Falcosidekick(`falcosidekick-deployment.yaml:41-43`)과 Trivy(`trivy-cronjob.yaml:79-81`)는 `elasticsearch-secret`을 쓰는데 **후자는 배포되지 않는다**.
- `trivy-cronjob.yaml:51`이 `aquasec/trivy` 안에서 `kubectl`을 실행하는데 **이미지에 kubectl이 없다.** `--cacert`를 쓰면서 인증서 볼륨도 마운트하지 않는다 → **Trivy Operator로 대체**(ADR-047).

### 5-4. 시크릿 로테이션

```
CronJob (wave 8, "0 3 1,15 * *")
   → 서비스에 새 자격증명 적용 (ALTER USER / API)
   → kubectl patch secret
   → Stakater Reloader가 소비자 파드 rolling restart
"30 3 1,15 * *" rotation-git-sync
   → kubectl get secret | sops --encrypt → git push origin v2
   → ArgoCD 재동기화 (Secret /data는 ignoreDifferences)
```

**제어 흐름 설계는 일관되나 배선이 되어 있지 않다.**

| 문제 | 근거 |
|---|---|
| Secret이 하나도 배포되지 않음 | 12개 `*.enc.yaml` 전부 주석 처리 |
| 키 이름 불일치 7개 중 4개 | PostgreSQL `postgresql-password` vs `postgres-password`(`rotate-postgresql.yaml:58,66`), MariaDB·MongoDB `root-password` vs `*-root-password`, MinIO `root-user/root-password` vs `minio-access-key/minio-secret-key` |
| 잘못된 시크릿 대상 | `rotate-elasticsearch.yaml:56` — 소비자는 ECK `elasticsearch-es-elastic-user` |
| git-sync 출력 경로 부재 | `base/rotation/secrets/`(`rotation-git-sync.yaml:65`) |
| 이미지에 도구 없음 | `curlimages/curl`에서 `kubectl`, git-sync는 런타임 `apk add` |
| RBAC 범위 불일치 | Role은 네임스페이스 한정인데 `rotate-admin.yaml:100`은 argocd NS 시크릿 패치 |

→ **Vault 채택 시 이 체계 전체가 대체된다**(ADR-024). CronJob 8종·git-sync·`.enc.yaml` 12개가 제거되고 위 문제가 전부 소멸한다.

### 5-5. 외부 HTTP 수집 `[목표]`

```
외부 클라이언트
   │ HTTPS
   ▼ OPNsense        L3/L4 방화벽 + Suricata 인라인 IPS
   ▼ SafeLine WAF    L7 검사 · 레이트리밋 · 페이로드 상한
   ▼ ingress-nginx   TLS 종단(cert-manager) · 스티키 세션
   ▼ oauth2-proxy    Keycloak OIDC 검증        ← 인증이 여기서 강제됨
   ▼ Kafka Bridge :8080   (ClusterIP, 외부 직접 도달 불가)
   ▼ Kafka :9092
```

**Kafka Bridge의 HTTP API에는 자체 인증·인가가 없다고 보고 설계한다.** 도달 가능한 누구나 produce/consume 할 수 있으므로 인증은 반드시 앞단이 담당한다.

Bridge는 **토픽 단위 클라이언트 인가를 하지 못한다.** 대응: ⓐ 게이트웨이 경로 인가(`/topics/<name>` ↔ OIDC 클레임 매핑, Cilium L7 정책 병행) + ⓒ Bridge 자격증명 최소권한(Kafka ACL을 외부 공개 토픽으로 한정). ⓒ에는 Kafka SASL·ACL이 필요한데 현재 없다 → ADR-034의 근거.

**운영 제약** — 컨슈머 인스턴스가 특정 Bridge 파드 메모리에 존재하므로 `replicas > 1`이면 Service `sessionAffinity: ClientIP` **및** Ingress `affinity: cookie`가 함께 필요하다.

---

## 6. 네트워크 아키텍처

### 6-1. Cilium ∥ Istio 역할 분담 (ADR-023 / ADR-009)

| 계층 | 담당 | 범위 |
|---|---|---|
| **Cilium** | 파드 네트워킹, kube-proxy 대체, L3/L4 정책, FQDN egress, 노드 간 전송 암호화 | **클러스터 전체** — 메시 미가입 워크로드 포함 |
| **Hubble** | 플로우 관측, 서비스 맵, 드롭 원인 | 클러스터 전체 |
| **Istio Ambient** | 워크로드 ID 기반 mTLS, L7 인가(SA principal, HTTP 메서드/경로) | 메시 가입 네임스페이스만 |

Falco/Tetragon·Filebeat·Cilium agent 같은 DaemonSet과 오퍼레이터는 ambient에 넣지 않으므로 **이들에 대한 통제는 Cilium만 가능하다.** 이것이 병행의 실질적 근거다.

### 6-2. 공존 필수 설정 (ADR-043)

| # | 설정 | 이유 |
|---|---|---|
| **M1** | `socketLB.hostNamespaceOnly=true` | Cilium 소켓 레벨 LB가 ztunnel 리다이렉션보다 먼저 목적지를 확정해 **메시를 우회**시킨다 |
| **M2** | `cni.exclusive=false` | Cilium 배타 CNI 설정을 꺼야 `istio-cni`가 체이닝된다 |
| **M3** | `istio-cni` DaemonSet 배포 | ambient에서 파드 netns에 리다이렉션 규칙을 설치하는 주체. 현재 레포에 없다 |

**M1의 실패 모드가 특히 위험하다** — 설정이 틀려도 에러 없이 통신은 정상 동작하고, 다만 **mTLS와 AuthorizationPolicy가 적용되지 않은 채 흐른다.** 보안 통제가 꺼진 상태를 인지할 수 없다.

→ `scripts/security-verification/`에 **ambient 우회 탐지** 항목을 신설한다. ztunnel 메트릭에서 워크로드별 HBONE 연결 수를 확인한다.

### 6-3. 암호화 계층 (ADR-044)

**역할 분리** — Cilium WireGuard는 메시 미가입 트래픽(kube-system, DaemonSet, 오퍼레이터, 컨트롤플레인), Istio mTLS는 메시 내부 워크로드 ID. 메시 트래픽 일부에 이중 암호화가 남지만 Cilium WireGuard는 커널 레벨이라 오버헤드가 낮다. 실측 후 조정한다.

**`PeerAuthentication`을 `PERMISSIVE` → `STRICT`로 전환한다.** PERMISSIVE는 평문을 허용해 M1 설정 오류를 덮어버린다.

### 6-4. 정책 작성 규약 (ADR-045)

| 정책 종류 | 작성 계층 |
|---|---|
| 기본 격리 (네임스페이스·파드 L3/L4) | CiliumNetworkPolicy |
| **Egress FQDN 제어** | CiliumNetworkPolicy |
| 메시 미가입 워크로드 통제 | CiliumNetworkPolicy |
| **워크로드 ID 기반 인가** | Istio AuthorizationPolicy |
| L7 HTTP 메서드·경로 인가 | Istio AuthorizationPolicy (waypoint) |
| 기존 K8s NetworkPolicy 14개 | 유지 — Cilium이 해석. 점진적 CNP 이관 |

**드롭 원인 추적 절차**: ① `hubble observe --verdict DROPPED` → ② 드롭 없으면 ztunnel/waypoint 로그 → ③ `istioctl analyze`.

### 6-5. 선결 과제

**15개 워크로드가 `serviceAccountName`을 지정하는데 ServiceAccount는 3개만 존재한다**(G18). Istio SPIFFE principal은 ServiceAccount에서 파생되므로 **현재 4개 AuthorizationPolicy의 `principals` 규칙이 아무것도 매칭하지 못한다.**

### 6-6. Cilium 전환의 전제 — 클러스터 재구축

`bootstrap-k3s.sh:126-132`가 `--flannel-backend wireguard-native`로 설치한다. Cilium에는 `--flannel-backend=none --disable-network-policy`가 필요한데 **둘 다 k3s 설치 시점에만 지정 가능한 플래그**다. 실행 중인 클러스터에 얹을 수 없고 **노드를 재설치해야 한다.**

### 6-7. ambient 재활성화 절차

dev에서 ambient는 꺼져 있다(`overlays/dev/namespace.yaml:10`, 커밋 `33e1c94`). **원인은 규명되지 않았고**, 현재 CNI가 flannel이므로 M1이 원인일 수는 없다. Cilium 전환이 재부트스트랩을 동반하므로 이를 재검증 기회로 삼는다.

```
1. Cilium 전제로 k3s 재설치 (M1·M2 포함)
2. Cilium 단독 상태에서 네트워킹·정책 검증 (Hubble)
3. istio-cni + ztunnel 배포 (M3)
4. dev 네임스페이스 ambient 레이블 재활성화
5. ambient 우회 탐지 검증 통과 확인          ← 배포 게이트
6. PeerAuthentication PERMISSIVE → STRICT
7. prod 적용
```

**5번을 통과하지 못하면 6번으로 넘어가지 않는다.**

---

## 7. 배포 구성 — 컴포넌트 × 오버레이

현재 `base/kustomization.yaml`이 10개 카테고리를 무조건 포함해 **부분 배포가 구조적으로 불가능하다.** Kustomize `Component`로 조립 단위를 분리한다 (ADR-054).

### 7-1. 컴포넌트

| 컴포넌트 | 구성 | 하드 의존 | 로컬 소요 |
|---|---|---|--:|
| **core** | 정책·메시·NetPol, DB 4종, 부트스트랩 Job, Kafka·Apicurio·AKHQ·Bridge, MinIO·Trino·Hive MS, Keycloak, 애플리케이션 3종 | — | 19.9 GB |
| **observability** | Prometheus, Grafana, ES+Kibana, Logstash, Loki, Tempo, Jaeger, OTel | core | 15.2 GB |
| **security-min** | Wazuh(Manager+Indexer), Trivy Operator, Policy Reporter, Vault | core + observability | 5.5 GB |
| **security-full** | + SafeLine, Kubescape, Dependency-Track, DefectDojo, Caldera, Wazuh Dashboard | security-min | +13.7 GB |
| **lakehouse-v1** | ZooKeeper, Hadoop(NN·DN·JN·RBF), HBase(HM·RS), Hive Server | core | 9.2 GB |
| **governance** | DS389, Kerberos, LAM, Solr, Ranger(admin·usersync), Knox | core | 5.9 GB |
| **devops** | GitLab EE, Jenkins | core | 5.2 GB |
| **apm** | Sentry 또는 GlitchTip | core + observability | 22 / 2.0 GB |

### 7-2. 오버레이

| 오버레이 | 컴포넌트 | 소요 | 64 GB 호스트 |
|---|---|--:|:---:|
| `local-core` | core + observability(최소) | 32.1 GB | ✅ |
| `local-lakehouse` | core + lakehouse-v1 | 29.1 GB | ✅ |
| `local-governance` | core + governance + devops | 31.8 GB | ✅ |
| `local-apm` | core + observability(최소) + apm(GlitchTip) | 35.6 GB | ✅ |
| `local-security-min` | core + observability(최소) + security-min | 37.1 GB | ✅ |
| `dev` / `prod` | 전체 | — | — |

**`security-full`은 64 GB 로컬에서 검증 불가**하다. 128 GB 이상이 필요하다.

### 7-3. 선행 작업

| # | 작업 | 이유 |
|---|---|---|
| 1 | 서비스 디렉터리마다 `kustomization.yaml` 추가 (약 40개) | 현재 카테고리 레벨에만 있어 개별 서비스 참조 불가 |
| 2 | sync-wave를 카테고리 → 서비스 레벨로 이동 (ADR-062) | 컴포넌트 경계가 카테고리와 다르다. 오히려 정밀해진다 |
| 3 | `commonLabels` → `labels:` 전환 (ADR-063) | kustomize v5.8 deprecated 경고 8건 발생 중 |

### 7-4. 부수 효과

컴포넌트 경계를 그으려면 **"무엇이 무엇에 의존하는가"를 확정해야 한다.** 미해결 문제들이 여기서 강제로 드러난다 — G22(부트스트랩 부재)는 `core`에 `base/bootstrap`을 넣어야 나머지가 동작하므로 해소가 강제되고, G18(SA 누락)은 서비스별 kustomization 작성 시 함께 정의되며, G13(NetPol 공백)은 컴포넌트별 정책을 넣어야 부분 배포가 동작한다.

---

## 8. ArgoCD Sync Wave

### 8-1. 현재 `[구현됨]`

| Wave | 카테고리 | 근거 |
|---:|---|---|
| 0 | network-policies · service-mesh · kyverno | 각 `kustomization.yaml` `commonAnnotations` |
| 1 | database | `base/database/kustomization.yaml:28` |
| 2 | messaging | `base/messaging/kustomization.yaml:19` |
| 3 | data-lakehouse | `base/data-lakehouse/kustomization.yaml:23` |
| **4** | **security/keycloak** | `base/security/keycloak/kustomization.yaml:11` |
| 5 | devops | `base/devops/kustomization.yaml:11` |
| 6 | application | `base/application/kustomization.yaml:16` |
| 7 | observability | `base/observability/kustomization.yaml:36` |
| 8 | rotation | `base/rotation/kustomization.yaml:21` |

> `base/security/namespaces/`(wave 0)는 **어느 kustomization에도 포함되지 않는다** — 고아 디렉터리다. 네임스페이스는 오버레이가 각자 정의하며 두 정의가 서로 다르다 (G15).

### 8-2. 목표 `[목표]`

| Wave | 대상 |
|---:|---|
| **−1** | 오퍼레이터 — Cilium · ECK · Kyverno · Gateway API CRD · cert-manager · Argo Events · OTel Operator · Trivy Operator (부트스트랩 스크립트, ArgoCD 밖) |
| 0 | 네임스페이스 · NetworkPolicy/CNP · 서비스메시 · Kyverno 정책 |
| 1 | database · Vault |
| **1.5** | **DB/롤/버킷 부트스트랩 Job** |
| 2 | ZooKeeper · Kafka · Apicurio · AKHQ · Kafka Bridge |
| **2.5** | **Kafka 토픽 생성 Job** |
| 3 | 인증 — DS389 → Kerberos → LAM |
| 4 | Hadoop (JN → NN → DN → RBF) |
| 5 | MinIO · Hive Metastore · Trino · HBase · Hive Server · Solr |
| 6 | Keycloak · Ranger(admin → usersync) |
| 7 | Knox |
| 8 | GitLab · Jenkins |
| 9 | 애플리케이션 · ingress-nginx · SafeLine |
| 10 | 관측성 — Prometheus · ES · Loki · Tempo · Jaeger · OTel Collector |
| 11 | SIEM — Wazuh |
| 12 | 취약점 관리 — Dependency-Track · DefectDojo · Policy Reporter · Kubescape |
| 13 | rotation (Vault 미채택 시) |

---

## 9. 구현 현황 vs 설계 목표

### 9-1. 렌더링 검증 결과 `[구현됨]`

`kubectl kustomize` 빌드 성공 (dev 5,427줄 / prod 5,569줄).

| Kind | dev | prod |
|---|--:|--:|
| StatefulSet | 15 | 15 |
| Service | 17 | 17 |
| ConfigMap | 14 | 14 |
| NetworkPolicy | 14 | 14 |
| CronJob | 9 | 9 |
| ClusterPolicy | 6 | 6 |
| AuthorizationPolicy | 4 | 4 |
| DaemonSet / Deployment | 2 / 2 | 2 / 2 |
| Elasticsearch / Kibana (ECK CRD) | 1 / 1 | 1 / 1 |
| PodDisruptionBudget | 0 | 8 |
| **Secret** | **0** | **0** |

### 9-2. 주장 vs 실제 (갭 목록)

| # | 주장 | 실제 | 근거 |
|---|---|---|---|
| **G1** | SOPS+age 암호화 | **암호화 안 됨.** `.sops.yaml:3` age 키가 `age1xxxxx…` 플레이스홀더, `*.enc.yaml` 12개는 평문 `PLACEHOLDER_ENCRYPT_WITH_SOPS`, keycloak만 가짜 메타데이터(`age: []`) | `.sops.yaml`, `minio-secret.enc.yaml:13-14` |
| **G2** | Secret 배포됨 | **12개 전부 주석 처리** → Secret 0개. 8개 이상 워크로드가 `secretKeyRef` 참조 → **현 상태로 기동 불가** | 전 카테고리 `kustomization.yaml`, 커밋 `43c95b2` |
| **G3** | ArgoCD `kustomize-sops` CMP | 설치 스크립트는 **`ksops`** 로 등록. repo-server 사이드카 패치도 없음 | `install-argocd.sh:30` vs `oneinchmarket-dev.yaml:24` |
| **G4** | Hetzner 기반 | dev tfvars는 **`vultr` / `kor`** | `dev/terraform.tfvars:6-7` |
| **G5** | 멀티 프로바이더 이식성 | **Hetzner에 bastion/master/VPC/방화벽 없음.** prod/main.tf엔 provider 블록도 없고 storage `worker_ids = []` | `compute/hetzner/*`, `prod/main.tf:36` |
| **G6** | mTLS STRICT | **PERMISSIVE**, dev는 ambient 레이블 주석 처리 | `peer-authentication.yaml:13`, `overlays/dev/namespace.yaml:10` |
| **G7** | PSS restricted | dev는 **`enforce: privileged`** | `overlays/dev/namespace.yaml:11` |
| **G8** | Kyverno가 root 차단 | GitLab EE `runAsUser: 0` + `allowPrivilegeEscalation: true` + capability 8종 → **prod Enforce 시 모순** | `gitlab-statefulset.yaml:29-32,75-85` |
| **G9** | CI가 앱 이미지 빌드 | **`v1/admin/Dockerfile`·`v1/cmmn-api/Dockerfile` 부재** → build 실패 | `.gitlab-ci.yml:56,65` |
| **G10** | Cosign 서명 검증 | 서명만, **`verifyImages` 정책 없음.** 레지스트리 제한도 없음 | `base/security/kyverno/` |
| **G11** | ELK 파이프라인 | **Filebeat가 ES 직결**, Logstash 고아 | `filebeat-configmap.yaml:21-25` |
| **G12** | Redis Cluster | **standalone 6 레플리카**, 클러스터 초기화 없음 | `redis-statefulset.yaml:14,35`, 커밋 `7f21607` |
| **G13** | 필요한 통신만 허용 | MinIO·Trino·Hive MS·Keycloak·Apicurio·GitLab에 **ingress allow 없음** | `network-policies/kustomization.yaml` |
| **G14** | dev `secrets/` 비어 있음 | **디렉터리 자체가 없음** | — |
| **G15** | 네임스페이스 wave 0 | `base/security/kustomization.yaml`이 `namespaces/` 미포함 → 고아 | — |
| **G16** | — | prod storage 패치가 GitLab VCT를 `data`로 지정, base는 `gitlab-data` → PVC 추가가 됨 (dev는 `6d84c73`에서 수정, prod 미수정) | `storage-prod.yaml:42` |
| **G17** | — | AppProject `namespaceResourceWhitelist`에 `security.istio.io`·`gateway.networking.k8s.io` 없음 → **`service-mesh/` 전체 sync 거부.** `networking.k8s.io`·`policy`도 클러스터 화이트리스트에만 존재 | `projects/oneinchmarket.yaml:24-46` |
| **G18** | — | 워크로드 15개가 SA 지정, SA는 3개만 존재 | 커밋 `f08512f` 이후 |
| **G19** | — | 로테이션 시크릿 키 이름 불일치 7개 중 4개 | `rotate-*.yaml` |
| **G20** | — | rotate-elasticsearch가 `elasticsearch-secret` 패치, 소비자는 ECK 시크릿 | `rotate-elasticsearch.yaml:56` |
| **G21** | — | git-sync 출력 경로 `base/rotation/secrets/` 부재 | `rotation-git-sync.yaml:65` |
| **G22** | — | **DB·롤·버킷·토픽 부트스트랩 전무** | `postgresql-configmap.yaml:10-11` |
| **G23** | — | Kafka `KAFKA_LOG_DIRS` 미설정·`CLUSTER_ID` 없음·NetPol 9093 규칙 없음 | `kafka-configmap.yaml`, `messaging-netpol.yaml` |
| **G24** | — | Kyverno에 시스템 NS 예외 없음 → prod Enforce 시 플랫폼 차단 | `kyverno-*.yaml` |
| **G25** | — | dev/prod 두 Application이 동일 ClusterPolicy를 다른 action으로 소유 → sync 충돌 | `overlays/*/kustomization.yaml` |
| **G26** | prod 수동 배포 게이트 | CI는 `when: manual`이나 **ArgoCD prod가 `automated{prune,selfHeal}`** → `v2` 머지 시 자동 적용. `rotation-git-sync`가 리뷰 없이 `v2`에 push | `oneinchmarket-prod.yaml:30-34`, `rotation-git-sync.yaml:69-75` |
| **G27** | — | **Egress 기본 차단 전무** (`policyTypes: [Ingress]`만) | `default-deny.yaml:12-13` |
| **G28** | — | Hetzner 방화벽이 서버에 미부착 | `compute/hetzner/main.tf:15-27` |
| **G29** | — | `rotate-admin`·`rotate-minio`가 `--insecure`로 **관리자 비밀번호를 TLS 검증 없이 전송** | `rotate-admin.yaml:47-97` |
| **G30** | — | `secret-rotator` Role에 `resourceNames` 없음 | `secret-rotator-rbac.yaml:20-23` |
| **G31** | — | prod 핀닝이 `alpine/git`·`curlimages/curl`·`minio/mc`·`bitnami/redis-cluster`·`aquasec/trivy`·falco 계열 미포함 | `overlays/prod/kustomization.yaml:19-53` |
| **G32** | — | GitLab이 `drop: ALL` 없이 capability 8종 추가 | `gitlab-statefulset.yaml:76-85` |
| **G33** | — | `07-netpol-test.sh:27`이 없는 `default-deny-all`을 찾음. `08-age-key-backup.sh:80-94`는 오늘 실행 시 13건 FAIL | — |
| **G34** | — | `nginx`·`falcosidekick`·`logstash`가 `default` SA 사용 | — |
| **G35** | — | `require-standard-labels`·`require-health-probes`는 prod에도 Enforce 패치 없음 | `overlays/prod/patches/` |
| **G37** | — | 이미지 다이제스트 핀닝 없음 | — |
| **G38** | — | 계획서는 `vhp-*`(전용 vCPU), 코드는 `vhf-*`(공유) | `compute/main.tf:36-48` |
| **G39** | — | **Ranger가 Spark 경로(Livy·Connect·ETL)의 인가를 커버하지 못한다.** Ranger에는 Spark 플러그인이 없다. Trino 경로만 테이블·컬럼 수준 통제가 걸린다 | `data-lakehouse/spark/`, `data-lakehouse/livy/` |
| **G40** | — | **Livy는 세션마다 별도 driver 파드를 생성한다.** 세션 1개 = driver 1Gi + executor N×2Gi. `livy.server.session.max-creation`으로 상한을 걸지 않으면 상시 용량 산정 밖에서 메모리가 폭주한다 | `livy/livy-configmap.yaml` |
| **G41** | — | **kustomize `images:`는 ConfigMap 안의 이미지 참조를 바꾸지 못한다.** prod에서 StatefulSet 컨테이너는 `oneinch/spark-iceberg:3.5.6`으로 핀되지만, `spark-config`·`livy-config` 안의 `spark.kubernetes.container.image`·`livy.spark.kubernetes.container.image`는 `:latest`로 남는다 → **동적 생성되는 driver/executor가 `:latest`를 쓰며 prod `disallow-latest` Enforce를 위반한다** | `spark/spark-defaults-configmap.yaml`, `livy/livy-configmap.yaml` |

### 9-3. 실제로 구현된 것

- Kustomize base 10개 카테고리 + dev/prod 오버레이, sync-wave 0→8
- **securityContext 위생이 거의 전 워크로드에 적용됨** — `runAsNonRoot`·`seccompProfile: RuntimeDefault`·`drop: ["ALL"]`. 리소스 requests/limits 100%, 프로브 100%. 계획서 Phase 3의 3-2/3-3/3-4는 실제 완료
- v1→v2 스택 전환이 매니페스트에 실재 — Hadoop/HBase/Hive-Server/ZK/Ranger/Knox/DS389/Solr 제거, MinIO+Trino(Iceberg+Hive)+Hive Metastore-on-S3A, Kafka KRaft, Apicurio, AKHQ
- Kyverno 6정책(base Audit, prod 4종 Enforce), 표준 레이블, 전 워크로드 `reloader.stakater.com/auto`
- OpenTofu 멀티 프로바이더 구조 — **Vultr 구현은 완전**(VPC, 방화벽 그룹 2종, bastion/master/worker 3-tier)
- WireGuard 게이트 k3s 부트스트랩 7단계 자동화
- GitLab CI 6스테이지 — kustomize/kubeconform, Trivy image/config/fs, Cosign, Skopeo, ArgoCD
- 보안 검증 스크립트 9종 + `run-all.sh`
- prod 이미지 17개 태그 핀닝, PDB 8개

---

## 10. 아키텍처 결정 필요 항목 (TODO)

### 외부 접근

- **TODO-01** — 남-북 진입 전략. traefik·servicelb 비활성이고 Ingress/Gateway/NodePort/LB 객체가 없으며 nginx는 ClusterIP. **v1에는 ingress-nginx + Ingress 5종이 있었다**(`v1/nginx/`) — 이관 누락에 가깝다.
- **TODO-02** — TLS 전략. cert-manager 없음. **v1에는 Issuer/Certificate가 있었다**(`v1/elk/elasticsearch/`).
- **TODO-03** — 오퍼레이터 설치 주체. **v1에는 ECK 설치 코드가 있었다**(`v1/elk/elasticsearch/elasticsearch.sh:1-2`).
- **TODO-14** — nginx upstream이 `*.dev.svc.cluster.local` 하드코딩 → prod 오동작.

### 컨트롤플레인 · HA

- **TODO-04** — k3s 단일 서버 + SQLite. prod SPOF 허용 여부.
- **TODO-05** — prod `replicas: N`은 독립 인스턴스 N개. 오퍼레이터 도입 여부.
- **TODO-06** — Redis 토폴로지. `redis-pdb minAvailable: 4`가 클러스터를 전제한다.

### 스토리지 · DR

- **TODO-07** — storageClass. 전부 `standard`인데 k3s 기본은 `local-path`. **블록 스토리지 $225/월 vs 로컬 NVMe $0 vs 데이터 이동성**의 비용 결정이다.
- **TODO-08** — 백업/DR 전무. tfstate는 local backend, 잠금 없음.
- **TODO-09** — MinIO 단일 레플리카가 레이크하우스를 보유.

### 레이크하우스

- **TODO-10** — 스키마 부트스트랩 주체 (G22).
- **TODO-11** — Iceberg 카탈로그: HMS vs REST vs JDBC.
- **TODO-12** — Trino coordinator/worker 분리 및 spill 스토리지.
- **TODO-33** — ~~HDFS ↔ MinIO 이중 스토리지. Hive warehouse 위치.~~ **로컬에서 해소**(LOCAL-DEPLOYMENT §8-16). 한 HiveServer2 가 `hdfs://` 와 `s3a://` 를 동시에 처리한다 — `hadoop-hdfs-client` 와 `hadoop-aws` 가 한 클래스패스에 공존하고 `FileSystem` 이 스킴별로 구현체를 고른다. 정할 것은 **기본값뿐**이다: `fs.defaultFS=hdfs://…`(scratch·중간 결과), `hive.metastore.warehouse.dir=s3a://…`(기본 웨어하우스). 나머지는 테이블·DB 의 `LOCATION`/`MANAGEDLOCATION` 으로 지정한다. dev/prod 적용은 미결.

### 보안

- **TODO-13** — PSS 예외 구조. Falco/Tetragon·Filebeat·GitLab·Cilium·Suricata/Zeek·node-exporter가 `restricted`에서 admit되지 않는다. **보안 전용 NS를 `privileged`로 분리하고 워크로드 NS만 `restricted` 유지**가 실질적 해답이다.
- **TODO-15** — Kyverno 시스템 NS 예외 (G24).
- **TODO-16** — ClusterPolicy 소유권 분리 (G25).
- **TODO-17** — ambient 완주 및 STRICT 전환 (§6-7).
- **TODO-18** — ServiceAccount 12개 신규 생성 (G18).
- **TODO-19** — NetworkPolicy 커버리지 + egress 정책 (G13·G27).
- **TODO-20** — 공급망 루프 완결 (G10·G37).
- **TODO-36** — 로컬 빌드 이미지의 root 실행 예외 정책.

### GitOps · 전달

- **TODO-21** — AppProject 화이트리스트 확장 (G17).
- **TODO-22** — 부트스트랩 순환. ArgoCD가 GitLab에서 sync하는데 GitLab은 ArgoCD가 wave 8에 배포한다.
- **TODO-23** — 애플리케이션 소스 위치 (G9).
- **TODO-24** — `kubeconform-validate`가 kubeconform 이미지에서 `kustomize`를 실행하고 `allow_failure: true` → 스키마 게이트 무력화.
- **TODO-40** — Jenkins ↔ GitLab CI 역할 분담.

### 환경 정합성

- **TODO-25** — prod에 dev가 가진 ECK podTemplate 레이블 패치가 없다.
- **TODO-26** — prod GitLab VCT 이름 불일치 (G16).
- **TODO-27** — prod IaC 사용 가능 여부 (G5).
- **TODO-28** — dev/prod 동일 `network_cidr`. OPNsense의 Vultr 배치 실현성 `[UNVERIFIED]`.
- **TODO-31** — Vultr 플랜 계열 `vhf`(공유) vs `vhp`(전용) 확정 (G38).
- **TODO-32** — dev 노드 사이징 및 ES dev 축소 패치. 현재 dev도 ES 3노드다.

### 신규 스택

- **TODO-34** — ZooKeeper 재도입 범위 (HBase 전용, Kafka는 KRaft 유지).
- **TODO-35** — 인증 마스터: DS389(LDAP) vs Keycloak(OIDC) 페더레이션.
- **TODO-37** — 로컬 빌드 이미지 3종 레지스트리·빌드 파이프라인.
- **TODO-38** — `kerberos` 이미지가 `fedora:rawhide`(재현 불가 태그).
- ~~**TODO-39** — Apicurio Studio 이미지 가용성 `[UNVERIFIED]`.~~ **해소(2026-09-01)** — Studio 는 upstream 에서 완전 폐기되었고 기능이 Registry 3.1.0 에 opt-in 으로 흡수되었다. `apicurio/apicurio-studio` 에는 GA 태그가 없다(1.0.0.Beta1·latest-snapshot 뿐). ADR-021 참조.
- **TODO-41** — CSPM 공백. Prowler/ScoutSuite는 Vultr 미지원. Checkov로 IaC 사전 검사만 대체하고 런타임 클라우드 포스처는 공백으로 남는다.
- **TODO-42** — **Spark ETL 잡 미결.** Spark·Livy·Spark Connect는 `[작업 수단]`으로만 배치했다. 무엇을 적재·변환할지는 결정되지 않았다. 후보: ⓐ Kafka `falco-alerts`·`keycloak-events` → Iceberg 스트리밍 적재 ⓑ Iceberg 테이블 유지보수(compaction·expire-snapshots) 정기 잡 ⓒ 외부 소스 배치 적재. **결정 전까지 `spark-etl-cronjob.yaml`을 만들지 않는다.**
- **TODO-43** — Spark Connect 인증을 Istio AuthorizationPolicy로 강제하려면 PeerAuthentication이 STRICT여야 한다. 현재 base는 PERMISSIVE라 `spark-connect-authz.yaml`은 실효가 없다. SEC-108(ambient 우회 탐지)이 선행 게이트다.
- **TODO-44** — `docker/spark-iceberg`·`docker/livy`가 Maven Central·ASF에서 JAR·배포판을 받는다. 체크섬·서명 검증이 없어 SEC-512(런타임 외부 의존)와 같은 유형의 노출이 남는다.
- **TODO-45** — Livy 0.9.0-incubating의 Kubernetes 전용 튜닝 키(앱 조회 타임아웃·UI 프록시)를 릴리스 문서와 대조해 `livy-configmap.yaml`에 반영한다. 현재 `livy.spark.*` 패스스루만 사용한다.
- **TODO-46** — Livy·Spark History 앞단 `oauth2-proxy`(Keycloak OIDC) 매니페스트 미작성. NetworkPolicy는 이미 `oauth2-proxy` 셀렉터를 전제한다.
- **TODO-47** — G41 해소 방식 결정. ⓐ 이미지 참조를 전용 ConfigMap 키로 분리해 prod가 그 키만 패치 ⓑ kustomize `replacements`로 ConfigMap 내부 문자열 치환 ⓒ `spark-submit --conf`로 제출 시점 주입. **ⓐ가 전체 `spark-defaults.conf`를 prod에 복제하지 않아 드리프트 위험이 없다** (ADR-011 교훈).
- **TODO-48** — HiveServer2 의 `hadoop.proxyuser.hive.*=*` 는 Kerberos 가 없는 로컬 전제다. dev/prod 에서는 위임 대상을 실제 클라이언트 사용자로 좁히거나 Knox/Ranger 경유로 대체해야 한다 (SEC 신규 항목 후보).
- **TODO-49** — HiveServer2 는 Tez **로컬 모드**로 돈다(`tez.local.mode=true`). DAG 가 HiveServer2 JVM 안에서 실행되므로 분산 실행·동시 질의 규모에 한계가 있다. 실배치에서는 YARN(ResourceManager·NodeManager)을 올리고 로컬 모드를 끄거나, HiveQL 경로 자체를 Trino·Spark 로 흡수할지 결정한다.
- **TODO-50 해소**(2026-09-03) — `docker/jenkins/` 로컬 빌드 이미지에 `jenkins-plugin-cli` 로 플러그인을 굽고(요청 4종 + 의존 55종 = 59개), JCasC 로 관리자 계정·인가 전략을 선언했다. `runSetupWizard=false` 를 **보안 영역 선언과 함께** 주므로 인증 없는 Jenkins 가 되지 않는다. 비밀번호는 `jenkins-secret` 에서 환경변수로 주입되어 ConfigMap 에 평문이 남지 않는다.
- **TODO-51** — Pyroscope 가 애플리케이션을 프로파일링하지 못한다(자기 자신만 본다). ⓐ Pyroscope Java 에이전트를 `cmmn-api` 이미지에 넣으려면 G9(Dockerfile 부재) 해소가 선행된다 ⓑ Grafana Alloy 의 eBPF 프로파일링은 앱 변경이 필요 없으나 WSL2 에서 동작할지 미검증이다 — Falco 의 modern_ebpf 는 실패했고(W3) Tetragon 은 동작하므로 해봐야 안다. 결정 전까지 Pyroscope 는 "도구는 섰지만 대상이 없는" 상태다.
  - 남은 것: **에이전트가 없어 빌드가 컨트롤러에서 돈다**(`numExecutors: 1`). 에이전트를 붙이면 0 으로 내리고 `mode: EXCLUSIVE` 로 바꿀 것. `allow-jenkins-access` 에 `jenkins-agent` 셀렉터를 미리 열어 두었다.
  - 남은 것: **TODO-40**(Jenkins ↔ GitLab CI 역할 분담)은 여전히 미결이다. 지금 Jenkins 에는 잡이 하나도 없다.
  - 플러그인 버전을 고정하지 않는다 — `jenkins-plugin-cli` 가 코어 호환 버전을 고르므로, 버전을 박으면 base 의 `:lts` 가 올라갈 때 조합이 깨진다. 재현성은 이미지 태그로 잡는다(TODO-44 와 같은 계열의 미검증 다운로드는 남는다).

---

## 11. ADR 색인

전체 54건은 [`ADR-CANDIDATES.md`](./ADR-CANDIDATES.md) 참조.

| 범주 | ADR |
|---|---|
| 데이터 플랫폼 | 001(Hadoop→MinIO, **부분 철회**) · 002(KRaft) · 017(Iceberg 카탈로그) · 022(v1 복원 범위) · 032/033(Kafka Bridge) · 034(Kafka Strimzi) · 035(외부 노출) · **064(Spark 도입)** · **065(Livy+Connect)** · **066(FreeIPA 제거, `Accepted`)** |
| 매니페스트 · GitOps | 003(Helm 미사용) · 004(Kustomize) · 005(ArgoCD sync wave) · 054(프로파일 컴포넌트) · 062 · 063 |
| IaC | 011(멀티 프로바이더, **Superseded**) · 019(Vultr 단독) · 051~053(Hyper-V) |
| 네트워크 · 메시 | 009(Istio Ambient) · 010(WireGuard bastion) · 023(Cilium) · 043(공존 규약) · 044(암호화) · 045(정책 계층) · 028(OPNsense) · 029(WAF) |
| 보안 | 007(Kyverno) · 008/025(Falco↔Tetragon) · 024(Vault) · 030(Caldera) · 046(Aqua OSS) · 047~050 |
| 관측성 | 026(도메인 분리) · 027(Loki) · 031(Logstash) · 036~038(Sentry) · 039~042(OTel) |
| 운영 · 비용 | 013(DB HA) · 014(로테이션) · 015(StorageClass) · 055~061(사이징·배치) |

---

## 관련 문서

- [PRD.md](./PRD.md) — 제품 요구사항, 목표/비목표, Phase 달성도
- [SECURITY.md](./SECURITY.md) — SEC-xxx 보안 요구사항, 통제 인벤토리
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소 카탈로그, v1↔v2 대조
- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx 인프라 요구사항, 배포 절차, 용량·비용
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — 아키텍처 결정 기록 후보 63건
