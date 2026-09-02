# COMPONENTS — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> 표기 규칙은 [ARCHITECTURE.md](./ARCHITECTURE.md) 서두와 동일하다.
>
> **컬럼 설명**
> - `Rep` — base 레플리카 (괄호 안은 dev/prod 오버레이 값)
> - `MEM` — 로컬 프로파일 기준 추정 작업 메모리 (레플리카 1 + JVM 힙 명시 설정 적용)
> - `로컬` — 64 GB 로컬 프로파일 포함 여부

---

## 목차

1. [v1 → v2 구성요소 대조](#1-v1--v2-구성요소-대조)
2. [core](#2-core)
3. [observability](#3-observability)
4. [security](#4-security)
5. [lakehouse-v1](#5-lakehouse-v1)
6. [governance](#6-governance)
7. [devops](#7-devops)
8. [apm](#8-apm)
9. [플랫폼 계층 (ArgoCD 밖)](#9-플랫폼-계층-argocd-밖)
10. [서비스·포트 일람](#10-서비스포트-일람)
11. [의존 관계](#11-의존-관계)
12. [클러스터에 없는 것](#12-클러스터에-없는-것)

---

## 1. v1 → v2 구성요소 대조

v1은 31개 서비스 디렉터리 / 201개 파일이었다. **v1은 `kind` 클러스터 기반 로컬 환경**이었다 (`v1/cluster/cluster-config.yaml`).

### 1-1. 대체됨

| v1 | v2 | 근거 |
|---|---|---|
| hadoop (NN 2·DN 3·JN 3·RBF 1) | **MinIO + Trino + Iceberg** | 계획서 §3 — 29 pods 제거 |
| hbase (HM 2·RS 3) | 제거 | 사용처 없음 |
| hive/server | **Trino** | metastore만 승계 |
| zookeeper ×3 | 제거 | **Kafka KRaft** |
| schema-reg (Confluent) | **Apicurio Registry** | |
| kafka-ui (provectuslabs) | **AKHQ** | |
| kafka/rest (`confluentinc/cp-kafka-rest`) | **Strimzi Kafka Bridge** | ADR-032 — Apache 2.0 |
| jenkins | **GitLab CI** | 계획서 전환표에 명시 없음 — ADR-020으로 명문화 |
| NodePort 30개 | ClusterIP + Ingress | Ingress는 미구현 (TODO-01) |
| kind 로컬 클러스터 | **Hyper-V + k3s** | ADR-051 — 다중 노드·실제 CNI·실제 스토리지 |

### 1-2. 복원 대상 `[목표]` — ADR-022

사용자 결정: **`schema-reg`·`kafka-ui`를 제외한 v1 전용 구성요소 전부 복원.**

| 카테고리 | 구성요소 | 파드 |
|---|---|--:|
| 분산 스토리지 | hadoop-namenode ×2, datanode ×3, journalnode ×3, rbf-router ×1 | 9 |
| NoSQL | hbase-hmaster ×2, regionserver ×3 | 5 |
| 질의 | hive-server ×1 | 1 |
| 코디네이션 | zookeeper ×3 | 3 |
| 데이터 거버넌스 | ranger-admin, ranger-usersync, solr, knox | 4 |
| 인증/디렉터리 | ds389, kerberos, lam | 3 |
| 메시징 | **kafka-bridge** (kafka-rest 대체) | 1 |
| API 관리 | apicurio registry-ui, studio-api, studio-ui, studio-ws | 4 |
| DevOps | jenkins | 1 |
| 진입점/TLS | ingress-nginx ×2, cert-manager ×3 | 5 |
| **합계** | | **37** |

### 1-3. v1에 있었으나 v2에서 누락된 인프라 요소

**TODO로 잡았던 항목 상당수가 v1에 이미 구현되어 있었다.**

| v1 위치 | 내용 | v2 | 연결 |
|---|---|---|---|
| `v1/nginx/controller/`, `v1/nginx/ingress/` | ingress-nginx + Ingress 5종(admin/auth, gitlab, registry.gitlab, argocd, kafka-ui, knox) + TLS Secret | **전무** | TODO-01 |
| `v1/elk/elasticsearch/elasticsearch-{issuer,certificate}.yaml` | cert-manager `Issuer`(selfSigned) + `Certificate` | **전무** | TODO-02 |
| `v1/elk/elasticsearch/elasticsearch.sh:1-2` | ECK operator 설치 (`crds.yaml` + `operator.yaml` v3.2.0) | **전무** | TODO-03 |
| `v1/kafka/kafka-job.yaml` | Kafka 토픽 생성 Job (`keycloak-events`, 브로커 준비 5분 대기) | **전무** | G22 · `keycloak-events` 프로듀서 부재의 직접 원인 |
| `v1/mariadb/cmmn/init_mariadb.sh` | MariaDB 초기화 + **TDE(저장 데이터 암호화)** | **전무** | G22 |
| `v1/coredns/coredns` | CoreDNS rewrite (`auth.oneinchmarket.co.kr` → `keycloak-nodeport.dev.svc` 등) | **전무** | Keycloak SSO URL 검증 통과용 |
| `v1/nginx/admin/` | admin-nginx HTTPS 종단 (`backend-protocol: HTTPS`, `ssl-redirect`) | v2는 **평문 HTTP만** | TODO-02 |

> v2 DNS 모듈(`infra/modules/dns/vultr/main.tf:14-22`)이 생성하는 A 레코드가 `gitlab`·`argocd`·`keycloak`·`kafka-ui`·`kibana`·`minio`·`admin` — **정확히 v1 Ingress의 호스트 패턴이다.** v2는 Ingress를 전제로 DNS를 설계했으나 Ingress만 구현되지 않았다.

### 1-4. 기능 축소

| v1 | v2 | 검토 |
|---|---|---|
| `bitnami/redis-cluster` (실제 클러스터) | `bitnami/redis` standalone ×6 | 커밋 `7f21607` 기동 실패 회피용. TODO-06 |
| Kafka broker + controller **분리** StatefulSet | 단일 결합 (`broker,controller`) | 3노드 규모에선 결합이 일반적 — 유지 |
| Apicurio 5종 (registry + registry-ui + studio 3종) | registry 1종 | 스키마 편집 UI 소멸. AKHQ가 조회는 대체 |

### 1-5. v2의 Argo Events는 목적을 상실했다

v1 Sensor는 Keycloak `USER_CREATE`(realm=knox) 이벤트로 **Knox/Ranger 사용자 동기화 Job**을 돌리는 것이 목적이었다(`v1/argocd/argocd-kafka-sensor.yaml`). v2에서 Knox·Ranger가 제거되며 트리거가 `echo`만 하는 껍데기로 남았다(`argocd/events/keycloak-sensor.yaml:59-61`).

v1 복원으로 Knox·Ranger가 돌아오면 **원래 목적이 복구된다.**

### 1-6. 죽은 참조

| 위치 | 내용 |
|---|---|
| `messaging-netpol.yaml:26` | `kafka-rest` 셀렉터 — **Bridge 복원 시 `kafka-bridge`로 이름 변경하면 정상 규칙이 된다** |
| `messaging-netpol.yaml:29` | `schema-reg` 셀렉터 — 대상 파드 없음, **제거 대상** |
| `.gitignore` | `**/tde/` — v1 MariaDB TDE 잔재. TDE 복원 시 유효 |

---

## 2. core

**항상 포함되는 최소 동작 집합.** 로컬 소요 19.9 GB.

### 2-1. 데이터베이스 (wave 1)

| 서비스 | 이미지 (base / prod) | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **postgresql** | `bitnami/postgresql:latest` / `16.4.0` | 1 (prod 2) | 5432 | `data` `standard` (prod 50Gi) | 1.0 | ✅ |
| **mariadb** | `bitnami/mariadb:latest` / `11.4.3` | 1 (prod 2) | 3306 | `data` `standard` | 1.0 | ✅ |
| **mongodb** | `percona/percona-server-mongodb:latest` / `7.0.14` | 1 (prod 3) | 27017 | `data` `standard` | 1.0 | ✅ |
| **redis** | `bitnami/redis:latest` / `7.4.1` | **6** (dev 1) | 6379, 16379 | `data` `standard` | 0.3 | ✅ |

- PostgreSQL 소비자: Keycloak, GitLab, Apicurio, Hive Metastore, (복원 시) Ranger
- MariaDB 소비자: cmmn-api (`jdbc:mariadb://mariadb-headless:3306/cmmn`)
- **MongoDB 소비자: 매니페스트 전체에서 발견되지 않음**
- Redis: **standalone 6 레플리카** — 클러스터 아님 (G12). `redis-pdb minAvailable: 4`가 클러스터를 전제
- **`postgresql-configmap.yaml:10-11`은 `oneinchmarket` DB만 생성** → 나머지 DB·롤 부트스트랩 부재 (G22)

### 2-2. 메시징 (wave 2)

| 서비스 | 이미지 | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **kafka** | `apache/kafka:latest` / `4.1.1` | 3 (dev 1) | 9092, 9093 | `data` `standard` (prod 50Gi) | 1.0 | ✅ |
| **apicurio-registry** | `apicurio/apicurio-registry:latest` / `3.0.4` | 1 | 8080 | — | 0.5 | ✅ |
| **akhq** | `tchiotludo/akhq:latest` / `0.25.1` | 1 | 8080 | — | 0.5 | ✅ |
| **kafka-bridge** `[목표]` | `quay.io/strimzi/kafka-bridge` (버전 핀 필요) | 1 | **8080** | — | 0.3 | ✅ |

**Kafka 문제점** — `KAFKA_LOG_DIRS` 미설정으로 마운트한 PVC를 사용하지 않는다. `CLUSTER_ID` 없음. NetPol에 9093 규칙 없어 prod quorum 형성 불가 (G23).

**Kafka Bridge** — 상태 없음 → Deployment (ADR-033). Strimzi Cluster Operator는 도입하지 않는다: 단일 무상태 파드에 CRD 10종·광범위 ClusterRole은 비용 대비 이득이 없다. ADR-034(Kafka Strimzi 이관) 채택 시 `KafkaBridge` CR로 전환하며 비용은 파일 3개 삭제 + CR 1개.

**Bridge 운영 제약** — 컨슈머 인스턴스가 특정 파드 메모리에 존재하므로 `replicas > 1`이면 Service `sessionAffinity: ClientIP` + Ingress cookie 어피니티가 함께 필요하다. 스키마 레지스트리 연동 없음 (임베디드 포맷 `json`·`binary` 중심).

### 2-3. 레이크하우스 (wave 3·5)

| 서비스 | 이미지 | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **minio** | `minio/minio:latest` / `RELEASE.2024-11-07T00-52-20Z` | 1 | 9000, 9001 | `data` `standard` (dev 10Gi / prod 100Gi) | 1.0 | ✅ |
| **trino** | `trinodb/trino:latest` / `465` | 1 | 8080 | **없음** (`node.data-dir=/data/trino` 미마운트) | 1.5 | ✅ |
| **hive-metastore** | `apache/hive:4.0.1` (+ initContainer `busybox:1.36`) | 1 | 9083 | — | 0.8 | ✅ |
| **spark-history** `[작업 수단]` | `oneinch/spark-iceberg:latest` / `3.5.6` | 1 | 18080 | — (MinIO `spark-events`) | 0.5 | ✅ |
| **spark-connect** `[작업 수단]` | 동일 | 1 | **15002**(gRPC), 7078/7079(driver RPC) | — | 1.5 | ✅ |
| **livy** `[작업 수단]` | `oneinch/livy:latest` / `0.9.0-incubating` | 1 | **8998**(REST) | — (MinIO `livy-recovery`) | 1.0 | ✅ |
| **oauth2-proxy** `[목표]` | `quay.io/oauth2-proxy/oauth2-proxy` | 1 | 4180 | — | 0.15 | ✅ |


**Spark 계층 — `[작업 수단]`으로만 배치되었다 (ADR-064·065)**

- ETL 잡 자체는 **미결정**이다. `spark-etl-cronjob.yaml`은 존재하지 않으며 **TODO-42** 결정 전까지 만들지 않는다
- 네 실행 경로(ETL Job · History · Connect · Livy)가 `spark-config` ConfigMap 하나를 공유한다. Iceberg 카탈로그 좌표는 `trino-configmap.yaml:31-41`과 동일한 Hive Metastore·warehouse를 가리킨다 — **Spark가 쓴 테이블을 Trino가 즉시 조회한다**
- driver/executor는 **상시 구동이 아니다.** `PriorityClass: batch-low` + `spark.dynamicAllocation.minExecutors=0`으로 상시 용량 산정에서 제외한다. 잡 실행 시 driver 1Gi + executor N×2Gi가 일시적으로 추가된다
- **Kerberos는 채택하지 않는다.** ~~HDFS가 아니라 S3(MinIO)를 쓰므로 GSSAPI 경로가 없다~~ —
  **HDFS 가 들어왔으므로 이 근거는 더 이상 성립하지 않는다**(HBase 가 요구한다). 대신
  `hadoop.security.authentication=simple` 로 명시적으로 비활성화했다. 그 대가로
  HiveServer2 가 `hadoop.proxyuser.hive.*` 를 필요로 한다 — 위임 대상은 `users=hive`
  하나로 좁혔으나 `hosts=*` 는 그대로다(TODO-48). MinIO 자격증명(향후 OIDC+STS)은 별개다
- **G39** — Ranger가 Spark 경로의 인가를 커버하지 못한다. **G40** — Livy 세션당 driver 생성으로 메모리 폭주 가능
- Trino 카탈로그 2종: `iceberg`(`catalog.type=hive_metastore`, PARQUET), `hive`. 둘 다 `thrift://hive-metastore-headless:9083` + `s3.endpoint=http://minio-headless:9000` (path-style, `us-east-1`)
- Hive Metastore warehouse: `s3a://warehouse/tables`
- **initContainer가 기동 시 인터넷에서 PostgreSQL JDBC 드라이버를 다운로드**한다 — 체크섬 미고정, 런타임 외부 egress 의존 (SEC-512)
- **MinIO·Trino·Hive Metastore 모두 대상 NetworkPolicy가 없다** (G13)
- MinIO `warehouse` 버킷을 생성하는 주체가 없다 (G22)

### 2-4. 인증 (wave 4)

| 서비스 | 이미지 | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **keycloak** | `keycloak/keycloak:latest` / `26.0.7` | 1 (prod 2) | 8080, 8443, **9000(health)** | `keycloak-data` (**storageClassName 없음**) | 0.8 | ✅ |

- PostgreSQL `keycloak` DB 사용 — **DB 생성 주체 없음** (G22)
- health 엔드포인트는 관리 포트 9000 (커밋 `3088376`·`ffd014c`)
- **대상 NetworkPolicy 없음** (G13)
- **event-listener SPI 미설정** → `keycloak-events` Kafka 토픽에 프로듀서가 없다

### 2-5. 애플리케이션 (wave 6)

| 서비스 | 이미지 | Rep | 포트 | 의존 | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **admin** | `inquotient/admin:latest` / `1.0.0` | 1 | 3000 | `NEXTAUTH_URL`, `NODE_ENV`만 설정 | 0.5 | ✅ |
| **cmmn-api** | `inquotient/cmmn-api:latest` / `1.0.0` | 1 | 8080 | MariaDB `cmmn`, Redis, Kafka | 0.6 | ✅ |
| **nginx** | `nginx:latest` / `1.27.3` | 1 (prod 2) | 80, 443 | admin:3000, cmmn-api:8080 | 0.1 | ✅ |

- **`.gitlab-ci.yml`이 참조하는 `v1/admin/Dockerfile`·`v1/cmmn-api/Dockerfile`이 존재하지 않는다** (G9) → 이미지 빌드 불가
- nginx는 `resolver 10.43.0.10`(CoreDNS)을 쓰고 upstream이 **`*.dev.svc.cluster.local`로 하드코딩** → prod 오동작 (TODO-14)
- nginx Service는 443 포트를 선언하지만 **리스너가 없다** (설정은 80만)

### 2-6. 정책·메시 (wave 0)

| 리소스 | 개수 | 파일 |
|---|--:|---|
| Kyverno ClusterPolicy | 6 | `security/kyverno/` |
| NetworkPolicy | 14 (deny 1 + allow 13) | `network-policies/` |
| PeerAuthentication | 1 (**PERMISSIVE**) | `service-mesh/peer-authentication.yaml` |
| AuthorizationPolicy | 4 | `service-mesh/authorization-policies.yaml` |
| Gateway (waypoint) | 1 | `service-mesh/waypoint-proxy.yaml` |

### 2-7. 부트스트랩 Job `[목표]` (wave 1.5 · 2.5)

| Job | 대상 |
|---|---|
| `postgres-bootstrap` | DB·롤 4종 — `keycloak`, `gitlab`, `apicurio`, `hive_metastore` (+복원 시 `ranger`) |
| `mariadb-bootstrap` | `cmmn` DB·사용자 |
| `minio-bootstrap` | `warehouse` 버킷 |
| `hive-schematool` | Metastore 스키마 초기화 |
| `kafka-topics` | `keycloak-events`, `falco-alerts` 등 — **v1 `kafka-job.yaml` 패턴 계승** |

---

## 3. observability

로컬 소요 15.2 GB (최소 구성 12.2 GB).

| 서비스 | 이미지 | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **elasticsearch** (ECK CRD) | `8.17.0` | **3 (dev도 3)** | 9200 | `elasticsearch-data` 20Gi `standard` | 3.5 | ✅(1) |
| **kibana** (ECK CRD) | `8.17.0` | 1 | 5601 | — | 1.5 | ✅ |
| **logstash** | `docker.elastic.co/logstash/logstash:8.17.0` | 1 (prod 2) | 5044, 9600 | — | 1.5 | ✅ |
| **filebeat** | `docker.elastic.co/beats/filebeat:8.17.0` | DaemonSet | — | hostPath | 0.3/노드 | ❌ |
| `elasticsearch-ilm-setup` | `curlimages/curl:latest` | Job (PostSync) | — | — | — | ✅ |
| **prometheus** `[목표]` | — | 1 | 9090 | 100Gi | 3.0 | ✅ |
| **grafana** `[목표]` | — | 1 | 3000 | — | 0.7 | ✅ |
| **loki** `[목표]` | — | single-binary | 3100 | MinIO | 1.5 | ✅ |
| **tempo** `[목표]` | — | single-binary | 3200 | MinIO | 2.0 | ✅ |
| **jaeger** `[목표]` | — | collector 2 + query 1 | 16686 | Elasticsearch | 1.5 | ❌ |
| **otel-collector-agent** `[목표]` | — | DaemonSet | 4317/4318 | — | 0.3/노드 | ✅ |
| **otel-collector-gateway** `[목표]` | — | 3 (로컬 1) | 4317/4318 | — | 0.5 | ✅ |

**ES ILM**: 10GB / 7d rollover + delete phase. 인덱스 별칭 `logstash`·`falco-alerts`·`keycloak-events`·`trivy-reports`.

**dev에도 ES가 3노드로 유지된다** — 축소 패치가 없다 (TODO-32).

**Logstash 역할** — 현재는 `beats:5044`만 열고 아무도 보내지 않는 고아 상태(G11). **보안 이벤트 정규화 계층으로 재배치**한다 (ADR-031).

**자격증명 분열** — Filebeat·Logstash·ILM Job은 ECK 생성 `elasticsearch-es-elastic-user`, Falcosidekick·Trivy는 배포되지 않는 `elasticsearch-secret`을 참조한다.

---

## 4. security

`security-min` 5.5 GB + `security-full` 13.7 GB.

### 4-1. security-min

| 서비스 | 이미지 | Rep | 포트 | MEM | 로컬 |
|---|---|:-:|---|--:|:-:|
| **falco** | `falcosecurity/falco-no-driver:latest` | DaemonSet | — | 0.3/노드 | ✅ |
| **falcosidekick** | `falcosecurity/falcosidekick:latest` | 1 | 2801 | 0.3 | ✅ |
| **tetragon** `[목표]` (Falco 대체) | — | DaemonSet | — | 0.3/노드 | ✅ |
| **trivy-operator** `[목표]` | — | 1 | — | 0.7 | ✅ |
| **policy-reporter** `[목표]` | — | 2 | 8080 | 0.3 | ✅ |
| **vault** `[목표]` | — | 3 (로컬 dev 1) | 8200 | 0.5~3.0 | ✅ |
| **wazuh-manager** `[목표]` | — | 2 (로컬 1) | 1514, 1515, 55000 | 1.5 | ✅ |
| **wazuh-indexer** `[목표]` | — | 3 (로컬 1) | 9200 | 2.5 | ✅ |

**Falco 예외** — `privileged: true`, `hostNetwork: true`, `engine.kind=modern_ebpf`, containerd 소켓·`/proc`·`/dev`·`/boot` 마운트. 커밋 `5ca8068`에서 커널 모듈이 불필요한 modern-bpf 드라이버로 전환.

**Falcosidekick 출력** — ES `falco-alerts` 인덱스 **및** Kafka `falco-alerts` 토픽(`falcosidekick-configmap.yaml:20-44`). Kafka 경로가 Logstash → Wazuh 배선의 기반이 된다.

### 4-2. security-full

| 서비스 | Rep | MEM | 로컬(64GB) |
|---|:-:|--:|:-:|
| **safeline-waf** `[목표]` (mgt·detector·tengine·pg) | 4 컨테이너 | 3.0 | ❌ |
| **kubescape** `[목표]` (operator·kubevuln·storage·node-agent DS) | 4 + DS | 3.0 | ❌ |
| **dependency-track** `[목표]` (apiserver·frontend) | 2 | 3.0 | ❌ |
| **defectdojo** `[목표]` (django·celery worker·beat·nginx) | 6 | 3.0 | ❌ |
| **caldera** `[목표]` | 1 | 0.7 | ❌ |
| **wazuh-dashboard** `[목표]` | 1 | 1.0 | ❌ |

**Caldera 제약** — dev/local 전용, **prod 배포 금지**. 전용 네임스페이스 격리, 기본 상태 에이전트 미배포, 훈련 실행 창을 SIEM 알림 규칙에 등록해 실사고와 구분 (ADR-030).

### 4-3. 현행 Trivy CronJob

| 서비스 | 이미지 | 스케줄 | 문제 |
|---|---|---|---|
| `trivy-image-scan` | `aquasec/trivy:latest` | `0 6 * * 1` | **이미지에 `kubectl`이 없고, `--cacert`를 쓰면서 인증서 볼륨을 마운트하지 않는다 → 동작 불가.** Trivy Operator로 대체 (ADR-047) |

### 4-4. 로테이션 (wave 8) — Vault 채택 시 제거 대상

| CronJob | 이미지 | 스케줄 | 문제 |
|---|---|---|---|
| `rotate-postgresql` | `bitnami/postgresql:latest` | `0 3 1,15 * *` | 키 이름 불일치 (`postgres-password` vs `postgresql-password`) |
| `rotate-mariadb` | `bitnami/mariadb:latest` | `5 3 1,15 * *` | 키 이름 불일치 |
| `rotate-mongodb` | `percona/percona-server-mongodb:latest` | `10 3 1,15 * *` | 키 이름 불일치 |
| `rotate-elasticsearch` | `curlimages/curl:latest` | `10 3 1,15 * *` | **잘못된 Secret 대상** + 이미지에 kubectl 없음 |
| `rotate-redis` | `bitnami/redis-cluster:latest` | `15 3 1,15 * *` | 유일하게 키 이름 일치. **이미지가 워크로드(`bitnami/redis`)와 달라 prod 핀닝 미적용** |
| `rotate-minio` | `minio/mc:latest` | `15 3 1,15 * *` | 키 이름 불일치 + `--insecure` + `https://` (MinIO는 HTTP) |
| `rotate-admin` | `curlimages/curl:latest` | `20 3 1 */3 *` | `--insecure` + argocd NS 시크릿 패치(RBAC 범위 밖) |
| `rotation-git-sync` | `alpine/git:latest` | `30 3 1,15 * *` | 출력 경로 부재 + 런타임 `apk add` + **리뷰 없이 `v2` push** |

RBAC: `secret-rotator` SA + 네임스페이스 Role (`secrets` `get`/`patch`, **`resourceNames` 없음**).

---

## 5. lakehouse-v1 `[목표]` — 로컬은 배포 완료

ADR-022 복원 대상. 로컬 소요 9.2 GB (레플리카 1 기준).

> **2026-09-02** — 브랜치 `local` 에서 **비-HA 구성으로 전부 기동했다**
> (LOCAL-DEPLOYMENT §8-14~16). JournalNode·RBF Router 는 HA 전용이라 만들지
> 않았다. 아래 표의 "HA Rep" 은 여전히 목표값이며, 실배포한 것은 "로컬 Rep" 이다.

| 서비스 | v1 이미지 | HA Rep | 로컬 Rep | MEM | 의존 |
|---|---|:-:|:-:|--:|---|
| **zookeeper** | `zookeeper:3.9.5` | 3 | 1 | 0.7 | — |
| **hadoop-journalnode** | `apache/hadoop:3.4.3` | 3 | 0 | — | ZK · **미배포**(HA 전용) |
| **hadoop-namenode** | `apache/hadoop:3.4.3` | 2 | 1 | 1.5 | JN, ZK |
| **hadoop-datanode** | `apache/hadoop:3.4.3` | 3 | 1 | 1.5 | NN |
| **hadoop-rbf-router** | `apache/hadoop:3.4.3` | 1 | 0 | — | NN · **미배포**(단일 NN 에 불필요) |
| **hbase-hmaster** | `oneinch/hbase:2.6.6` **(로컬 빌드)** | 2 | 1 | 1.2 | ZK, HDFS |
| **hbase-regionserver** | `oneinch/hbase:2.6.6` **(로컬 빌드)** | 3 | 1 | 2.0 | HMaster |
| **hive-server** | `apache/hive:4.0.1` | 1 | 1 | 1.5 | Hive Metastore |

**TODO-33 해소** — 양자택일이 아니었다. `apache/hive:4.0.1` 한 이미지에 `hadoop-hdfs-client`
와 `hadoop-aws` 가 함께 있고 Hadoop `FileSystem` 이 URI 스킴별로 구현체를 고르므로 **한
HiveServer2 가 `hdfs://` 와 `s3a://` 를 동시에 처리한다.** 정할 것은 기본값뿐이다 —
`fs.defaultFS`=HDFS(scratch·중간 결과), `hive.metastore.warehouse.dir`=S3A(기본 웨어하우스).
나머지는 DB·테이블의 `LOCATION`/`MANAGEDLOCATION` 으로 지정한다. 로컬에서 두 스킴의 테이블을
한 질의로 JOIN 해 실증했다(LOCAL-DEPLOYMENT §8-16). **dev/prod 적용은 아직 하지 않았다.**

> `hadoop-aws` 는 `share/hadoop/tools/lib` 에 있고 이 경로는 Hadoop 기본 클래스패스가
> **아니다.** `HADOOP_CLASSPATH` 에 넣지 않으면 `fs.s3a.impl` 을 적어 두어도
> `ClassNotFoundException: S3AFileSystem` 이다 — 메타스토어에도 원래 있던 결함이다.

**TODO-37** — `oneinch/hbase:2.6.6` 은 `docker/hbase/Dockerfile` 기반 로컬 빌드 이미지다.
`local/build-images.sh` 가 podman 으로 빌드해 k3s containerd 로 반입한다. **레지스트리 경로·
CI 빌드 파이프라인은 여전히 없다** — `oneinch/spark-iceberg`·`oneinch/livy`·
`oneinch/ranger-usersync` 와 같은 상태다.

---

## 6. governance `[목표]`

로컬 소요 5.9 GB. **FreeIPA는 제외되었다 (ADR-066).**

| 서비스 | v1 이미지 | Rep | MEM | 의존 |
|---|---|:-:|--:|---|
| **ds389** (LDAP) | `389ds/dirsrv:latest` | 1 | 0.7 | — |
| **kerberos** | **`fedora:rawhide`** | 1 | 0.3 | — |
| **lam** | `ldapaccountmanager/lam:latest` | 1 | 0.3 | DS389 |
| **solr** | `apache/solr:9.10.0-slim` | 1 | 1.2 | — |
| **ranger-admin** | `apache/ranger:2.7.0` | 1 | 1.5 | PostgreSQL `ranger`, Solr, DS389 |
| **ranger-usersync** | `eclipse-temurin:8u452-b09-jdk-noble` | 1 | 0.7 | DS389 |
| **knox** | `knox-gateway:2.1.0` **(로컬 빌드)** | 1 | 1.2 | DS389, Kerberos, Hadoop |

### 확인된 의존 관계 (v1 configmap 근거)

```
ds389 (ldap://ds389-headless:3389)
  ├─→ ranger-admin      인증 + usersync
  ├─→ knox              Shiro JndiLdapRealm
  └─→ lam               디렉터리 관리
kerberos → knox         gateway.hadoop.kerberos.{keytab,principal}
postgresql → ranger-admin   db_name=ranger, db_user=rangeradmin
solr → ranger-admin     audit_store=solr, collection=ranger_audits   ← Solr의 유일한 용도
```

**중요** — `v1/ranger/admin/ranger-admin-configmap.yaml:179`에 **`io.trino.jdbc.TrinoDriver` 설정이 이미 존재한다.** Ranger를 Hadoop 없이 **Trino/Iceberg 접근제어(테이블·컬럼·행 수준 + 감사 로그)** 로만 쓰는 축소 구성이 성립한다. 이 기능은 현재 v2에 완전히 빠져 있다.

**SEC-402** — 같은 파일 6행에 DB 비밀번호가 평문으로 커밋되어 있다. 복원 시 Secret 전환 필수.

**TODO-38** — `kerberos`가 `fedora:rawhide`(재현 불가 롤링 태그)를 사용한다. Kyverno `disallow-latest` 취지에도 위배된다.

~~**TODO-39** — `apicurio/apicurio-studio-{api,ui,ws}` 이미지의 현재 pull 가능 여부는 `[UNVERIFIED]`.~~ **해소(2026-09-01)** — Studio 는 완전 폐기되었다. 대신 `apicurio-registry-ui:3.3.2` 를 배포하고 Registry 의 `apicurio.rest.mutability.artifact-version-content.enabled` 로 편집 기능을 켰다. ADR-021 참조.

---

## 7. devops

| 서비스 | 이미지 | Rep | 포트 | PVC | MEM | 로컬 |
|---|---|:-:|---|---|--:|:-:|
| **gitlab** | `gitlab/gitlab-ee:latest` / `17.6.2-ee.0` | 1 | 80, 443, 22 | `gitlab-data` (dev 20Gi / **prod 패치는 `data` — 이름 불일치**) | 4.0 | ❌ |
| **jenkins** `[목표]` | `jenkins/jenkins:latest` | 1 | 8080, 50000 | — | 1.2 | ❌ |

**GitLab 보안 예외** — `runAsUser: 0`, `runAsGroup: 0`, `fsGroup: 0`, `runAsNonRoot: false`, `allowPrivilegeEscalation: true`, capability 8종 추가(`CHOWN`·`DAC_OVERRIDE`·`FOWNER`·`SETGID`·`SETUID`·`NET_BIND_SERVICE`·`SYS_CHROOT`·`KILL`) **`drop: ALL` 없이**. 커밋 `2911a41`에 사유 기록.

**메모리** — 2Gi에서 OOMKilled 이력(커밋 `c889fb7`) → 4Gi 상향. 축소 불가.

**startup probe** — 20분 타임아웃 (커밋 `32a2649`).

**TODO-40** — Jenkins 복원 시 GitLab CI와의 역할 분담 정의 필요.

---

## 8. apm

| 옵션 | 구성 | 파드 | MEM | 권고 |
|---|---|--:|--:|---|
| **Sentry** (Helm, ADR-036 ⓑ) | Relay 2, web 2, worker 3, cron, snuba api 2 + consumer 8, post-process 2, **ClickHouse**, Memcached, **전용 Kafka·Redis** | ~22 | 22 GB | 요청 사항 |
| **GlitchTip** (ADR-036 ⓓ) | web, worker (PostgreSQL·Redis 재사용) | 3~4 | **2.0 GB** | **권고** |

**OTel 채택으로 백엔드 잠김이 사라졌다** — 계측이 OTLP이므로 백엔드 교체가 Collector 설정 변경이다. APM·트랜잭션 추적은 Tempo/Jaeger가 담당하므로 Sentry의 고유 영역은 오류 그룹핑·릴리스 회귀 탐지·이슈 워크플로로 좁아진다.

**클라우드 비용 차이 −$384/월, 로컬 배포 가능성 16 GB 차이.**

> Sentry의 OTLP 직접 수집 지원 범위는 `[UNVERIFIED]`. 확인 전까지는 Sentry SDK와 OTel SDK를 병행하되 W3C Trace Context를 공유하는 구성을 기본으로 한다.

**전제 조건** — 애플리케이션 SDK 계측이 필요하나 **G9(Dockerfile 부재)로 이미지 빌드가 불가능**하다. OTel Operator 자동 계측(`instrumentation.opentelemetry.io/inject-{java,nodejs}`)이 이 제약을 우회한다 (ADR-042).

---

## 9. 플랫폼 계층 (ArgoCD 밖)

ArgoCD가 아니라 부트스트랩 스크립트가 설치한다 (wave −1).

| 구성요소 | 설치 주체 | 상태 | 비고 |
|---|---|---|---|
| **k3s** | `bootstrap-k3s.sh` | `[구현됨]` | v1.31.4+k3s1, `--disable traefik --disable servicelb` |
| **Istio Ambient** | `install-istio.sh` | `[구현됨]` | v1.24.2, `profile=ambient`. **`default` NS에만 레이블** |
| **istio-cni** | — | ❌ | ambient 필수 (M3) |
| **ArgoCD** | `install-argocd.sh` | `[구현됨]` | v2.13.3. **CMP 이름 불일치 (G3)** |
| **Stakater Reloader** | `install-reloader.sh` | `[구현됨]` | v1.2.0 |
| **Cilium + Hubble** | — | ❌ | M1·M2 설정 필수 |
| **ECK Operator** | — | ❌ | **v1에는 설치 코드가 있었다** |
| **Kyverno** | — | ❌ | 정책은 있으나 컨트롤러 설치 경로 없음 |
| **Gateway API CRD** | — | ❌ | waypoint Gateway가 의존 |
| **cert-manager** | — | ❌ | **v1에는 Issuer/Certificate가 있었다** |
| **Argo Events** | — | ❌ | `argo-events` NS·`argo-events-sa`도 없음 |
| **OTel Operator** | — | ❌ | 자동 계측 |
| **Trivy Operator** | — | ❌ | CronJob 대체 |
| **ingress-nginx** | — | ❌ | **v1에 있었다** |
| **OPNsense** | — | ❌ | 클러스터 밖 VM. Vultr 실현성 `[UNVERIFIED]` |

---

## 10. 서비스·포트 일람

| Service | 포트 | 대상 |
|---|---|---|
| `admin-headless` | 3000 | admin |
| `cmmn-api-headless` | 8080 | cmmn-api |
| `nginx` | 80, 443 | nginx (ClusterIP) |
| `hive-metastore-headless` | 9083 | Hive Metastore (thrift) |
| `minio-headless` | 9000, 9001 | MinIO (API, 콘솔) |
| `trino-headless` | 8080 | Trino |
| `mariadb-headless` | 3306 | MariaDB |
| `mongodb-headless` | 27017 | MongoDB |
| `postgresql-headless` | 5432 | PostgreSQL |
| `redis-headless` | 6379, 16379 | Redis |
| `gitlab-headless` | 80, 443, 22 | GitLab |
| `akhq-headless` | 8080 | AKHQ |
| `apicurio-registry-headless` | 8080 | Apicurio |
| `kafka-headless` | 9092, 9093 | Kafka (`publishNotReadyAddresses`) |
| `falcosidekick` | 2801 | Falcosidekick |
| `logstash-headless` | 5044, 9600 | Logstash |
| `keycloak-headless` | 8080, 8443, 9000 | Keycloak |
| `elasticsearch-es-http` | 9200 | ECK 생성 |
| `kafka-bridge` `[목표]` | 8080 | Kafka Bridge |

---

## 11. 의존 관계

```
PostgreSQL    ←── Keycloak · GitLab · Apicurio · Hive Metastore · (Ranger) · (GlitchTip)
MariaDB       ←── cmmn-api
MongoDB       ←── (소비자 없음)
Redis         ←── GitLab · cmmn-api · (GlitchTip)
Kafka         ←── cmmn-api · AKHQ · Falcosidekick · Argo Events · Logstash · Kafka Bridge
Apicurio      ←── AKHQ (ccompat)
MinIO         ←── Trino · Hive Metastore · Tempo · Loki
Hive MS       ←── Trino
Elasticsearch ←── Filebeat · Logstash · Falcosidekick · Trivy · Kibana · Jaeger
Wazuh Indexer ←── Logstash (보안 이벤트 정규화)
DS389         ←── Ranger · Knox · LAM · Keycloak(LDAP federation)
ZooKeeper     ←── HBase · Hadoop HA
Solr          ←── Ranger (감사 저장소)
```

### 컴포넌트 의존

| 컴포넌트 | 하드 의존 |
|---|---|
| core | — |
| observability | core (Logstash가 Kafka 입력 사용) |
| security-min | core + **observability** |
| security-full | security-min |
| lakehouse-v1 | core |
| governance | core (Ranger DB). Solr·DS389는 컴포넌트 내부 |
| devops | core (PostgreSQL, Redis) |
| apm | core + observability (OTel 경로) |

---

## 12. 클러스터에 없는 것

현재 매니페스트 전체 grep으로 **0건** 확인된 항목이다.

| 부재 항목 | 영향 | 연결 |
|---|---|---|
| `kind: Ingress` | 외부 진입 불가 | TODO-01 |
| cert-manager / ClusterIssuer / Certificate | TLS 없음 | TODO-02 |
| `type: LoadBalancer` / `NodePort` | 외부 노출 경로 없음 | TODO-01 |
| Prometheus / Grafana / metrics-server | 메트릭 관측 전무 | INFRA-601 |
| Velero / 스냅샷 / 논리 덤프 | 백업·DR 전무 | INFRA-504 |
| StorageClass 정의 | 전 PVC가 존재하지 않는 `standard` 참조 | INFRA-301 |
| ServiceAccount 12개 | 15개 워크로드가 없는 SA 지정 | G18 |
| Secret (렌더링 결과) | **0개** — 워크로드 기동 불가 | G2 |
| anti-affinity 규칙 | HA replicas가 같은 노드에 배치될 수 있음 | INFRA-506 |
| PriorityClass | 배치 워크로드가 상시 용량을 점유 | INFRA-604 |

---

## 관련 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 데이터 흐름, 갭 목록, TODO
- [SECURITY.md](./SECURITY.md) — SEC-xxx 보안 요구사항, 워크로드 커버리지
- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx, 배포 절차, 용량·비용
- [PRD.md](./PRD.md) — 제품 요구사항, Phase 달성도
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — 결정 기록 후보
