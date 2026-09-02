# ADR CANDIDATES — OneinchMarket Infrastructure v2

> 작성 기준일: 2026-08-30 · 브랜치 `v2` · 커밋 `edac4b1`
>
> **이 문서는 정식 ADR이 아니라 후보 목록이다.** 각 항목은 정식 ADR로 승격될 때 `docs/adr/NNNN-*.md`로 분리한다.
>
> **상태 정의**
>
> | 상태 | 의미 |
> |---|---|
> | `Accepted` | 이미 코드로 구현되어 있다. 소급 문서화한다 |
> | `Accepted (조건부)` | 채택했으나 충족해야 할 전제가 있다 |
> | `Proposed` | 설계로 확정했으나 미구현 |
> | `Open` | **사람의 결정이 필요하다** |
> | `Superseded` | 다른 ADR로 대체됨 |
> | `Partially Reverted` | 일부 철회됨 |

---

## 목차

- [데이터 플랫폼](#데이터-플랫폼)
- [매니페스트 · GitOps](#매니페스트--gitops)
- [IaC](#iac)
- [네트워크 · 서비스메시](#네트워크--서비스메시)
- [보안](#보안)
- [관측성](#관측성)
- [운영 · 사이징](#운영--사이징)
- [결정 요약](#결정-요약)

---

## 데이터 플랫폼

### ADR-001 — Hadoop/HBase/Hive-Server를 MinIO + Trino + Iceberg로 대체
**상태: `Partially Reverted`**

- **배경**: v1의 Hadoop 스택이 29 파드를 소비하며 운영 부담이 컸다.
- **결정**: `kubernetes/base/data-lakehouse/` — MinIO 오브젝트 스토어, Trino(`iceberg` + `hive` 커넥터), Hive Metastore를 `s3a://warehouse/tables`로 재지정.
- **대안**: HDFS 유지 / Delta Lake + Spark / Iceberg REST 카탈로그 / DuckDB·ClickHouse.
- **결과**: 파드 수 약 1/10, 스토리지·컴퓨트 분리, 클라우드 이식성. 다만 MinIO가 단일 노드이고 Hive Metastore가 PostgreSQL·Thrift 의존을 유지하며, Iceberg 테이블 유지보수(compaction·expiry) 주체가 없다.
- **철회 사유**: ADR-022로 Hadoop·HBase·Hive Server가 복원된다. **이 결정은 "대체"에서 "MinIO/Trino 추가 + Hadoop 병존"으로 성격이 바뀐다.** HDFS↔S3A 이중 스토리지 문제는 TODO-33.

### ADR-002 — Kafka를 KRaft 모드로 운영 (ZooKeeper 제거)
**상태: `Accepted`**

- **결정**: `kafka-configmap.yaml` — `broker,controller` 역할, 9093 quorum, 3노드.
- **대안**: ZooKeeper 기반 / Strimzi 오퍼레이터 / Redpanda·NATS.
- **결과**: 파드 3개 감소. 다만 수기 StatefulSet이라 오퍼레이터 수준의 리밸런싱·업그레이드가 없고, `KAFKA_LOG_DIRS` 미설정으로 PVC가 사용되지 않으며, 리스너가 PLAINTEXT이고, NetPol이 9093 quorum을 허용하지 않는다.
- **참고**: ADR-022로 ZooKeeper가 복원되지만 **HBase 전용**이며 Kafka는 KRaft를 유지한다 (TODO-34).

### ADR-017 — Iceberg 카탈로그: Hive Metastore vs REST vs JDBC
**상태: `Open`**

- **배경**: 현재 `iceberg.catalog.type=hive_metastore`로 Hive Metastore + PostgreSQL + Thrift가 임계 경로에 있다.
- **선택지**: ⓐ HMS 유지(v1 연속성, `hive` 커넥터 병행 가능) ⓑ Iceberg REST 카탈로그(HMS·Thrift SPOF 제거, wave 3 파드 1개 감소) ⓒ JDBC 카탈로그.
- **트레이드오프**: ⓑ는 현대적 기본값이나 기존 HMS 메타데이터 마이그레이션과 `hive` 커넥터 포기가 필요하다.

### ADR-022 — v1 스택 복원 범위
**상태: `Proposed`**

- **결정**: **`schema-reg`·`kafka-ui`·`freeipa`를 제외한 v1 전용 구성요소 복원.** 36 파드 — Hadoop 9, HBase 5, Hive Server 1, ZooKeeper 3, 거버넌스 4(Ranger·Solr·Knox), 인증 3(DS389·Kerberos·LAM), Kafka Bridge 1, Apicurio Studio 4, Jenkins 1, ingress-nginx·cert-manager 5. **FreeIPA 제외 근거는 ADR-066.**
- **대안**: ⓐ 인프라 누락분만(5 파드) ⓑ 거버넌스 축소안(15 파드 — Ranger를 **Hadoop 없이 Trino 접근제어로만** 활용) ⓒ 전체 복원.
- **근거**: `v1/ranger/admin/ranger-admin-configmap.yaml:179`에 이미 `io.trino.jdbc.TrinoDriver` 설정이 있어 Ranger가 Hadoop 없이도 성립한다.
- **결과**: 노드 비용 약 2배, 신규 결정 8건(TODO-33~40), PSS 예외 대량 필요. v1 매니페스트를 그대로 쓸 수 없고 v2 보안 규약(securityContext·리소스·프로브·NetPol·SA)에 맞춰 **재작성**해야 한다.

### ADR-032 — Kafka REST 인터페이스: Confluent REST Proxy → Strimzi Kafka Bridge
**상태: `Proposed`**

- **결정**: `confluentinc/cp-kafka-rest` 대신 `quay.io/strimzi/kafka-bridge`.
- **근거**: ① **Apache 2.0 라이선스** — Confluent Community License 대비. Apicurio 채택과 동일한 기준(SEC-511) ② **브로커를 직접 노출하지 않고 HTTP 단일 지점으로 외부 접근 수용** ③ Prometheus 메트릭 내장 ④ **v1/v2 전체에서 8082 API를 호출하는 내부 소비자가 없어 교체 비용 0**.
- **결과**: 포트 8082 → 8080. Schema Registry 연동 상실(v1 configmap에서도 주석 처리 상태였음). 컨슈머 API가 파드에 고정되어 `replicas > 1` 시 세션 어피니티 필수. `messaging-netpol.yaml:26`의 `kafka-rest` 셀렉터를 `kafka-bridge`로 개명하면 기존 규칙이 살아난다.

### ADR-033 — Kafka Bridge를 독립 Deployment로 운영
**상태: `Proposed`**

- **결정**: Strimzi Cluster Operator를 도입하지 않고 Deployment + ConfigMap으로 배포한다.
- **근거**: **단일 무상태 파드에 CRD 약 10종과 광범위 ClusterRole을 도입하는 것은 비용 대비 이득이 없다.** Bridge는 상태 없음, 설정 파일 1개, 포트 1개다. 설정 변경 시 재시작은 Reloader가 이미 처리한다.
- **명시적 배제**: "오퍼레이터 + KafkaBridge CR만" 조합은 **비용을 전부 치르고 이득은 최소인 최악의 조합**이다.
- **정정 기록**: 초기 검토에서 "Strimzi 오퍼레이터가 수기 Kafka와 충돌한다"고 판단했으나 **부정확**하다. 오퍼레이터는 존재하는 CR만 조정하므로 `Kafka` CR을 만들지 않으면 수기 StatefulSet을 건드리지 않는다.
- **전환 비용**: ADR-034 채택 시 파일 3개 삭제 + CR 1개 추가로 이전 가능하므로 지금 Deployment로 시작해도 손해가 없다.

### ADR-034 — Kafka 운영 모델: 수기 StatefulSet vs Strimzi Cluster Operator
**상태: `Open`**

- **배경**: 수기 StatefulSet에서 확인된 결함 — `KAFKA_LOG_DIRS` 미설정(PVC 미사용 → **재시작 시 데이터 유실**), `CLUSTER_ID` 없음, NetPol 9093 규칙 부재, PLAINTEXT 리스너, 토픽 생성 주체 없음, ACL 없음, ServiceAccount 부재.
- **Strimzi 도입 시**: `KafkaTopic` CR이 토픽 부트스트랩(G22)을, `KafkaUser` CR이 ACL(SEC-207)을, `Kafka` CR이 로그 디렉터리·리스너·quorum 설정을 해결한다.
- **트레이드오프**: ADR-003(Helm 미사용)의 정신과 긴장. 다만 ECK 선례가 있어 원칙 위반은 아니다. 현재 PVC에 데이터가 없으므로 마이그레이션 부담은 오히려 낮다.

### ADR-035 — Kafka 외부 노출 방식: HTTP Bridge vs 네이티브 외부 리스너
**상태: `Accepted`**

- **결정**: HTTP Bridge를 통해 노출한다.
- **회피하는 비용**: 브로커별 고유 외부 주소(3브로커 = LB/NodePort 3 + bootstrap 1), 파드별 `advertised.listeners`, 외부 리스너 TLS + SASL/SCRAM, 클라이언트의 Kafka 라이브러리 요구.
- **트레이드오프**: 처리량 낮음, 트랜잭션·정확히 한 번 미지원, 컨슈머 그룹 리밸런싱 제한적, 포맷 제한(`json`·`binary`).
- **적합**: 파트너사 연동, 서버리스·브라우저 클라이언트, 간헐적 이벤트 수집. **고처리량 스트리밍 소비에는 네이티브 리스너가 맞다.**
- **보안 전제**: Bridge의 HTTP API에는 자체 인증이 없으므로 반드시 인증 계층(oauth2-proxy + Keycloak) 뒤에 둔다(SEC-206).

---



### ADR-066 — FreeIPA를 아키텍처에서 완전 제거
**상태: `Accepted`**

- **배경**: FreeIPA는 ADR-022의 v1 복원 대상에 포함되어 있었다. 원래 의도는 **Keycloak에서 생성된 계정을 Knox·Ranger까지 연동**하는 것이었다.
- **결정**: **FreeIPA를 복원 대상에서 제외한다.** ADR-022의 복원 범위가 37 → **36 파드**로 줄어든다.
- **근거 ① 기능이 전부 중복이다.**

  | FreeIPA 구성요소 | 이 스택의 대체재 |
  |---|---|
  | 389-DS (LDAP) | **ds389** 독립 배포 — Knox `JndiLdapRealm`·Ranger `SYNC_LDAP_URL`이 실제로 참조하는 곳 |
  | MIT Kerberos KDC | **kerberos** 독립 컨테이너 |
  | Dogtag PKI (CA) | **cert-manager** (TODO-02) |
  | BIND (DNS) | **CoreDNS** |
  | 디렉터리 관리 UI | **LAM** · Keycloak 관리 콘솔 |
  | SSSD / HBAC | 이 스택에서 미사용 |

- **근거 ② 원래 목적은 다른 수단으로 달성된다.** 계정 연동의 빠진 조각은 "Keycloak에서 만든 계정이 DS389 `ou=users`에 나타나게 하는 것" 하나였고, 답은 **Keycloak LDAP User Federation (`Edit Mode: WRITABLE`, `Sync Registrations: ON`)** 이다. 이벤트 파이프라인(Kafka `keycloak-events` → Argo Events → Job)도, FreeIPA도 필요 없다. Knox는 로그인 시점 LDAP bind라 즉시, Ranger는 usersync 주기 내에 반영된다.
- **근거 ③ v1에서도 완성된 적이 없다.** `v1/argocd/argocd-kafka-sensor.yaml:43`의 동기화 Job 이미지가 `your-registry/sync-tools:latest` 플레이스홀더다.
- **근거 ④ Kubernetes와 전제가 충돌한다.** FreeIPA는 고정 FQDN·고정 IP·정/역방향 DNS·정확한 시각을 설치 시점에 요구하고 LDAP에 영구 기록한다. 파드에는 그 넷 중 무엇도 보장되지 않는다. WSL 로컬에서는 클럭 드리프트가 Kerberos 티켓(±5분)을 깨뜨린다.
- **효과**
  - governance 로컬 소요 **7.9 → 5.9 GB**, `local-governance` 프로파일 31.8 → **29.8 GB** (여유 8.9 → 10.9)
  - PSS `restricted` 예외 1건 감소 (TODO-13 목록 축소)
  - 로컬 빌드 이미지 **3종 → 2종** (`freeipa-systemd` 제거) — Oracle Ampere 부적합 근거도 그만큼 약화
  - `v1/freeipa/freeipa-configmap.yaml:5-6`의 평문 비밀번호 2건이 복원 경로에서 사라진다 (SEC-402 동류)
- **남기는 것**: `kerberos`는 제거하지 않는다. Hadoop 네이티브 CLI/RPC 접근 요구가 생기면 필요하다 — 별도 판단 사항이다.

### ADR-067 — API 계약 관리를 계약 우선(contract-first)으로
**상태: `Accepted`** (2026-09-01)

**결정** — `contracts/` 의 파일이 원천이고 구현이 거기에 맞춘다. 그 반대가 아니다.

**계약 표면** — 확인된 것은 둘뿐이다.

| 주체 | 성격 | 계약 |
|---|---|---|
| `cmmn-api` | **Spring Boot** REST (`SPRING_*`, `/actuator/health`) | OpenAPI. OpenAPI 엔드포인트를 노출하지 않는다(springdoc 미적용) |
| `cmmn-api` ↔ Kafka | 토픽 `dev.api.cmmn.menu` · `dev.api.cmmn.multilanguage` | AsyncAPI + Avro/JSON 스키마 |
| `admin` | **프론트엔드**(포트 3000, env 없음, `/` 프로브) | 없음. REST 계약 주체가 아니다 |

> **정정** — 이전 검토에서 두 앱을 Quarkus 라고 적었으나 틀렸다. 그때 본 `QUARKUS_*` 는
> Apicurio 자신의 환경변수였다. `cmmn-api` 는 Spring Boot 이고 `admin` 은 프론트엔드다.
> 결정 자체는 바뀌지 않는다 — 오히려 두 앱 모두 OpenAPI 문서를 내놓지 않으므로
> 코드 우선을 택했어도 추출할 것이 없었다.

**필수 귀결 — `auto.register.schemas` 를 껐다**

`cmmn-api` 는 이미 Apicurio 의 ccompat 엔드포인트를 가리키고 있었다.

```
SPRING_KAFKA_PROPERTIES_SCHEMA_REGISTRY_URL = http://apicurio-registry-headless:8080/apis/ccompat/v7
```

Confluent serdes 의 기본값은 `auto.register.schemas=true` 다. 그대로 두면 **앱이 처음
메시지를 보낼 때 스키마를 스스로 등록한다.** 그것은 코드 우선이며 이 결정과 정면으로
충돌한다. 매니페스트에서 껐다.

```
SPRING_KAFKA_PROPERTIES_AUTO_REGISTER_SCHEMAS = false
SPRING_KAFKA_PROPERTIES_USE_LATEST_VERSION    = true
```

이제 앱은 등록된 최신 스키마를 찾아 쓰고 **없으면 실패한다.** 계약이 먼저 있어야 한다는
뜻이고 그것이 의도다.

**기구**

| 층 | 무엇 | 어디 |
|---|---|---|
| 원천 | `contracts/{openapi,asyncapi,schemas}` | 이 레포 |
| 스타일 게이트 | Spectral 6.16.3 | CI `validate` (`spectral-lint`) |
| 구문·호환 게이트 | Apicurio 전역 규칙 `VALIDITY=FULL`·`COMPATIBILITY=BACKWARD` | 레지스트리 (ADR-021, §8-13) |
| 게시 | `contracts/` → Apicurio | CI `deploy` (`publish-contracts`) |

스키마는 ccompat(파일명 = subject), OpenAPI/AsyncAPI 는 Registry v3(파일명 = artifactId)로 올린다.

**아직 없는 것** — 실제 계약 파일이 0개다. 앱 소스가 이 레포에 없고(G9) 두 앱 모두 OpenAPI
문서를 내놓지 않으므로 **초기 계약은 손으로 작성해야 한다.** 그때까지 두 CI 잡은 대상이
없으면 통과하되 그 사실을 로그에 남긴다(아무것도 안 한 잡이 초록색으로만 남지 않도록).

**하지 않기로 한 것** — Swagger Editor(레지스트리와 연동 없음, 저장이 브라우저 로컬),
Swagger Parser(라이브러리이지 배포물이 아님). OpenAPI Generator 는 앱 레포 CI 소관이다.
Microcks 는 6단계로 미룬다(§8-13).

### ADR-064 — Spark 계층 도입 및 배포 방식
**상태: `Proposed`**

- **배경**: v2는 MinIO+Trino+Iceberg 레이크하우스이나 **배치 ETL 주체가 없다.** Trino는 인터랙티브 질의 엔진이며, MinIO에 데이터를 적재하거나 Iceberg 테이블을 유지보수(compaction·expire-snapshots)하는 담당이 부재했다.
- **결정**: Spark를 **native `spark-submit --master k8s://`** 로 도입한다. Spark Operator(`SparkApplication` CRD)는 채택하지 않는다.
- **근거**: 레포 원칙이 "No Helm — 수기 YAML + Kustomize"이고, **오퍼레이터 설치 경로 부재가 이미 P0 블로커**다(ECK·Kyverno·Gateway API·cert-manager·Argo Events·OTel·Trivy 7종). 8번째 오퍼레이터를 지금 추가하면 부담만 커진다. Job/CronJob은 Kustomize·sync wave와 자연스럽게 맞물린다.
- **재검토 조건**: Spark 잡이 10개를 넘거나 잡 간 의존 관계 표현이 필요해지면 Operator 전환.
- **부수**: 동적 생성되는 driver/executor 파드도 Kyverno 6정책을 만족해야 하므로 **pod template**(`spark-config` ConfigMap)으로 `securityContext`·`resources`·`priorityClassName`을 강제한다.
- **용량**: 상시 소요는 History 0.5 + Connect 1.5 + Livy 1.0 + oauth2-proxy 0.15 = **3.15 GiB**. driver/executor는 `PriorityClass: batch-low`로 **상시 용량 산정에서 제외**한다 (INFRA-604 동시 해소).

### ADR-065 — Livy와 Spark Connect 병행 채택
**상태: `Proposed`**

- **배경**: 원격 Spark 세션 진입점이 필요하다. 두 후보의 역할이 일부 겹친다.
- **결정**: **둘 다 배치한다.** 용도가 갈린다.

  | | Apache Livy | Spark Connect |
  |---|---|---|
  | 프로토콜 | REST/HTTP `:8998` | gRPC `:15002` |
  | 클라이언트 | curl · **Jupyter(sparkmagic)** · Zeppelin · 임의 언어 | `pyspark`/Scala/Go/Rust 얇은 클라이언트 |
  | 세션 모델 | **세션당 별도 driver 파드** (격리 강함, 메모리 큼) | **단일 서버가 다중 세션** (효율적, 격리 약함) |
  | 인증 | oauth2-proxy → Keycloak OIDC | Istio AuthorizationPolicy + mTLS |

- **Livy 상태 확인**: Attic 아님. **0.9.0-incubating**(2026-01) 최신, 0.10.0 준비 중. LIVY-702(K8s), LIVY-1010(Spark 3.5.6). 2017년부터 **ASF Incubator** 소속이라 산출물에 `-incubating` 접미사가 붙는다.
- **한계**: 두 경로 모두 **Ranger 인가를 우회한다**(G39). Ranger에 Spark 플러그인이 없다. 세밀한 테이블·컬럼 통제가 필요한 사용자는 Trino로 강제하고, Spark 경로는 MinIO 버킷 정책 수준까지만 보장한다.
- **통제**: Livy는 세션당 driver를 띄우므로 `livy.server.session.max-creation = 3`, `timeout = 1h`로 상한을 건다(G40).
## 매니페스트 · GitOps

### ADR-068 — 환경 분리는 브랜치가 아니라 Kustomize 오버레이로 한다
**상태: `Accepted`** (2026-09-03)

**결정** — `local`·`dev`·`prod` 는 오버레이로 나눈다. 브랜치는 **버전 축**(`main`=v1, `v2`)이지 환경 축이 아니다. `local` 브랜치는 환경 브랜치가 아니라 **v2 를 실배포로 검증하는 작업 라인**이며, 끝나면 `v2` 로 합치고 소멸한다.

**근거 — 측정값이 브랜치 분리를 반대한다.** `local` 이 `v2` 보다 앞선 116 커밋의 경로 분포:

| 커밋이 건드린 경로 | 건수 | 브랜치 분리 시 |
|---|--:|---|
| 로컬 전용만 (`overlays/local/`·`local/`) | 23 (20%) | 그 브랜치에만 남으면 된다 |
| **공유만** (`base/`·`docs/`·CI·`argocd/`) | **57 (49%)** | 매번 dev·prod 브랜치로 전파해야 한다 |
| **혼재** | **36 (31%)** | **자동 전파 불가** |

파일 기준으로도 462개 중 로컬 전용은 45개(약 10%)다. 환경 브랜치의 전제는 "브랜치 간 차이 = 환경 차이"인데 이 레포의 실측은 정반대다.

**혼재 커밋 36건이 결정적이다.** cherry-pick 하면 로컬 전제(`dfs.replication=1`·`tez.local.mode=true`)가 딸려가고, 안 하면 공유 수정(`hadoop-aws` 클래스패스·S3A 자격증명·capability·메모리)이 누락된다. "커밋을 환경별로 쪼개 올린다"는 규율로만 막히며, **도구가 보장하던 것을 사람에게 넘기는 것**이다. 오버레이는 구조로 보장한다 — §8-18 에서 dev/prod 렌더의 로컬 전용 워크로드 0개·로컬 전제 값 0개를 확인했다.

**기각 — `local` 을 `v3` 로 개명하는 안.** 기계적 비용은 0 에 가깝다(원격 미푸시, 문서 5줄). 그러나 ⓐ 커밋을 한 건도 dev/prod 로 옮기지 못하면서 ⓑ "다른 세대니 갈라져 있는 게 당연하다"는 명분을 주어 드리프트를 고착시킨다. 내용상으로도 v3 가 아니다 — `v1→v2` 는 교체(Hadoop→MinIO/Trino, raw YAML→Kustomize)였으나 `local` 의 116 커밋은 대부분 **v2 의 결함 수정과 미완 항목(G1~G41·TODO 47건) 충족**이다.

> **v3 를 정당하게 선언할 조건** — ADR-022(Hadoop/HBase/Hive 복원)를 dev/prod 에 채택하고 `overlays/local/lakehouse-local/` 을 base 로 승격할 때. 데이터 계층 구조가 실제로 달라지는 시점이다. 현재 그 결정(TODO-48·49)은 미결이다.

**prod 보호는 브랜치가 아니라 `targetRevision` 으로 한다.** 현재 dev·prod Application 이 **둘 다** `targetRevision: v2` + `automated{prune,selfHeal}` 이라 `.gitlab-ci.yml` 의 prod `when: manual` 게이트가 **무력하다** — v2 에 커밋되는 순간 prod 에 반영된다. prod 의 `targetRevision` 을 태그로 고정하면 승격이 명시적 행위가 되고, 브랜치 분리로 얻으려던 것(prod 가 dev 에 끌려가지 않음)을 드리프트 비용 없이 얻는다.

**머지 시점** — 7단계까지 모두 끝난 뒤 (2026-09-03 결정). 그때까지 `local` 은 유지한다.

| | |
|---|---|
| **비용** | 머지 지연만큼 공유 수정이 dev/prod 에 도달하지 않는다. 현재 미도달 93건 |
| **완화** | `local` 은 `v2` 대비 **0 뒤처짐**이라 fast-forward 가 유지된다. 누가 `v2` 에 커밋하면 이 성질이 깨지므로, 그때는 즉시 rebase 할 것 |
| **머지 시 파급** | dev 오버레이가 98 → 234 오브젝트(신규 136·삭제 0), **신규 워크로드 26종**. dev 는 auto-sync 라 즉시 반영된다 → **머지 전에 prod 태그 고정, dev `automated` 일시 해제, wave 순 분할 머지**가 전제다 |

**dev/prod 가 같은 클러스터를 쓴다**(`destination.server: https://kubernetes.default.svc`). 물리적으로 분리하게 되면 `destination.server` 가 갈라지는 것이지, 그때도 브랜치가 갈라질 이유는 아니다.

### ADR-003 — Helm 미사용, 수기 YAML + Kustomize
**상태: `Accepted`**

- **결과**: 완전한 투명성, 차트 드리프트 없음. 대가로 업스트림 운영 지식(bitnami·Strimzi·ECK 차트 로직)을 직접 재구현해야 하며, **DB 부트스트랩 부재·ServiceAccount 누락·Kafka PVC 미사용이 그 대가로 드러났다.**
- **예외**: Sentry 채택 시 커뮤니티 Helm 차트를 허용한다(ADR-036 ⓑ). 예외 기준 — 수기 작성 시 유지보수 부담이 얻는 것을 명백히 초과하는 경우.

### ADR-004 — Kustomize base + overlay 구조
**상태: `Accepted`** — `kubectl kustomize`로 dev/prod 빌드 성공 확인 (dev 5,427줄 / prod 5,569줄).

### ADR-005 — ArgoCD GitOps + sync wave 의존 순서
**상태: `Accepted`**

- **결정**: 카테고리 `commonAnnotations`로 wave 0~8, `automated{prune,selfHeal}`, `PruneLast`, `RespectIgnoreDifferences`, retry backoff.
- **결과**: 환경당 Application 1개라 폭발 반경이 하나이고, **클러스터 범위 ClusterPolicy를 dev/prod가 공동 소유해 충돌한다**(G25). AppProject 화이트리스트 누락으로 `service-mesh/` 전체가 sync 거부된다(G17).

### ADR-006 — prod 배포 승인 모델
**상태: `Open`**

- **배경**: CI `deploy-prod`는 `when: manual`이나 **ArgoCD prod Application이 `automated{prune,selfHeal}`** 이라 `v2` 머지 시 CI와 무관하게 자동 적용된다. `rotation-git-sync`가 리뷰 없이 `v2`에 push 한다(G26).
- **선택지**: ⓐ prod Application의 auto-sync 제거 ⓑ prod 브랜치 분리 ⓒ 문서를 현실에 맞게 수정.

### ADR-054 — Kustomize Component 기반 프로파일 구조
**상태: `Proposed`**

- **배경**: `base/kustomization.yaml`이 10개 카테고리를 무조건 포함해 부분 배포가 불가능하다. 64 GB 로컬 호스트에서 전체 스택(93 GB)을 올릴 수 없다.
- **결정**: `kubernetes/components/` 8종(core·observability·security-min·security-full·lakehouse-v1·governance·devops·apm) + `overlays/local-*` 5종. dev/prod는 전 컴포넌트를 포함해 구조를 통일한다.
- **하드웨어 사다리** (전 구성요소 동시 배포 기준):

  | 조치 | 소요 | 필요 호스트 |
  |---|--:|---|
  | 설계 그대로 (HA) | ~170 GB | 256 GB |
  | 레플리카 전부 1 | ~120 GB | 192 GB |
  | + JVM 힙 설정 + GlitchTip | **~93 GB** | **128 GB (권장)** |
  | + 프로파일 분할 | ~40 GB | 64 GB |

- **부수 효과**: 컴포넌트 경계를 그으려면 의존 관계를 확정해야 하므로 **G22·G18·G13이 강제로 해소된다.**
- **한계**: Kustomize에 의존성 자동 해석이 없어 문서 + CI로 강제해야 한다.

### ADR-062 — sync-wave를 카테고리 → 서비스 단위로 이동
**상태: `Proposed`** — 컴포넌트 경계가 카테고리와 다르다. `governance` 내부의 DS389(3) → Solr(5) → Ranger(6) → Knox(7) 순서를 표현할 수 있게 되어 오히려 정밀해진다.

### ADR-063 — `commonLabels` → `labels:` 전환
**상태: `Proposed`** — kustomize v5.8에서 deprecated. 빌드 시 경고 8건 발생 중.

---

## IaC

### ADR-011 — count 기반 멀티 프로바이더 추상화
**상태: `Superseded` (→ ADR-019)**

- **결정(당시)**: `modules/{compute,network,dns,storage}/main.tf`가 `count = var.provider_name == ... ? 1 : 0`으로 hetzner/vultr 서브모듈에 분기.
- **폐기 사유**: **두 구현이 침묵 속에 어긋났다.** Hetzner 경로에 bastion·master·VPC 연결·방화벽 부착이 없고(G5), `bastion_ip` 출력이 worker[0]을 반환하며, 방화벽이 어떤 서버에도 부착되지 않는다(G28). 보안 태세도 프로바이더별로 달랐다(Vultr deny-all vs Hetzner `0.0.0.0/0` 개방). 비활성 프로바이더도 더미 토큰으로 초기화해야 했다.
- **교훈**: **추상화를 유지한다고 프로바이더 이동이 쉬워지지 않는다.** 이동 시점에 모듈을 새로 쓰는 것이 쓰지 않는 분기를 계속 이고 가는 것보다 저렴하다.
- **보완 조항**: 근본적으로 다른 기반(Hyper-V)은 **별도 루트 모듈**로 추가한다(ADR-052).

### ADR-019 — Vultr 단일 프로바이더 확정 및 IaC 평탄화
**상태: `Proposed`**

- **결정**: Hetzner 11개 파일 삭제, `modules/*/vultr/` 하위를 모듈 루트로 승격. `provider_name` 변수·`count` 분기·`module.vultr[0]` 인덱싱·더미 기본값 제거. `modules/bastion/`(죽은 코드) 삭제. tf 파일 **42 → 19**.
- **부수 해소**: G4·G5·G28·SEC-601·SEC-602·리전 매핑 누락(storage 모듈이 `kor`을 매핑 없이 전달).
- **고려한 대안 — 비용 정량 비교** (prod 6노드, 2026-08 추정):

  | 프로바이더 | 월 | 연 |
  |---|--:|--:|
  | Hetzner EU | ~$727 | ~$8,700 |
  | Hetzner SG | ~$1,251 | ~$15,000 |
  | OVH SG (12개월 약정) | ~$1,733 | ~$20,800 |
  | **Vultr (채택)** | ~$2,526 | ~$30,300 |

  **Vultr는 Hetzner SG 대비 연 약 $15,300 비싸다.** 다만 현 레포의 Hetzner 구현이 사실상 없는 상태라 "저렴함"의 대가로 IaC를 새로 써야 했다. OVH는 OpenStack 기반이라 IaC 전면 재작성이 필요하고 2026-10-01 언번들 과금 전환으로 가격 우위가 축소되었다(b3-64 €299 → €343). Oracle Cloud Ampere(ARM)는 로컬 빌드 이미지 3종과 Hadoop/HBase/Ranger/Knox/ClickHouse/Wazuh의 arm64 검증 부담으로 부적합.
- **재검토 조건**: 비용이 지배적 요인이 되면 Hetzner SG를 재검토한다. 단 Hetzner IaC를 처음부터 제대로(bastion + VPC + 방화벽 부착) 작성하는 작업이 전제다.

### ADR-051 — 로컬 개발 타깃으로 Hyper-V + k3s 도입
**상태: `Proposed`**

- **배경**: v1은 `kind` 기반 로컬 환경을 가졌으나 v2는 로컬 타깃이 없다.
- **결정**: Hyper-V VM 위에 k3s를 구성한다. **k3s 플래그를 클라우드와 동일하게 유지**해야 Cilium 관련 문제를 로컬에서 재현할 수 있다.
- **대안**: kind / minikube / k3d / WSL2 단일 노드.
- **결과**: 다중 노드·실제 CNI·실제 스토리지로 충실도 상승. **Cilium+Istio 공존 설정(M1)을 클라우드 재구축 전에 선검증할 수 있다.** dev 클러스터를 대체하면 **−$1,400/월**. 제약은 H1~H6.

### ADR-052 — IaC를 Vultr/Hyper-V로 통합하지 않고 루트 모듈 분리
**상태: `Proposed`**

- **근거**: Hyper-V에는 VPC·방화벽 그룹·DNS 존·블록스토리지 서비스 API가 **없다.** Hetzner↔Vultr(리소스 모델이 거의 동일)와 달리 애초에 대응되지 않는 개념이 다수다. ADR-011의 실패를 반복하지 않는다.
- **명문화**: **이식성의 실제 경계는 IaC가 아니라 Kubernetes 계층이다.** Kustomize + ArgoCD는 이미 완전히 기반 무관하며 그것이 실제로 작동하는 부분이다.

### ADR-053 — Hyper-V 프로비저닝 방식
**상태: `Open`**

- **선택지**: ⓐ `taliesins/hyperv` 프로바이더(선언적, WinRM 설정 선행, **유지보수 활성도 확인 필요 `[UNVERIFIED]`**) ⓑ `null_resource` + `local-exec` PowerShell(프로바이더 의존 없음, Microsoft 공식 cmdlet, 상태 추적·drift 감지 약함).
- **VM 이미지**: cloud-init seed ISO는 Windows에서 별도 도구(`oscdimg`)를 요구하므로 **골든 VHDX 템플릿 복제 방식**을 채택한다.

---

## 네트워크 · 서비스메시

### ADR-009 — Istio Ambient 모드 채택 (사이드카 대비)
**상태: `Accepted (조건부)`**

- **조건**: ① M1~M3 설정 준수 ② ambient 우회 검증(SEC-108) 통과 ③ mTLS STRICT 전환.
- **현재**: dev에서 ztunnel HBONE 문제로 **비활성**(커밋 `33e1c94`), `PeerAuthentication`은 PERMISSIVE, AppProject가 Istio CR을 sync하지 못하며, SA 부재로 principal이 매칭되지 않는다 — **메시가 현재 아무 강제도 제공하지 않는다.**

### ADR-010 — WireGuard bastion 기반 제로트러스트 엣지
**상태: `Accepted`**

- **결정**: `network/vultr/main.tf` — bastion 22/51820만 공개, k3s 노드는 빈 방화벽 그룹(deny-all). 프로비저닝 전 과정을 bastion 경유. `--flannel-backend wireguard-native`.
- **결과**: 공격 표면 최소화. 대가로 **외부 진입점 부재**(TODO-01)와 단일 하드코딩 WireGuard 피어.
- **갱신**: ADR-019로 Hetzner가 제거되어 "Vultr 경로 한정" 단서가 삭제되고 무조건 적용된다.

### ADR-023 — CNI를 flannel → Cilium 교체 및 Hubble 도입
**상태: `Proposed`**

- **범위**: **서비스 메시 대체가 아니라 CNI + 네트워크 정책 + 관측성.** mTLS·L7 인가는 Istio가 담당한다(ADR-009와 병행).
- **전제**: `--flannel-backend=none --disable-network-policy`가 **k3s 설치 시점에만 지정 가능한 플래그**이므로 **노드 재설치가 필요하다.**
- **얻는 것**: 메시 미가입 워크로드(DaemonSet·오퍼레이터·kube-system)까지 통제, FQDN egress 제어, Hubble 플로우 가시성.

### ADR-028 — OPNsense 경계 방화벽 도입 및 Suricata/Zeek 배치
**상태: `Open`**

- **배치**: L0(OPNsense) 전용. **DaemonSet으로 두지 않는다** — 노드당 3.5 GB 비용이 붙고 동-서 가시성은 Cilium/Hubble이 제공한다(ADR-055).
- **실현성 `[UNVERIFIED]`**: Vultr의 커스텀 ISO 지원 여부, VPC 커스텀 라우트 노출 여부. 불가 시 대안 — OPNsense를 bastion 대체(VPN 종단 + 남-북 방화벽)로만 쓰고 동-서는 Cilium에 위임.

### ADR-029 — SafeLine WAF 도입 및 진입점 체인
**상태: `Proposed`**

- **체인**: OPNsense → SafeLine WAF → ingress-nginx(TLS 종단) → oauth2-proxy(OIDC) → 서비스.
- **필수 이유**: **Kafka Bridge에 자체 인증이 없어** 인증을 앞단이 강제해야 한다(SEC-206). 외부 노출 경로에 레이트리밋·페이로드 상한도 필요하다 — v1 ingress는 `proxy-body-size: 1024m`으로 과도했다.

### ADR-043 — Cilium + Istio Ambient 공존 설정 규약
**상태: `Proposed`**

- **필수 설정**: M1 `socketLB.hostNamespaceOnly=true` · M2 `cni.exclusive=false` · M3 `istio-cni` DaemonSet.
- **위험**: **M1의 실패 모드는 "조용한 보안 우회"다.** 설정이 틀려도 에러 없이 통신은 정상 동작하고 mTLS·AuthorizationPolicy만 적용되지 않는다. 인지가 불가능하다.
- **완화**: ztunnel HBONE 연결 수를 확인하는 검증 항목을 신설하고 **배포 게이트로 삼는다**(SEC-108).

### ADR-044 — 암호화 계층 역할 분리
**상태: `Proposed`**

- **결정**: Cilium WireGuard는 **메시 미가입 트래픽**(kube-system·DaemonSet·오퍼레이터·컨트롤플레인), Istio mTLS는 메시 내부 워크로드 ID.
- **대안**: ⓑ Cilium 암호화 비활성(Falco·Filebeat가 평문 전송 — 부적절) ⓒ Istio mTLS 비활성(병행 의미 상실).
- **결과**: 메시 트래픽 일부에 이중 암호화가 남으나 Cilium WireGuard는 커널 레벨이라 오버헤드가 낮다. 실측 후 조정한다.

### ADR-045 — 네트워크 정책 작성 계층 규약
**상태: `Proposed`**

- **결정**: 기본 격리·FQDN egress·메시 미가입 워크로드는 **CiliumNetworkPolicy**, 워크로드 ID 기반 인가·L7 HTTP는 **Istio AuthorizationPolicy**. 기존 K8s NetworkPolicy 14개는 유지(Cilium이 해석)하고 점진 이관.
- **드롭 원인 추적 절차**: ① `hubble observe --verdict DROPPED` → ② ztunnel/waypoint 로그 → ③ `istioctl analyze`.

---

## 보안

### ADR-007 — 어드미션 제어로 Kyverno 채택 (OPA Gatekeeper 대비)
**상태: `Accepted`** — YAML 네이티브, 학습 곡선 낮음, Cosign 검증 내장. 다만 **`verifyImages` 정책이 작성되지 않았고**(G10) 시스템 네임스페이스 예외가 없다(G24).

### ADR-008 — 런타임 탐지로 Falco 채택
**상태: `Accepted`** — CNCF Graduated, Falcosidekick의 ES 연동 기본 지원. ADR-025 결과에 따라 Superseded 가능.

### ADR-016 — 공급망 강제: 사설 레지스트리 + 서명 검증
**상태: `Open`**

- **배경**: CI가 이미지를 미러링·서명하지만 **어떤 매니페스트도 `registry.oneinchmarket.co.kr`을 참조하지 않고 `imagePullSecrets`도 없으며 `verifyImages` 정책도 없다.**
- **선택지**: ⓐ 오버레이 `images[].newName`으로 레지스트리 재작성 + `restrict-image-registries` + `verify-image-signature` ⓑ 업스트림 pull 유지하고 Cosign 폐기 ⓒ ArgoCD Image Updater + 다이제스트 핀닝.
- **트레이드오프**: ⓐ는 GitLab(wave 8)이 모든 이미지 pull의 하드 의존이 되어 ADR-005와 부트스트랩 순환을 만든다.

### ADR-020 — Jenkins → GitLab CI 통합
**상태: `Proposed`** — 계획서 전환표에 Jenkins 언급이 아예 없어 암묵적으로 제거되었던 결정을 명문화한다. ADR-022로 Jenkins가 복원되면 **역할 분담 정의가 필요하다**(TODO-40).

### ADR-021 — Apicurio Studio 제외 및 Registry 단독 운영
**상태: `Accepted`** (2026-09-01) — **upstream 이 대신 결론냈다.**

- **Apicurio Studio 는 완전 폐기(deprecated)되었다.** `apicur.io/studio` 공지:
  *"Apicurio Studio is now fully deprecated. Studio functionality has been integrated
  into Apicurio Registry 3.1.0 as an opt-in feature."*
  저장소도 `ApicurioArchive/apicurio-studio` 로 옮겨졌다.
- 즉 v1 의 5종(registry + registry-ui + studio-api/ui/ws) 중 studio 3종은 **더 이상 존재하지 않는다.**
- **TODO-39(이미지 pull 가능 여부 `[UNVERIFIED]`)는 이것으로 해소된다.**
  Docker Hub `apicurio/apicurio-studio` 에는 `1.0.0.Beta1`·`latest-snapshot` 만 있고
  GA 태그가 없다. 채택 가능한 상태가 아니다.

**결정 — registry + registry-ui 2종 운영.**

- `registry-ui` 는 **제외 대상이 아니었다.** v2 로 오면서 누락된 것이며(3.x 는 UI 가 별도 이미지),
  그 결과 레지스트리를 REST 로만 볼 수 있었다. 2026-09-01 에 `apicurio-registry-ui:3.3.2` 를 배포했다.
- 편집 기능은 Registry 의 opt-in 스위치로 켠다:
  `apicurio.rest.mutability.artifact-version-content.enabled=true`
  (env `APICURIO_REST_MUTABILITY_ARTIFACT_VERSION_CONTENT_ENABLED`)
  → 콘솔에 Drafts 섹션과 버전 콘텐츠 편집이 나타난다. **실증 완료**(DRAFT 등록 → 내용 수정 204 → 반영 확인).
- **따라서 별도 편집기(Swagger Editor 등)를 두지 않는다.** 레지스트리와 연동되지 않는 편집기는
  저장 위치가 브라우저 로컬이라 계약 관리의 원천이 되지 못한다.

**Apitomy 와의 관계** — Apicurio 의 후계자가 아니다. 라이브러리·코드생성 조각
(Data Models · Codegen · Apicurito)이 옮겨간 곳이며, Registry 는 Apicurio 에 남아
CNCF Sandbox 로 계속 유지된다(3.3.2, 2026-08-27). **Registry 는 대체 대상이 아니다.**


### ADR-024 — 시크릿 관리를 SOPS+age → Vault 전환
**상태: `Open`**

- **배경**: SOPS+age 설계는 **전혀 작동하지 않는다.** `.sops.yaml`이 플레이스홀더 키, `*.enc.yaml` 12개가 평문/가짜 암호문, 전부 kustomization에서 주석 처리되어 **Secret 0개 렌더**.
- **Vault 채택 시 소멸하는 문제**: G19(키 이름 불일치 4건)·G20(잘못된 대상)·G21(출력 경로 부재)·G30(RBAC 과다)·SEC-403·SEC-409·SEC-410. CronJob 8종 + git-sync + `.enc.yaml` 12개 제거.
- **대안**: SOPS 배선 복구 / SealedSecrets / External Secrets Operator.
- **비용**: Vault 파드 3(로컬 dev 1), unseal 운영 절차, Kubernetes auth 설정.

### ADR-025 — 런타임 보안: Tetragon vs Falco
**상태: `Open`**

- **Tetragon**: 탐지 **+ 차단**, Cilium과 동일 벤더·동일 eBPF 기반으로 정합성 우위, 드리프트 방지(exec 정책) 부분 대응 가능.
- **Falco**: 이미 구현됨, CNCF Graduated, Falcosidekick 라우팅 완비.
- **미지정 시 가정**: Tetragon.

### ADR-030 — MITRE Caldera 운영 범위 및 훈련 창 절차
**상태: `Proposed`**

- **제약**: **dev/local 전용, prod 배포 금지** — Sandcat 에이전트는 기능상 원격 제어 에이전트다. 전용 네임스페이스 + CiliumNetworkPolicy 격리, 기본 상태 에이전트 미배포.
- **훈련 창**: 실행 시간대를 Wazuh/Tetragon 알림 규칙에 등록해 훈련/실사고를 구분한다. 실행 승인 절차와 결과 리포트를 `scripts/security-verification/`에 편입한다.
- **효과**: Caldera가 위험 요소가 아니라 **탐지 스택의 유효성을 실증하는 검증 도구**로 기능한다.

### ADR-046 — Aqua Platform 기능의 OSS 구성
**상태: `Proposed`**

- **결정**: Trivy(+Operator)·Kubescape·Kyverno·Cosign·Syft·Dependency-Track·DefectDojo·Policy Reporter·Gitleaks·Checkov·Tetragon·Cilium·Wazuh·Caldera 조합.
- **대체 불가 3영역 (명시)**: ① **Dynamic Threat Analysis**(샌드박스 폭파) — OSS 동등물 없음 ② **드리프트 방지** — 빌드 시점 바이너리 목록 기반 강제는 근사만 가능 ③ **CSPM** — Prowler/ScoutSuite가 Vultr를 지원하지 않아 Checkov IaC 사전검사로 부분 대체.
- **용도**: 상용 제품 재검토 시 판단 근거.

### ADR-047 — Trivy CronJob → Trivy Operator 전환
**상태: `Proposed`** — 현행 CronJob은 `aquasec/trivy` 이미지 안에서 `kubectl`을 실행하는데 이미지에 kubectl이 없고, `--cacert`를 쓰면서 인증서 볼륨을 마운트하지 않아 **동작 불가**다. Operator는 `VulnerabilityReport`·`ConfigAuditReport`·`ExposedSecretReport`·`RbacAssessmentReport` CR을 생성해 Kyverno 연동(SEC-013)의 기반이 된다.

### ADR-048 — 취약점 관리 단일 조회 지점
**상태: `Proposed`** — DefectDojo(CI 결과 중복 제거·트리아지·SLA) + Policy Reporter(PolicyReport CR 대시보드). 현재는 결과가 CI 로그·ES·Kyverno CR에 흩어져 있다.

### ADR-049 — Harbor 미도입, GitLab Registry 유지
**상태: `Proposed`**

- **근거**: GitLab Registry가 이미 있다. Harbor 추가는 레지스트리 2개 + 파드 8개 + 약 8 GB. 동등 효과를 다른 경로로 얻는다 — 스캔은 Trivy(CI) + Trivy Operator(클러스터), 서명 검증은 Kyverno `verifyImages`(**풀 시점이 아니라 배포 시점 검증 — 실질적으로 더 강력**), 보존은 GitLab Registry 정리 정책.
- **재검토 조건**: 레지스트리 계층에서의 차단이 명시적 요구사항이 될 때.

### ADR-050 — SBOM 생성·보관 정책
**상태: `Proposed`** — Syft(CycloneDX) → Dependency-Track. 신규 CVE 공개 시 **이미 배포된 이미지에 소급 알림**(SEC-505)이 핵심 가치다.

---

## 관측성

### ADR-026 — 관측성 · 보안 관제 도메인 분리 (ELK ∥ Wazuh)
**상태: `Accepted`** (사용자 결정)

- **결정**: Elasticsearch(ECK)는 **운영 관측성**, Wazuh Indexer는 **보안 관제**로 저장소를 분리한다. ECK를 제거하지 않는다.
- **근거**: 운영 관측과 보안 관제는 데이터 수명주기·조회 주체·규제 요건이 다르다.
- **트레이드오프**: 검색 클러스터 2개 운영 부담(약 52 Gi)을 수용한다.

### ADR-027 — Loki · Elasticsearch 보존기간 기반 역할 분리
**상태: `Proposed`** — Loki는 컨테이너 stdout 7~14일(Grafana 메트릭↔로그 상관), ES는 장기 보존·전문 검색(ILM 기존 설정 유지). 입력 경로는 Promtail이 아니라 **OTel Collector**로 통합한다.

### ADR-031 — Logstash를 보안 이벤트 정규화 계층으로 재배치
**상태: `Proposed`**

- **배경**: 현재 Logstash는 `beats:5044`만 열고 Filebeat가 ES로 직결해 **아무것도 처리하지 않는다**(G11).
- **결정**: Tetragon·Suricata·Zeek·Wazuh Agent·K8s Audit·Kubescape의 이질적 포맷을 Wazuh 스키마로 변환해 Indexer에 적재한다. Falcosidekick이 이미 Kafka `falco-alerts`로 전송하므로 기존 설정을 활용한다.
- **`[UNVERIFIED]`**: Logstash `opensearch` output 플러그인의 Wazuh Indexer 호환. 대안은 Wazuh Manager syslog 수집기 경유.

### ADR-036 — 애플리케이션 오류 추적 도입 및 배포 방식
**상태: `Open`**

- **선택지**: ⓐ 수기 YAML 22종(유지보수 부담 과다) ⓑ **커뮤니티 Helm 차트**(ADR-003 예외 필요) ⓒ SaaS(자체 호스팅·데이터 경계 방침과 배치) ⓓ **GlitchTip**(Sentry SDK 완전 호환, Django + PostgreSQL + Redis만 필요, ClickHouse·Kafka·Snuba 불필요, 3~4 파드).
- **권고**: 대상 애플리케이션이 2개뿐이고 **OTel 채택으로 백엔드 잠김이 사라졌으므로 ⓓ**. 22 파드/28 Gi → 3~4 파드/4 Gi, 클라우드 비용 −$384/월, 로컬 배포 가능성 16 GB 차이.
- **Sentry가 필요한 경우**: APM·프로파일링·세션 리플레이·대규모 이슈 워크플로가 요구사항일 때. 이 경우 ⓑ.
- **전제 조건**: 애플리케이션 SDK 계측 — G9(Dockerfile 부재)로 빌드 불가하나 **ADR-042의 자동 계측이 이를 우회한다.**

### ADR-037 — Sentry Snuba용 ClickHouse 도입
**상태: `Open`** — Snuba가 ClickHouse 스키마에 강결합되어 **Trino/Iceberg로 대체 불가**하다. ADR-036 ⓓ 채택 시 불필요.

### ADR-038 — Sentry 전용 Kafka · Redis 인스턴스 분리
**상태: `Open`** — Sentry는 자체 토픽을 다수 생성하고 특정 버전에 결합된다. **레이크하우스 Kafka와 공유하면 v2의 핵심 데이터 경로가 Sentry 이벤트 폭주에 영향받는다.** ADR-036 ⓓ 채택 시 불필요.

### ADR-039 — OpenTelemetry를 텔레메트리 수집 표준으로 채택
**상태: `Proposed`**

- **결정**: 애플리케이션은 OTLP로만 계측하고 백엔드 라우팅은 Collector 설정으로 관리한다.
- **대안**: 백엔드별 전용 에이전트 유지 / 벤더 SDK 직접 사용.
- **결과**: **백엔드 교체 비용이 소멸**한다. 대신 Collector가 새로운 단일 장애점이 되므로 Gateway 다중화가 필수다.
- **경계**: 보안 관제(Wazuh) 경로는 OTel을 경유하지 않는다 — 유실·지연이 허용되지 않고 샘플링 대상이 아니다.

### ADR-040 — Collector 2계층 구조 및 테일 샘플링 배치
**상태: `Proposed`** — Agent(DaemonSet, `loadbalancing` exporter로 trace_id 기준 라우팅) + Gateway(Deployment ×3, `tail_sampling`·`redaction`). **테일 샘플링은 한 트레이스의 모든 스팬이 같은 인스턴스에 모여야 하므로 Gateway에만 둘 수 있다.** Gateway에서 PII·자격증명 스크러빙을 강제한다.

### ADR-041 — 트레이스 백엔드 역할 분리: Jaeger ∥ Tempo
**상태: `Proposed`**

- **결정**: Jaeger + Elasticsearch는 단기(3~7일) 개발자 디버깅·서비스 의존성 그래프, Tempo + MinIO는 장기(30일+) Grafana 상관분석·TraceQL. Collector가 동일 트레이스를 양쪽에 fan-out.
- **대안**: ⓐ Tempo 단독(가장 저렴, MinIO 재사용, 의존성 그래프는 Grafana Service Graph로 대체) ⓒ 둘 다 장기 보존(비권장).

### ADR-042 — OTel Operator 도입 및 자동 계측
**상태: `Proposed`**

- **핵심 근거**: `instrumentation.opentelemetry.io/inject-{java,nodejs}` 어노테이션으로 **코드 변경 없이 계측**된다. `.gitlab-ci.yml`이 참조하는 Dockerfile이 존재하지 않아 이미지 빌드가 불가능한 상태(G9)에서도 트레이스 수집을 시작할 수 있다.
- **ADR-033과의 차이**: Strimzi에서는 "파드 1개에 CRD 10종은 과하다"고 판단했으나, 여기서는 **자동 계측이라는 대체 불가능한 기능**을 제공하므로 도입 근거가 명확하다.

---

## 운영 · 사이징

### ADR-012 — 외부 진입점 및 TLS 전략
**상태: `Open`**

- **배경**: Ingress/Gateway/LB/NodePort 객체가 하나도 없고 traefik·servicelb가 비활성이며 DNS는 사설 IP를 가리킨다. **v1에는 ingress-nginx + Ingress 5종 + cert-manager가 있었다** — 이관 누락에 가깝다.
- **선택지**: ⓐ VPN 전용 유지 ⓑ ingress-nginx + cert-manager + 공용 LB(v1 설정 재활용) ⓒ Istio ingress gateway(waypoint용으로 이미 도입한 Gateway API 재사용).
- **트레이드오프**: ⓐ는 ADR-010의 제로트러스트 엣지를 보존하나 Trino·Kibana·GitLab의 외부 소비자를 차단한다.

### ADR-013 — 상태 저장 데이터 서비스 HA 모델
**상태: `Open`** — prod가 replicas만 올리고 복제 토폴로지가 없으며 PDB는 실제 HA를 전제한다. 선택지: 오퍼레이터(CloudNativePG·Percona·Redis Sentinel/Cluster) / 단일 인스턴스 + 엄격한 백업 / 관리형 DB(프로바이더 이식성 상실).

### ADR-014 — 비밀번호 로테이션: CronJob + Reloader + git write-back
**상태: `Superseded` (ADR-024 채택 시)** — 설계 순서 자체는 타당하나(서비스 먼저 → Secret → 재시작), 키 이름 4건 불일치·잘못된 대상·출력 경로 부재로 동작하지 않는다. git write-back은 시크릿을 VCS에 재도입하며 `selfHeal`과 경합한다.

### ADR-015 — StorageClass 및 볼륨 프로비저닝
**상태: `Open`**

- **배경**: 전 PVC가 존재하지 않는 `standard`를 참조한다. k3s 기본은 `local-path`. 블록 스토리지 모듈은 빈 ID 리스트로 호출된다.
- **선택지**: ⓐ k3s `local-path`(무료·빠름, **StatefulSet이 노드 고정되어 ADR-013의 HA가 무의미해짐**) ⓑ 프로바이더 CSI 블록 볼륨(약 $225/월, 이동성 확보) ⓒ Longhorn/OpenEBS(복제 계층 추가, 상당한 오버헤드).
- **비용 결정이기도 하다.**

### ADR-018 — 백업 · 복원 · 재해복구
**상태: `Open`** — 현재 전무하다. 선택지: Velero + CSI 스냅샷 / 서비스별 논리 덤프 CronJob → MinIO / MinIO 사이트 복제 / 원격 S3 tfstate 백엔드. **MinIO를 백업 대상으로 쓰는 것은 순환**이다(레이크하우스 주 저장소이기도 하다).

### ADR-055 — 로컬 DaemonSet 제외 정책 및 Suricata/Zeek 배치 정정
**상태: `Proposed`**

- **정정**: 초기 산정에서 Suricata·Zeek를 L0(OPNsense)에 배치해놓고 DaemonSet으로도 계산해 **이중 계상**했다. 클라우드에서도 **OPNsense 전용**이며 DaemonSet이 아니다.
- **효과**: 노드당 DaemonSet 6.3 GB → 2.6 GB, 총 소요 329 → 303 Gi, **7노드 → 6노드**.
- **로컬 추가 제외**: Kubescape node-agent·Wazuh agent·Filebeat → 노드당 1.6 GB.

### ADR-056 — 레플리카 축소 정책 및 검증 손실 명시
**상태: `Proposed`**

- **절감**: HA → 전부 1로 축소 시 약 65 GB (184 → 120 GB).
- **잃는 검증**: HA 페일오버 / Kafka KRaft quorum(**G23의 9093 NetPol 누락을 로컬에서 재현할 수 없다**) / ZooKeeper quorum / Hadoop NameNode HA / ES 샤드 복제.
- **⚠️ PDB 정합성**: `redis-pdb minAvailable: 4`인데 replicas가 1이면 **모든 축출이 차단되어 노드 드레인이 불가능해진다.** 축소 오버레이에서는 PDB를 제거하거나 `minAvailable`을 함께 낮춘다.

### ADR-057 — JVM 힙 명시 설정 규약
**상태: `Proposed`** — 현재 모든 Java 워크로드가 기본값(컨테이너 limit의 50%)에 의존해 예측이 불가능하다. ES `-Xms1500m -Xmx1500m`, Kafka `-Xmx768m`, Trino `-Xmx1500m` 등 서비스별 힙을 고정한다. 약 12 GB 절감 → **노드 1대 절감(−$384/월)**.

### ADR-058 — 실측 기반 리소스 산정 (KRR/VPA)
**상태: `Proposed`**

- **배경**: 현재 모든 수치가 추정이다. v1 매니페스트에는 리소스 정의가 없고(계획서 §2 이슈 #5), 신규 스택은 프로젝트 기본값을 사용했다. 계획서 자체 수치로도 requests 46.3 GB vs limits 102.7 GB로 **2.2배 격차**다.
- **도구**: **KRR**(Prometheus 기반, 컨트롤러 불필요 — Prometheus가 이미 설계에 있어 추가 비용 0) 또는 VPA recommendation 모드 + Goldilocks.
- **절차**: 배포 후 **최소 2주 관측 → 재산정.** 이 단계 없이 여유율 90%를 적용하면 위험하다 — 메모리는 throttle이 아니라 OOMKill이다.

### ADR-059 — 빈 패킹 스케줄러 및 Descheduler 도입
**상태: `Proposed`** — k3s 기본은 `LeastAllocated`(분산). `NodeResourcesFit.scoringStrategy: MostAllocated`로 조밀 배치하고 Descheduler `HighNodeUtilization`으로 저사용 노드를 비운다. **`--kube-scheduler-arg=config=<path>`는 부트스트랩 시점에만 적용 가능**하므로 Cilium 재설치와 함께 반영한다. 위험: 장애 반경 확대, PDB와의 충돌.

### ADR-060 — PriorityClass 체계
**상태: `Proposed`** — `platform-critical` / `stateful` / `stateless` / `batch-low` 4단계. 로테이션 CronJob·Trivy·Kubescape·Caldera·부트스트랩 Job을 `batch-low`로 두어 **상시 용량 산정에서 제외**한다. 부수 효과로 야간 Job이 자원을 못 잡고 조용히 실패하는 문제도 방지된다.

### ADR-061 — anti-affinity 적용 범위
**상태: `Proposed`** — 상태 저장 HA 서비스에만 적용한다. 무상태 워크로드에 걸면 빈 패킹 효율이 떨어진다. **현재 anti-affinity 규칙이 아예 없으므로 정의 작업이 선행되어야 한다.** 노드 수 하한을 만든다 — ES×3·Kafka×3·Wazuh Indexer×3·MongoDB×3 + N+1 = **최소 4노드**.

---

## 결정 요약

### 즉시 결정이 필요한 항목

| ADR | 항목 | 미지정 시 가정 |
|---|---|---|
| **025** | 런타임 보안: Tetragon vs Falco | Tetragon |
| **024** | 시크릿 관리: Vault vs SOPS+age | Vault |
| **036** | APM 배포: Sentry(Helm) vs GlitchTip | Sentry Helm — **GlitchTip 재검토 권고** |
| **053** | Hyper-V 프로비저닝 방식 | `taliesins/hyperv` 우선 검토 |

### 확정된 결정 (사용자 지시)

| ADR | 내용 |
|---|---|
| 019 | Vultr 단독 + IaC 평탄화 |
| 022 | v1 스택 복원 (`schema-reg`·`kafka-ui` 제외) |
| 026 | ECK 유지 — 관측성/보안 관제 도메인 분리 |
| 009 + 023 | Cilium + Istio Ambient **병행** |
| 032 | kafka-rest → Strimzi Kafka Bridge |
| 035 | Kafka 외부 노출은 HTTP Bridge 방식 |
| 051 | Hyper-V 로컬 타깃 도입 |
| **066** | **FreeIPA 아키텍처 제거** |

### 상태 집계

| 상태 | 건수 |
|---|--:|
| Accepted | 10 |
| Accepted (조건부) | 1 |
| Proposed | 27 |
| Open | 14 |
| Superseded | 2 |
| Partially Reverted | 1 |
| **합계** | **55** |

> 번호는 001~066 범위에서 부여했으나 일부 번호는 통합·병합되어 실제 항목 수는 54건이다.

---

## 관련 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 갭 목록(G1~G41), TODO 47건
- [SECURITY.md](./SECURITY.md) — SEC-xxx 68건
- [DEPLOYMENT.md](./DEPLOYMENT.md) — INFRA-xxx 56건
- [COMPONENTS.md](./COMPONENTS.md) — 구성요소 카탈로그
- [PRD.md](./PRD.md) — 목표·비목표, Phase 달성도
