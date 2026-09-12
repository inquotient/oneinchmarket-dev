# WSO2 Enterprise → OSS 대체 매핑

> 작성 2026-09-07 · 브랜치 `local`
>
> **전제** — "외부 API 소비자가 생길 것" 을 사실로 두고 **미리 짓는다.**
> 이 전제가 바뀌면 §6 의 순서가 통째로 바뀐다 — 소비자가 없으면 포털·플랜·
> 구독은 §8-79 에서 겪은 "배포됐지만 쓰이지 않는 컴포넌트" 가 된다.
>
> **이 문서가 아닌 것** — 구현 계획이 아니다. 후보 목록과 그 근거이며,
> 결정은 [ADR-079](ADR-CANDIDATES.md) 에 있다.
>
> **범위** — WSO2 로 시작했으나 "상용 제품을 OSS 조합으로 채운다" 라는
> 같은 작업이므로 관련 매핑을 함께 둔다. **부록 A 는 Vault Enterprise** 다.
>
> **표기** — ★ 권장 · ✅ 이미 있음 · ⚠️ 있으나 미완 · ❌ 없음

## 0. 왜 이 문서가 필요한가

WSO2 의 가치는 개별 기능이 아니라 **한 제품 안에서 서로 배선되어 있다는 점**이다.
OSS 로 가면 그 배선을 직접 해야 하고, 그 단가는 이 레포에 기록되어 있다 —
컨테이너 레지스트리 **하나**를 붙이는 데 서로 다른 결함 다섯을 지불했다(§8-79).
컴포넌트가 12개면 비용은 12배가 아니라 **상호작용의 곱**이다.

그래서 이 문서는 "무엇으로 대체할 수 있는가" 와 **"지금 이 클러스터가 어느 칸을
갖고 있는가"** 를 반드시 나누어 적는다. 이 구분을 흐리면 별점 다섯 개짜리 표가
실제로는 빈 칸이라는 사실이 가려진다.

## 1. 재사용 가능한 기반 — 실측 (2026-09-07)

후보들이 요구하는 데이터스토어가 **이미 전부 돌고 있다.** 이것이 여러 후보의
도입 비용을 크게 낮춘다.

| 데이터스토어 | 상태 | 이것을 요구하는 후보 |
|---|---|---|
| PostgreSQL | ✅ `postgresql-0` | OpenFGA · Lago · Flowable · Temporal · Backstage · ArgoCD |
| MongoDB | ✅ `mongodb-0` | **Gravitee CE** |
| Elasticsearch (ECK) | ✅ `elasticsearch-es-default-0` | **Gravitee CE** (분석) |
| Redis | ✅ `redis-0` | **Envoy ratelimit** · Lago |
| ClickHouse | ✅ `clickhouse-0` | Lago · OpenMeter |
| Kafka (KRaft) | ✅ `kafka-0` | Flink · Debezium · Camel |
| MariaDB | ✅ `mariadb-0` | (해당 없음) |

그리고 아이덴티티 계층이 이미 서 있다 — **Keycloak 26.7.3**(Organizations 가 GA 라
B2B 멀티테넌시가 네이티브로 된다) · **389DS**(사용자 저장소) · **LAM**(LDAP 관리).

## 2. 제품별 매핑

### A. WSO2 API Manager

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| API Gateway (동기) | ★ **Gravitee CE** / Kong OSS / APISIX / Tyk OSS / Envoy Gateway | Istio Gateway ✅ |
| Streaming·Async Gateway (WS·SSE·Kafka) | ★ **Gravitee CE** (Kafka·WS 네이티브) / Karapace + Kafka REST | ❌ |
| API Publisher (라이프사이클·버전) | ★ Gravitee CE Management / Apicurio + GitLab(APIOps) | Apicurio ⚠️ `artifacts=0` |
| Developer Portal (셀프서비스 구독·키) | ★ **Gravitee CE Portal** / Backstage / Zudoku·Redocly | ❌ |
| Key Manager (OAuth2·OIDC) | ★ **Keycloak** / Ory Hydra / Zitadel | ✅ `api-jwt.yaml` (§8-54) |
| Traffic Manager (쓰로틀·쿼터·spike arrest) | ★ **Envoy ratelimit + Redis** / Gravitee 정책 / APISIX limit-req | ❌ 자산 0건 |
| API Analytics | ★ OTel + Prometheus + Grafana + Loki/Tempo | ✅ (§8-55~63) |
| Threat protection (JSON·XML bomb, injection) | ★ **Coraza + OWASP CRS** / SafeLine / APISIX 플러그인 | SafeLine ✅ (부분) |
| 게이트웨이 내 변환·중개 | ★ Envoy Wasm/Lua / Gravitee 정책 40여 종 | ❌ |
| Monetization | ★ **OpenMeter** (부족하면 Lago) | 계량 ✅ / 가격 ❌ (§9-2) |
| API Governance·린팅 | ★ **Spectral**(CI) + OPA | Spectral ✅ / OPA ❌ |
| Multi-env · API Promotion | ★ **ArgoCD** + GitLab | ❌ ArgoCD 미설치 |
| Service Catalog | ★ Backstage / Apicurio | ❌ |

> ★ **게이트웨이 선택은 §5 에 따로 적었다** — Gravitee 와 Istio Gateway 는
> 같은 층이 아니고, 하나가 다른 하나를 대체하지 않는다.

### B. WSO2 Identity Server

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| OIDC·OAuth2·SAML2 | ★ **Keycloak** / Authentik / Zitadel / Ory | ✅ 26.7.3 |
| SSO · SLO · 페더레이션 | ★ Keycloak | ✅ |
| MFA (TOTP·WebAuthn·FIDO2) | ★ Keycloak | ✅ 가능 |
| **적응형 인증**(스크립트 조건부) | ⚠️ Keycloak Authenticator SPI(Java) · Zitadel Actions(JS) · Authentik Expression(Python) | ❌ **약한 칸** |
| 사용자 저장소(LDAP) | ★ **389DS + LAM** | ✅ |
| **SCIM 2.0 프로비저닝** | ⚠️ Keycloak SCIM 확장(커뮤니티) · **midPoint**(IGA 로 상위 대체) | ⚠ **midPoint 도입됨**(§8-103) — 연동은 미수 |
| XACML 엔타이틀먼트 (PDP) | ★ **OpenFGA**(ReBAC) / **OPA**(Rego) / Cerbos / Permify / SpiceDB | ✅ **OpenFGA v1.19.0**(§8-102) |
| 조직 · B2B 멀티테넌시 | ★ **Keycloak Organizations**(26.x GA) / Zitadel | ✅ 버전 충족 |
| 계정 셀프서비스(가입·복구·잠금) | ★ Keycloak | ✅ |
| **ID 운영 승인 워크플로** | ★ **midPoint** / Temporal | ⚠ **midPoint 도입됨**(§8-103) — 정책은 미작성 |
| **동의 관리(GDPR)** | ⚠️ Keycloak 기본 · midPoint · 자체 구현 | ❌ **약한 칸** |
| 감사 로그 | ★ Keycloak Event SPI → Kafka → ES/Loki | ⚠️ 미배선 |

> ★ XACML → OpenFGA/OPA 는 **이식이 아니라 재작성**이다. 모델이 다르다
> (속성 기반 → 관계 기반 또는 규칙 기반). 기존 정책 수가 많을수록 이 칸이 가장 비싸다.

### C. WSO2 Enterprise / Micro Integrator

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| ESB 중개(EIP) | ★ **Apache Camel / Camel K** / NiFi / Benthos(Redpanda Connect) | ❌ |
| 커넥터 200종 | ★ Camel 300+ 컴포넌트 / Kafka Connect | ❌ |
| **Data Services** (SQL→REST 무코드) | ⚠️ **PostgREST** / Hasura / Directus / Camel SQL+REST DSL | ❌ **약한 칸** |
| 메시지 스토어 · DLQ · 보장 전달 | ★ Kafka + DLQ 토픽 | ✅ (§8-61) |
| 예약 작업 | ★ Kubernetes CronJob | ✅ |
| 프로토콜 중개 (FTP·HL7·MLLP·FIX·AS2) | ★ **Camel** (전부 컴포넌트 존재) | ❌ |
| 변환 (XSLT·JSON↔XML·Smooks) | ★ Camel / Envoy Wasm | ❌ |
| 분산 트랜잭션 · Saga | ★ **Temporal** / Camel Saga | ❌ |
| 통합 개발 도구 | ★ Camel JBang + **Kaoto**(비주얼) | ❌ |

> ★ 통합 런타임이 이미 둘 있다 — Logstash 파이프라인(§8-59~61)과 OTel
> Collector(§8-55·56). Camel 을 넣으면 셋이 된다. **기존 파이프라인을 옮기지 말 것**:
> 과금 경로이고 Gotcha 23 이 "과금 토픽에 대고 실험하지 말 것" 이라고 못 박았다.

### D. WSO2 Streaming Integrator (Siddhi)

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| 스트리밍 SQL · CEP (패턴·시퀀스·윈도우·조인) | ★ **Apache Flink** (Flink SQL + Flink CEP) / RisingWave / Materialize / ksqlDB | ❌ (Spark 는 배치 ✅) — **보류 결정, §9-1** |
| CDC | ★ **Debezium** / Flink CDC | ⏳ **Kafka Connect 로 도입 중** (§9-3) |
| 스트림 알림 | ★ Flink → Alertmanager | Alertmanager ✅ |

### E. WSO2 Message Broker

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| JMS · AMQP · MQTT · STOMP 큐/토픽 | ★ **ActiveMQ Artemis** / RabbitMQ / EMQX(MQTT) | Kafka ✅ 이나 **JMS 아님** — **제외 결정, §9-1**(JMS 참조 0건 · Kafka 78개 파일) |

> 레거시 JMS 클라이언트가 없다면 이 칸은 비워 두어도 된다. Kafka 로 충분하다.

### F. WSO2 Business Process (BPMN)

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| BPMN 2.0 · 휴먼 태스크 · 승인 | ★ **Flowable** / Camunda 7(Apache 2.0) / **Temporal**(코드 우선) | ❌ — **제외 결정, §9-1**(업무 프로세스 0건 · 승인은 midPoint) |

### G. WSO2 Choreo (iPaaS · 내부 개발자 플랫폼)

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| 빌드·배포·관측을 묶은 셀프서비스 플랫폼 | ★ **Backstage** + **ArgoCD** + GitLab CI + Kubernetes | ArgoCD ✅ · GitLab CI ✅ · **Backstage 도입 예정**(§9-3) |

> 이건 제품이 아니라 **조합**이라 대체 난도가 가장 높다. 그리고 Backstage 는
> 카탈로그에 넣을 저장소가 있어야 값을 한다 — 현재 GitLab 의 코드 저장소는 0개다.

### H. WSO2 Ballerina

이미 Apache 2.0 OSS 다 — **대체 불필요.** 대안이 필요하면 Camel + Quarkus.

### I. 버티컬 액셀러레이터

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| Open Banking (FAPI · PSD2 · 동의) | ⚠️ **직접 대체 없음** — Keycloak FAPI 프로파일 + 동의 관리 자체 구현 | ❌ |
| Open Healthcare (FHIR · HL7) | ★ **HAPI FHIR** / Medplum / Camel HL7·FHIR 컴포넌트 | ❌ |

### J. 횡단 엔터프라이즈 기능

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| 시크릿 볼트 | ★ **OpenBao** + External Secrets Operator — 상세는 **부록 A** | ✅ OpenBao 2.4.1 `2/2`(§8-80) |
| 감사 추적 | ★ OTel → Loki / Elasticsearch | ✅ |
| 콘솔 RBAC | ★ Keycloak + 컴포넌트별 RBAC | ⚠️ |
| HA / DR | ★ Kubernetes + 컴포넌트별 HA | ❌ §9-6 이 "고치기 전까지 건드리지 말 것" |
| 관측 (메트릭·로그·트레이스) | ★ Prometheus · Grafana · Loki · Tempo · OTel | ✅ |
| 공급망 보안 | ★ Trivy · Dependency-Track · Cosign · Kyverno | ✅ (§8-79 에서 보강) |

## 3. OSS 로 깔끔히 못 메우는 칸 — 6개

나머지는 조립의 문제고, 이것들은 **직접 만들어야 한다.**

| # | 칸 | 왜 어려운가 | 가장 가까운 것 |
|---|---|---|---|
| 1 | **SCIM 2.0 프로비저닝** | Keycloak 에 네이티브 SCIM 서버가 없다 | midPoint (IGA 로 상위 대체) |
| 2 | **적응형 인증(스크립트)** | WSO2 는 JS. Keycloak 은 Java SPI 라 난도가 다르다 | Zitadel Actions · Authentik Expression |
| 3 | **Data Services (SQL→REST 무코드)** | 선언 수준이 다르다 | PostgREST |
| 4 | **동의 관리 · Open Banking FAPI** | 규제 프로파일이라 구현체가 없다 | 자체 구현 |
| 5 | **ID 운영 승인 워크플로** | 아이덴티티와 워크플로가 붙어 있어야 한다 | midPoint · Temporal |
| 6 | **"한 제품으로 묶여 있음"** | 기능이 아니라 **배선 비용**이다 | — |

## 4. 최소 조합 — 한 칸에 하나씩

```
게이트웨이·포털·플랜   Gravitee CE          (MongoDB·ES 이미 있음)
아이덴티티             Keycloak 26.7.3 ✅   + midPoint (SCIM·워크플로)
인가                   OpenFGA              (Postgres 이미 있음) ※ OPA 와 택일
통합                   Apache Camel K
스트리밍·CEP           ~~Apache Flink~~ 보류  + Debezium (CDC) — §9-1
BPM                    ~~Flowable / Temporal~~ 제외 — 업무 프로세스 0건, §9-1
JMS 가 필요하면        ~~ActiveMQ Artemis~~ 제외 — JMS 참조 0건, §9-1
과금                   OpenMeter (미완)     (부족하면 Lago)
GitOps·멀티환경        ArgoCD
카탈로그·개발자 포털   Backstage
시크릿                 OpenBao + External Secrets
WAF                    ~~Coraza + CRS~~ 제외 — 먼저 SafeLine 정리, §9-1
```

## 5. 게이트웨이 선택 — Gravitee CE vs Istio Gateway

**둘은 같은 층이 아니다.** Istio Gateway 는 트래픽 인프라(Envoy 기반 ingress +
메시)이고 Gravitee 는 그 위의 API 관리 제품이다. 겹치는 것은 TLS 종료·라우팅·
JWT 검증 셋뿐이다.

**그리고 Gravitee 는 Istio 를 대체하지 않는다.** ztunnel 이 워크로드 138개의
east-west 를 담당하고 AuthorizationPolicy 26곳이 거기 얹혀 있다. Gravitee 는
north-south 전용이므로 **Istio 는 그대로 남는다.** 즉 "둘 중 하나" 가 아니라
**"한 계층을 더 얹는 것"** 이다 — L7 홉 둘, 인증 지점 둘, 정책이 틀릴 수 있는 곳 둘.

Istio Gateway 에 **없는 것**(그래서 Gravitee 가 채우는 것):

- API / Plan / Subscription / Application(소비자) / API Key 라는 **제품 개념 자체**
- 개발자 포털 — 셀프서비스 구독·키 발급
- API 라이프사이클(draft → published → deprecated) · 버전
- 쓰로틀·쿼터 (Istio 는 `envoyproxy/ratelimit` 을 따로 붙여야 한다)
- 정책 플러그인 조합 (바디 변환 · JSON↔XML · 캐시 · callout)

현재 게이트웨이의 실측 상태 — HTTPRoute 2개(`api.oneinchmarket.local` +
https 리다이렉트), 인가는 `requestPrincipals: ["*"]` 라 **유효한 Keycloak 토큰이면
누구나 통과**한다. 소비자별 구분도 쿼터도 없다.

### 전환 비용 — 계량 지점이 움직인다

과금 계약이 게이트웨이에 물려 있다. `contracts/schemas/api-usage-event.json` 의
`data` 필드는 **Envoy 액세스 로그 변수**에서 나온다(`telemetry-usage.yaml`):

```
route, method, status, duration_ms, request_bytes, response_bytes, api_product
```

게이트웨이를 바꾸면 로그 형식 → 이벤트 스키마 → OpenMeter 미터 정의가 연쇄로
흔들린다. 미터는 PostgreSQL 에 저장되고 불일치 시 OpenMeter 가 **기동을 거부**한다
(Gotcha 29).

★★ **그런데 지금은 청구 이력이 0건이다** — 요금제가 정의되지 않았다.
Gotcha 15 가 말한 "이미 청구한 이력" 이 아직 없으므로, **바꾼다면 지금이 가장 싼
순간이고 앞으로는 계속 비싸진다.** 요금제를 정의하기 **전에** 결정할 것.

### 판단 — **둘 다다(2026-09-12 결정, ADR-079 `Accepted`)**

★★★ 위의 "전환 비용" 절이 **잘못된 질문을 깔고 있었다.** 그것은 Gravitee 를
Istio *대신* 놓는 경우의 비용이고, 그때만 계량 지점이 움직인다.
**Gravitee 를 Istio 뒤에 놓으면 계량 지점은 움직이지 않는다** — 트래픽이
Istio 게이트웨이를 먼저 지나므로 액세스 로그가 그대로 나온다. 즉 이 절이
가장 비싸다고 적은 항목이 **배치를 바꾸면 0이 된다.**

```
바깥 -> Istio Gateway -> Gravitee Gateway -> cmmn-api
        ^ TLS·JWT·계량·쓰로틀    ^ 카탈로그·포털·구독/키·변환
```

- **Istio** — TLS · JWT 검증 · 신원 · **계량** · **쓰로틀**
  (쓰로틀 원천은 `local/pricing-catalog.yaml` 하나다, Gotcha 71)
- **Gravitee** — API/Plan/Subscription/Application 이라는 **제품 개념**,
  개발자 포털, 라이프사이클, 요청·응답 변환
- ★★ **Gravitee 의 플랜·쿼터·분석은 켜지 않는다.** 켜는 순간 "이 고객이 무엇을
  샀는가" 의 원천이 Gravitee 의 Mongo 와 OpenMeter 의 PostgreSQL 둘이 된다.
  그래서 첫 API 의 플랜은 KEY_LESS 다.

실측(2026-09-12): 같은 `acme-corp` 토큰으로 `/api/menu`·`/managed/api/menu` 둘 다
200, 토큰 없이 403, 액세스 로그에 `local.api.0`·`local.managed-api.0` 이 **둘 다**
남고 Kafka `api-usage` 에 6건이 들어갔다.

**대가는 실재한다** — L7 홉이 둘이 된다. 같은 액세스 로그의 `duration_ms` 로
재면 직결이 **4·5·7ms**, Gravitee 경유가 **10·12·22ms** 다(각 3건, 같은 시각대).
그리고 4파드가 1,856 Mi 를
예약하며, 정책이 틀릴 수 있는 곳이 둘이다. 그래서 Gravitee 에는 **인증·인가를
맡기지 않는다** — 그 둘은 Istio 한 곳에만 있다.

**되돌릴 조건** — 소비자 셀프서비스가 끝내 필요 없다고 판명되는 날. 그때는
Gravitee 4파드를 걷고 Istio + `envoyproxy/ratelimit` + Redis 만 남기면 된다
(그 조합은 이미 돌고 있어 철거가 곧 회수다: 1,856 Mi, 노드 89% -> 85%).

## 6. 도입 순서

### Phase 0 — 전제 (지금 깨져 있다)

1. ~~**시크릿**~~ — **끝났다**(§8-82). OpenBao 가 `2/2 Running · Sealed=false` 이고
   External Secrets 오퍼레이터 3파드가 돌며 **ExternalSecret 29건이 전부
   `SecretSynced`** 다(2026-09-08 실측). 위의 "Vault 는 0/1 봉인" 은 낡은 서술이었다.
2. ~~**ArgoCD**~~ — **끝났다**(§8-83·§8-84·§8-86). 네임스페이스·파드 7개·
   Application 1개가 있고 자동 동기화가 돌고 있다. 위의 "CRD 0 · 파드 0" 은
   낡은 서술이었다.
3. **메모리 여유** — 프로파일 분리(§19 ③). §11-4 가 이미 `필요 56.6 vs 가용 47.6` 이다.

### Phase 1 — API Manager 완성 (절반은 이미 있다)

4. ~~**쓰로틀링**~~ — **끝났다**(§8-89). `envoyproxy/ratelimit` + 기존 Redis.
   descriptor 키는 토큰의 tenant 클레임이고, 실측으로 650회 버스트에서
   **600번째부터 429** 를 받았다. 요금제별 쿼터는 ConfigMap 의 `descriptors` 에
   테넌트를 명시해 준다. ~~요금제와 한도를 잇는 자동화는 아직 없다~~ —
   **§8-90 에서 생겼다.** local/pricing-catalog.yaml 이 가격과 쿼터의 단일
   원천이고, render-ratelimit.py --check 가 뒤처지면 CI 가 멈춘다
5. **Apicurio 채우기** — `contracts/openapi/` 작성. ~~지금 0건~~ — **1건이
   생겼다**(`cmmn-api.yaml`, §8-99). 실측으로 썼고 spectral 을 0 errors 로
   통과한다. 남은 것: menu 이벤트 Avro 스키마·`asyncapi/cmmn-api.yaml`.
   ★ 그리고 `publish-contracts` 이 `v2` 브랜치 전용이어서 **클러스터가 있는
   `local` 에서는 돌지 않았다** — 그것도 함께 고쳤다
6. ~~**요금제 정의**~~(§9-2) — **끝났다**(§8-87·§8-90). 3단 요금제·고객·구독이
   서고 인보이스가 나온다. 5xx 가 청구되지 않는 것까지 확인했다
7. **Gravitee CE** — 소비자 셀프서비스가 필요하다는 전제라면 여기. §5 를 볼 것

### Phase 2 — Identity Server 완성

8. ~~**OpenFGA 또는 OPA**~~ — **OpenFGA 로 도입했다**(2026-09-08, §8-102).
   PostgreSQL 을 재사용하고 wave 4 에 선다. 인증(preshared)을 켜고
   플레이그라운드를 꿼다. 검증은 관계 추론까지 했다 — alice 를 editor 로만
   썼는데 viewer 질의가 True 였고(union 규칙) bob 은 False 였다.
   ★ OPA 를 고르지 않은 이유 — 이 플랫폼에는 규칙 기반 정책 엔진이 이미
   둘 있다(Kyverno = 어드미션, Istio AuthorizationPolicy = 서비스 간). 비어
   있는 칸은 **앱 데이터에 대한 인가**이고 그것은 관계로 표현된다
9. ~~**midPoint**~~ — **도입했다**(2026-09-08, §8-103). 4.10.4-alpine, wave 4,
   비-root(1000). 네이티브 PostgreSQL 저장소(테이블 100개 · 전부 midpoint
   소유)이고 `/actuator/health` 가 UP 이다. 실측 **1203Mi**

### Phase 3 — Integrator · Streaming

10. **Camel K** — Micro Integrator 대체 (기존 파이프라인은 옮기지 말 것)
11. **Debezium (Kafka Connect)** — CDC. ~~Flink~~ 는 **보류**(§9-1) — Iceberg 적재는 `iceberg-kafka-connect` 1.11.0 이 대신한다
12. ~~**Flowable 또는 Temporal** — BPM~~ → **제외**(§9-1). 이 자리는 비워 둔다

### Phase 4

13. **Backstage** — Choreo · 카탈로그. 카탈로그에 넣을 저장소가 생긴 뒤에

## 7. 메모리 산정 — **추정이다, 실측이 아니다**

아래는 업스트림 기본값과 통상적인 JVM/Go 런타임 크기에서 나온 **추정치**다.
이 레포의 다른 수치(§11-4 · §18-3)는 실측이므로 **섞어 쓰지 말 것.**
도입할 때마다 `kubectl top pod` 로 실측해 이 표를 교체할 것.

★★ **2026-09-10 실측 결과: 추정은 일관되게 과대했다.** Kafka Connect 38% ·
Backstage 31% · Gravitee 43% · Camel K **3%** · OpenFGA 10%(§8-102).
JVM 이라고 추정이 맞는 것도 아니었다 — midPoint 만 맞았다.
★ 다만 **유휴 값으로 requests 를 깎지 말 것**(Gotcha 102): 이 숫자들은
일을 시키기 전의 값이다. Camel K 는 통합 0건, Gravitee 는 트래픽 0,
Kafka Connect 는 스냅샷이 끝난 뒤의 정상 상태다.

| 컴포넌트 | 추정 | 비고 |
|---|---|---|
| Gravitee CE (4종 전부) | ~~2.0 ~ 2.5 GiB~~ **실측 1.06 GiB** | gateway 448Mi + management-api 595Mi + console 26Mi + portal 20Mi. **UI 2종은 합쳐 46Mi** 다 — 추정할 때 JVM 3종으로 잡은 것이 틀렸고 UI 는 nginx 다. MongoDB 는 재사용 |
| Flink (JobManager + TaskManager) | 2.0 ~ 3.0 GiB | |
| midPoint | 1.0 ~ 1.5 GiB → **실측 1203Mi** | JVM. 이번엔 추정이 맞았다 — Go 와 달리 JVM 은 부풀려 있지 않다(§8-103) |
| Debezium (Kafka Connect) | ~~1.0 GiB~~ **실측 406Mi** | JVM 인데도 추정의 40% 다 — 상류 이미지(커넥터 15종) 대신 **커넥터 하나만** 구우면 이런다. request 는 768Mi 로 두었다 — 스냅샷과 재시작 시 일시적으로 더 쓴다 |
| ArgoCD (4 컴포넌트) | 0.5 ~ 1.0 GiB | |
| Backstage | ~~0.7 ~ 1.0 GiB~~ **실측 252Mi** | |
| ActiveMQ Artemis | 0.5 ~ 1.0 GiB | JMS 가 필요할 때만 |
| Flowable / Temporal | 0.5 ~ 0.8 GiB | |
| Camel K (operator) | ~~0.5 ~ 1.0 GiB~~ **실측 27Mi** | ★ 통합이 **0건**일 때의 값이다. Integration 을 만들면 빌드 파드(request 512Mi·limit 1536Mi)와 통합 파드가 따로 뜬다 — 오퍼레이터만으로 판단하지 말 것 |
| OpenBao + External Secrets | 0.4 GiB | |
| OpenFGA | ~~0.15 ~ 0.25 GiB~~ **실측 17Mi** | Go. 추정의 **10분의 1** 이었다(§8-102) |
| Envoy ratelimit | 0.1 GiB | Redis 재사용 |
| Coraza | 0.0 ~ 0.25 GiB | Envoy Wasm 이면 무시 가능 |
| **합계** | ~~8 ~ 14 GiB~~ **2026-09-10 도입분 7종 실측 1.73 GiB** | ★ 이 숫자를 그대로 믿지 말 것 — 첫 실측에서 OpenFGA 가 추정의 1/10 이었다. **Go 서비스는 부풀려 있고 JVM 은 그렇지 않을 것이다** — 도입할 때마다 칸을 실측으로 교체할 것 |

**Phase 0 의 프로파일 분리가 선행되지 않으면 들어갈 자리가 없다.** 이것은
취향이 아니라 산술이다.

## 9. 제외·유지 결정 — 2026-09-10

§2~§7 은 **"무엇으로 대체할 수 있는가"** 를 적는다. 이 절은 **"무엇을 넣지
않기로 했는가"** 를 적는다. 근거를 남기지 않으면 다음 사람이 같은 검토를
처음부터 다시 한다 — 이 문서는 §8-102 에서 이미 그 값을 치렀다(Gotcha 98:
낡은 계획서는 계획을 막는다).

★ **여기 있는 것은 "영영 안 한다" 가 아니라 "지금은 아니다" 다.** 각 행의
**복귀 조건**이 참이 되는 날 다시 후보가 된다.

### 9-1. 넣지 않기로 한 것

| 컴포넌트 | 결정 | 근거 (실측 2026-09-10) | 복귀 조건 |
|---|---|---|---|
| **Apache Flink** | 보류 | 스트림 잡 **0건**. 배치는 Spark 가 이미 한다. Iceberg 적재는 `org.apache.iceberg:iceberg-kafka-connect` **1.11.0** 이 Maven Central 에 있어 Kafka Connect 로 된다(클러스터의 `ICEBERG_VERSION` 과 같은 값). 윈도우·조인·간단한 CEP 는 Kafka Streams 로 된다 — **라이브러리라 인프라가 0이다** | Kafka Streams 로 손수 짠 패턴 매칭이 셋을 넘거나, **이벤트 타임 + 워터마크 + 큰 상태**가 필요해질 때. ★ 매니페스트는 `kubernetes/base/streaming/` 에 이미 있으나 **`base/kustomization.yaml` 에 연결하지 않았다** — 되살릴 때 그 한 줄부터 |
| **Flowable** | 제외 | 실행할 업무 프로세스 **0건**. 업무 워크로드가 `admin`·`cmmn-api`·`nginx` **셋**이고 서비스 간 호출 **0건** — MSA 가 아니다. ID 운영 승인은 **midPoint 가 이미 덮는다**(§3 의 5번 칸). BPMN 작도는 draw.io 로 충분하다 | 사람 승인 단계가 있는 **크로스 서비스 프로세스**가 생길 때. ★★ 그때도 **중앙 엔진 서버가 아니라 Spring Boot 임베드 라이브러리**로 시작할 것 — 중앙 서버는 결합점과 상태 중앙화를 만든다(Kafka Streams 의 클러스터 vs 라이브러리와 같은 논리). 변수에는 ID·상관관계 키만 담고, 서비스 호출은 `HTTP Task` 가 아니라 **메시지 이벤트 + Kafka** 로 |
| **Temporal** | ✅ **도입**(2026-09-11, 사용자 결정) | Flowable 과 같은 칸이라 함께 보류. 다만 **사가(크로스 서비스 원자성)가 필요해지면 이쪽이 낫다** — BPMN 엔진에는 그 보증이 없다 | ★ **복귀 조건을 만나서가 아니라 사용자 결정으로 들였다.** 여기 적어 둔 신호는 "보상 트랜잭션을 손으로 짜기 시작하면" 이었는데, 실제 용도인 독촉(dunning)은 그것과 결이 다르다 — 사가가 아니라 **며칠짜리 durable timer + 재시도**다. 그 구분은 남겨 둔다. 구성은 `kubernetes/base/orchestration/`(wave 4) · auto-setup 한 프로세스 · PostgreSQL 2 DB |
| **Hyperswitch**(결제 오케스트레이션) | 보류 | **붙일 구멍이 없다** — OpenMeter 의 `collectPayments` 는 앱 인터페이스이고 구현체가 `sandbox`·`stripe` **둘뿐**이다(실측 marketplace). 붙이려면 OpenMeter 에 앱을 새로 구현하거나 결제 단계를 OpenMeter 밖으로 빼야 하고, 후자는 인보이스 상태의 주인이 갈린다. ★ 그리고 Hyperswitch 는 PSP 를 **라우팅**하는 계층이지 PSP 가 아니다 — 뒤에 Stripe/Adyen 계정이 여전히 필요한데 지금 PSP 는 **0개**다 | PSP 가 **둘 이상** 필요해질 때. PSP 하나면 OpenMeter 의 stripe 앱이 더 짧은 길이다 |
| **Listmonk**(메일 캠페인) | 보류 | 메일 자체가 빈칸인 것은 맞다 — Alertmanager·GlitchTip·Keycloak·DefectDojo **넷이** "SMTP 가 없다" 로 막혀 있다(실측). 다만 Listmonk 는 **캠페인 발송기**이지 SMTP 서버가 아니다. 뒤에 실제 발송 경로가 여전히 필요하고, 비밀번호 재설정·독촉 고지 같은 **트랜잭션 메일**은 주 용도와 결이 다르다 | **발송 경로(릴레이 자격 또는 자체 발송)를 먼저 정한 뒤**, 고객 대상 캠페인이 실제로 생길 때 |
| **ActiveMQ Artemis** | 제외 | JMS·AMQP·MQTT·STOMP 참조가 레포 전체에 **0건**, Kafka 는 **78개 파일**. 레거시 JMS 클라이언트가 없다 | JMS/AMQP 를 요구하는 **외부** 클라이언트가 붙을 때. 우리 쪽 코드를 위해 들이지는 말 것 |
| **Coraza + CRS** | 제외 | 사용자 결정(2026-09-10). ★ 검토 중 함께 드러난 것이 더 중요하다 — **SafeLine 이 트래픽 경로 밖이다**: HTTPRoute backend **0건** · IngressClass **0건**인데 **1.47 GiB** 를 예약하고 자기 로그에 `502 Bad Gateway` 를 찍고 있다 | **WAF 칸은 Coraza 도입이 아니라 SafeLine 정리가 먼저다.** 경로에 넣든 걷어내든 하나를 고를 것 — 지금은 "있는 것처럼 보이지만 아무것도 막지 않는" 상태다(Gotcha 33·84 와 같은 부류) |
| **Hubble** | ✅ **도입**(2026-09-11) | "도입" 이 아니라 **마저 켠 것**이다 — 에이전트는 `enable-hubble=true` 로 흐름을 모으고 있었는데 **relay·UI 파드가 0개**였다. 켠 뒤 실측: `Connected Nodes 1/1` · `Flows/s 166.87` · DROPPED 필터 동작 · `→ redis-0:15008`(ambient HBONE) 가 보인다 | — ★ ambient 에서 정책 거부가 **타임아웃으로 보이는** 문제(Gotcha 13·19·50)에 직접 듣는다 |
| **Pyrra / Sloth**(SLO) | **✅ 도입 (2026-09-11, 사용자 결정)** — 보류를 뒤집었다 | ★ **컨트롤러 모드로 넣지 않았다.** 둘 다 `PrometheusRule` CR 을 만드는데 **이 클러스터에는 Prometheus Operator 가 없다**(실측: `monitoring.coreos.com` CRD **0개**). Prometheus 는 평 `prom/prometheus:v3.14.0` 이고 규칙은 `prometheus-rules` ConfigMap 에서 온다 — 컨트롤러를 얹으면 출력이 **갈 곳이 없다**(Gotcha 84·141 의 부류: 설정은 있고 아무도 읽지 않는다). 그래서 각각 맞는 모드로 넣었다: **Sloth 는 생성기**(`local/render-slo.sh` 가 `slo/*.yaml` → `slo/generated/*.rules.yaml`, `--check` 로 CI 게이트 — `render-ratelimit.py` 와 같은 모양, §8-90), **Pyrra 는 filesystem 모드**(SLO ConfigMap → 규칙 emptyDir → UI 9099). 첫 SLO 는 **이미 계량되는 지표**로 잡았다(`istio_requests_total` 의 5xx 비율) — 없는 지표로 SLO 를 쓰면 빈 그래프가 "좋다" 로 읽힌다 | 실측: Sloth 가 규칙 **17개** 생성 · `--check` 통과 · Pyrra 가 규칙 **13개** 생성 · API 가 SLO 를 나열한다. ★★ **처음엔 Pyrra 가 규칙을 하나도 만들지 않았다** — `/var/lib/pyrra/rules` 가 비어 있었다. 원인은 SLO 정의에 `metadata.namespace` 가 없던 것이고, Pyrra 는 그것을 **오류가 아니라 경고로** 낸다(`validation warning ... namespace must be set`). 파드는 `2/2 Running` 이고 UI 도 200 을 준다 — **판정을 파드 상태나 UI 응답으로 하지 말고 생성물의 건수로 할 것**(Gotcha 12·33·84 와 같은 부류).  ★★ **Sloth 쪽은 잇었다** — `local/slo-to-configmap.py` 가 생성물을 `prometheus-rules` ConfigMap 안으로 넣고(키는 **`.yml`** 이어야 한다 — `rule_files` 가 `*.yml` 로 잡는다), 실측으로 **Prometheus 가 규칙 22개를 들었다**(billing 2 · platform 3 · **SLO 17**). ★ 그 과정에서 드러난 것: 기존 `platform.rules` 의 `GatewayHighErrorRate` 가 **이미 Sloth 출력 형식**(`slo:sli_error:ratio_rate5m{sloth_id=...}`)을 참조하고 있었다 — 그 경보는 그동안 받침 규칙이 없어 **죽어 있었다**. ★★★ **지표는 있었다 — 없는 줄 알고 한번 잘못 적었다.** 처음 재을 때 `istio_requests_total` 이 **시계열 0건**이라 "없는 지표로 SLO 를 썼다" 고 판단했는데, 게이트웨이에 HTTP 요청 3건을 보내자 **그 자리에서 생겼다**(Gotcha 150). 라벨도 맞는다 — `reporter="source"` 가 실제로 잡힌다. 지금 `slo:sli_error:ratio_rate5m` 이 비어 있는 것은 카운터가 평평해 0/0 이기 때문이고, 그것이 올바른 행동이다. ★ **결승하지 않았다: 부재 경보를 두지 않았다** — 트래픽이 없는 랩에서는 항상 울려 배경이 된다(Gotcha 73·90 이 경계하는 것). 대신 **비어 있음과 0 이 구분된다**는 사실을 적어 둔다 — 기록 규칙이 **없는** 것이 "무통" 이고, 0 이면 "오류 없음" 이다. ★★ **Pyrra 쪽은 여전히 잇지 않았다** — 규칙을 emptyDir 에 쓰므로 Prometheus 가 같은 볼륨을 마운트해야 하고, 그것은 Prometheus StatefulSet 을 손대는 일이라 별도 결정이다. 지금 Pyrra 는 **UI 역할**이고 규칙의 주인은 Sloth 다 |
| **Harbor** | 제외 — **멀티레포를 근거로 재검토했고 결론이 바뀌지 않았다**(2026-09-11) | 멀티레포에서 **실제로 레포 수에 비례해 커지는 두 가지는 GitLab 쪽이 낫다**: ① 레지스트리 경로가 **프로젝트 경로에서 자동으로 파생**된다 — 레포를 만들면 경로가 생긴다. 지금 `oneinch` 그룹의 빈 프로젝트 12개는 *단일 레포라서* 생긴 군더더기다(이미지에 주인 레포가 없어 경로만 만들어 둔 것이라 멀티레포가 되면 오히려 **사라진다**) ② CI 자격이 `CI_JOB_TOKEN`(`.gitlab-ci.yml:266` 의 `CI_REGISTRY_USER/PASSWORD`)이라 **레포마다 배포할 시크릿이 0개**다 — Harbor 는 프로젝트마다 robot 계정을 만들어 각 레포 CI 변수에 넣어야 하므로 **레포 수만큼 시크릿이 늘고 그만큼 회전해야 한다.** 즉 멀티레포는 Harbor 쪽 논거가 아니라 **반대 논거**다. Harbor 가 진짜로 더 주는 셋(프록시 캐시 · 보존/쿼터 · CVE·서명 pull 차단)은 **레포 수와 무관**하고 뒤의 둘은 이미 있는 것으로 덮인다 — 보존은 GitLab Free 의 프로젝트별 cleanup policy(실측 **켜진 프로젝트 0개**, 레지스트리 4.3G · 리포 12 · 태그 12), 서명 검증은 Kyverno `verifyImages`(실측 ClusterPolicy 7종 중 이미지 검증 0종). 남는 하나가 **프록시 캐시**이고 그것이 복귀 조건이다. 그리고 둘째 레지스트리는 이미지 원천을 둘로 만든다 — 그 실패는 Gotcha 85 가 실측해 두었다(빌드 성공·반입 성공·파드는 옛 이미지, **오류 0줄**) | ★ **메모리는 더 이상 근거가 아니다** — §23 의 56GB 상한 뒤 노드 여유가 **8,255Mi**(allocatable 53,887 / 요청 45,632)라 Harbor 최소 구성(core·registry·jobservice·portal·db·redis, 1~1.5Gi)은 **들어간다.** 복귀 조건은 **상류 pull 을 캐시해야 할 때**다: 이 클러스터는 상류 레지스트리 **8곳**에서 받는데 docker.io 는 132/236(56%)뿐이고 **quay.io 29 · ghcr.io 28 · public.ecr.aws 18 · docker.elastic.co 8 = 83건(35%)은 GitLab Dependency Proxy 가 못 덮는다**(그것은 Docker Hub 전용이다. 이 GitLab 은 19.3.1-ee **라이선스 없음 = Free** 라 그 기능 자체는 쓸 수 있다). Gotcha 132 가 잰 "이 회선은 큰 이미지 원격 읽기에서 리셋된다" 가 kubelet pull 까지 번지면 그때가 복귀 시점이고, 그때도 **push 대상이 아니라 프록시 캐시로만** 세울 것 — 그래야 이미지 원천이 둘이 되지 않는다. 단 대가가 있다: `registries.yaml` 의 mirror 가 Harbor 를 가리키게 되므로(노드 상태, §25) **Harbor 가 죽으면 단일 노드 전체가 이미지를 못 받는다** |
| **OpenSearch** | **✅ 도입 (2026-09-11)** — 두 번 제외했다가 사용자 결정으로 전환했다 | OpenSearch **3.8.0** + **Data Prepper 2.16.0**. Elasticsearch 9.5.3 · Kibana · Filebeat · ECK 를 **철거**했고 기존 31.66 GB 는 **옮기지 않았다**(ES 9 의 Lucene 10.5.1 스냅샷은 OpenSearch 에 복원되지 않는다). ★ **하드 블로커였던 Filebeat 이 실은 군더더기였다** — `otel-agent` 가 **이미** `/var/log/pods/*/*/*.log` 를 전부 읽어 otel-gateway 로 보내고 있었다(거기서 Loki 로 간다). 즉 Filebeat 은 **두 번째 전체 로그 파이프라인**이었고 걷어내도 잃는 것이 0이었다(참고: 그 데몬셋은 재시작 89회 상태였다). 지금 경로는 `otel-agent(filelog) -> otel-gateway -> Data Prepper -> OpenSearch` 이고 **Loki 로도 계속 간다**(하나를 끊고 붙이지 않았다). ★★ **Data Prepper 는 Logstash 를 완전히 대체하지 못한다** — TCP·syslog source 가 없고(Zeek 5141 · Suricata 5140), 아웃바운드 HTTP 요청 + 실패 분기 프로세서가 없다(Logstash `http` 필터의 `tag_on_request_failure` 등가물). 후자가 하필 **과금 DLQ** 라 손대면 매출이 샌다(Gotcha 31). 그래서 Logstash 를 **축소**했다 — 과금 다리와 TCP 수신만 남기고, 그 결과물은 OpenSearch 로 직접 쓰지 않고 **Data Prepper 의 http source 로 넘긴다**(`format => json_batch` 필수 — 그 source 는 JSON 배열만 받는다). 그러면 Elastic 배포 Logstash 9.5.3 에 `logstash-output-opensearch` 를 설치하지 않아도 된다 | **실측 결과**: 클러스터 **green** · `logs-2026.09.11` **405,365 문서/252 MB** · `siem-2026.09.11` **47,514** · `zeek-2026.09.11` 7 · 노드 메모리 **89% -> 84%**. 인증이 실제로 강제된다(자격 없이 401 · 틀린 비밀번호 401 — Elastic Basic 과 갈리는 지점이다). ★ **기능 티어가 도입의 근거는 아니었다** — SAML/OIDC 렐름 · DLS/FLS · 감사 로그가 OpenSearch 에서 무료인 것은 사실이나(Elastic 은 전부 Enterprise), 우리는 **아직 그것들을 쓰지 않는다**. Kibana 는 SSO 없이 돌았고 SEC-205 의 계획은 `oauth2-proxy + Keycloak` 이며 감사는 Wazuh 로 간다. 즉 지금 얻은 것은 **선택지**이지 기능이 아니다 — 켤 조건은 §9-16 에 적었다. ★★ **정정(같은 날)**: 앞서 "Zeek·Suricata 를 옮기면 Logstash 는 과금 다리 하나만 남는다" 고 적었는데 **틀렸다**. 실측으로 넷을 갈라 보면 — **Zeek**(발신자 `zeek-ship` 이 우리 코드라 배열 POST 로 고치면 된다)와 **Suricata**(syslog-ng 의 `http()` + `batch-lines` + `body-prefix/suffix` 로 JSON 배열을 만들 수 있다, 단 그 빌드에 http 모듈이 있어야 한다)는 옮길 수 있지만, **Alertmanager 와 과금 다리는 옮길 수 없다**: 전자는 webhook 페이로드가 **객체 하나**이고 형식을 바꿀 수 없는데 Data Prepper 의 http source 는 배열만 받는다(실측: 배열 200 · 객체 400 `Bad request data format. Needs to be json array.` · 원시 텍스트 400), 후자는 **Data Prepper 에 HTTP sink 자체가 없다**(sink 7종 — Lambda·File·OpenSearch·Pipeline·Prometheus·S3·stdout). 그리고 다리를 없앨 수도 없다 — OpenMeter 는 **자기 토픽 `om_sys.ingest_events` 만** 소비한다(`ingest.kafka.broker` 는 브로커 주소이지 토픽 지정이 아니다). ★ 즉 **Zeek·Suricata 를 옮겨도 Logstash 는 그대로 남는다**(requests 1,536Mi · 실사용 1,033Mi) — 구조적으로 얻는 것이 없으므로 하지 않았다. ★★ Logstash 를 실제로 걷어내려면 남은 **둘 다**를 대체해야 한다: 과금 다리는 **Kafka Connect**(이미 돌고 있고 `errors.deadletterqueue.*` 로 네이티브 DLQ 가 있다)에 HTTP sink 커넥터를 넣는 길이 있고, Alertmanager 는 객체→배열 어댑터가 따로 필요하다. 회수량 약 1.5 GiB 대 과금 DLQ 경로를 다시 쓰는 위험(Gotcha 31·32 가 이미 한 번 틀렸던 자리다) — 별도 결정으로 남긴다 |
| **BuildKit / Kaniko** | **✅ 도입 (2026-09-11, 사용자 결정)** — 둘 다 | **BuildKit**: rootless 데몬(`moby/buildkit:v0.33.0-rootless`, 1234) — **`overlays/local/buildkit/` 에 두었다**(base 에 두면 prod 가 상속해 어드미션에서 거부된다 — Caldera 와 같은 이유). ★★ **`allowPrivilegeEscalation: true` 가 구조적으로 필요하다** — rootless 는 `newuidmap`/`newgidmap` 으로 사용자 네임스페이스를 만드는데 그 둘이 **setuid** 라 `false` 면 실행 자체가 막힌다(실측: `fork/exec /usr/bin/newuidmap: operation not permitted`). root 는 아니다(uid 1000). **Kaniko**: 데몬이 없어 Job 하나로 끝난다 — 권한 상승이 필요 없는 대신 uid 0 이 필요하고 캐시가 없다. `kubernetes/base/devops/templates/kaniko-build-job.yaml` 에 **템플릿으로만** 두었다(kustomization 에 넣으면 동기화마다 빌드가 돈다) | ★ **prod 승격 때 둘 중 하나를 골라야 한다** — Kyverno 가 prod 에서 `disallow-privilege-escalation`·`disallow-root-user` 를 Enforce 하므로 BuildKit 은 전자의, Kaniko 는 후자의 exclude 가 필요하다. 마찰이 적은 쪽은 **Kaniko** 다(Camel K 빌더가 같은 자리에서 걸렸다, Gotcha 129). ★★ **지금 굽는 대상이 0개다** — `.gitlab-ci.yml` 이 참조하는 `v1/admin/Dockerfile`·`cmmn-api/Dockerfile` 이 없고 로컬 이미지 11종은 노드의 podman 이 굽는다. 경로를 열어 둔 것이지 쓰이는 것이 아니다 |
| **Paketo Buildpacks** | **✅ 도입 (2026-09-11, 사용자 결정)** — kpack 으로 | Paketo 는 **빌더 이미지**이지 클러스터 컴포넌트가 아니다. 쿠버네티스에서 돌리려면 컨트롤러가 필요해 **kpack v0.18.0** 을 넣었다(CRD 10종 · 컨트롤러+웹훅 2파드). ★ 설치에서 한 번 걸렸다 — `ClusterLifecycle` CR 이 자기 CRD 보다 먼저 적용돼 `no matches for kind` 로 실패했다. **같은 파일을 한 번 더 적용**하면 풀린다(CRD 가 그 사이 established 된다) | ★ **Builder·ClusterStore 를 아직 만들지 않았다** — 그것을 만들려면 Paketo 빌더 이미지를 받아야 하고(수백 MB), 무엇보다 **빌드할 앱 소스가 이 레포에 없다**. BuildKit/Kaniko 와 같은 전제다. 복귀 조건이던 "앱 소스가 이 레포로 들어올 때" 는 **여전히 참이 아니다** — 컨트롤러만 세워 둔 상태다 |
| **KEDA** | **✅ 도입 (2026-09-11, 사용자 결정)** — 기록이 없던 것을 채운다 | KEDA **v2.20.2**(operator·metrics-apiserver·admission 3파드 · CRD 6종). ★ **local 에는 스케일할 대상이 없다** — 실측 HPA 1개 · `replicas>1` 인 워크로드 **0종**. 반면 **prod 렌더에는 5종**이 있다(kafka 3 · redis 6 · nginx/keycloak/logstash 2). 즉 이것은 local 에서 값을 내는 도입이 아니라 **prod 를 위한 예행**이다 | ★★ **prod 에 켜기 전에 Gotcha 35 를 먼저 풀 것** — prod 의 DB 3종 `replicas: 2·3` 은 HA 가 아니라 **데이터 분기**다(복제 설정이 하나도 없다). 그 위에 오토스케일을 얹으면 분기를 자동화하는 셈이다. 근본 원인은 ADR-015(스토리지)가 `Open` 인 것이다 |
| **Crossplane** | **✅ 도입 (2026-09-11, 사용자 결정)** — 기록이 없던 것을 채운다 | Crossplane **v2.4.0**(core·rbac-manager 2파드 · CRD **21종**). Helm 은 이 레포 관례대로 **렌더러로만** 썼다(`helm template | kubectl apply`, 릴리스를 남기지 않는다). 자원은 `--set` 으로 192Mi/512Mi 로 낮췄고 **렌더 결과를 눈으로 확인했다**(Gotcha 88: `--set` 은 없는 키를 조용히 받아든다) | ★ **provider 를 하나도 넣지 않았다** — 넣으려면 클라우드 자격이 필요한데 이 랩에는 없다. ★★ 그리고 **대체할 대상 자체가 없다**: 실측으로 `tfstate` **0개**, prod 의 provider 블록 **0개**(dev 만 3개) — OpenTofu 가 한 번도 적용된 적이 없다. 그래서 이것은 "OpenTofu 를 대체한다" 가 아니라 **운영을 세울 때 고를 수 있는 선택지를 미리 둔 것**이다 |
| **Apache Airflow** | **✅ 도입 (2026-09-12, 사용자 결정)** — 범위 밖을 뒤집었다 | Airflow **3.3.1** · **LocalExecutor** · 구성요소 넷(api-server 8080 · scheduler · dag-processor · triggerer). ★ **복귀 조건이 실제로 참이었다** — 이 행이 적어 둔 "의존 관계가 있는 배치"가 **이미 있었다**: 과금 CronJob 넷(`openmeter-dlq-replay` */15 · `openmeter-subscription-sync` 매시 · `openmeter-billing-advance-invoices` */5 · `openmeter-billing-collect-invoices` */5)이 순서가 있는데 **서로를 모른다.** 재처리가 실패해도 인보이스는 그대로 진행되고, 그 결과가 §8-90 이 실측한 **매출 누락**이다. 그래서 첫 DAG 이 `openmeter_billing_chain` 이다 — 데모가 아니라 그 사슬이다. ★★ **LocalExecutor 를 고른 것은 산술이다**(Gotcha 99) — Celery 면 Redis + 워커 파드가 늘어나는데 노드가 이미 84% 였다. 대가는 **태스크가 scheduler 파드 안에서 돈다**는 것이고, 그 limit(1536Mi)이 곧 동시 태스크 예산이다 | ★★★ **DAG 은 기본이 정지(paused)이고, 첫 태스크가 CronJob 넷이 suspend 인지 검사해 아니면 실패한다.** 둘을 함께 돌리면 인보이스를 두 번 진행하는데 청구는 소급 재해석이 불가능하다(Gotcha 15). 전환은 **CronJob 을 suspend 한 뒤 DAG 을 켜는** 순서로만 한다 — 그 전환 자체는 아직 하지 않았다(과금 경로를 건드리는 별도 결정이다). ★ 이미지에 직접 물어 확인한 것들(Gotcha 103): uid **50000 · gid 0**(이 레포 기본값 1000/1000 이 아니다), FAB provider·psycopg2·cncf.kubernetes 가 **이미 들어 있다**, `scheduler.standalone_dag_processor` 키는 3.3 에 **없다**(dag-processor 가 항상 독립이다), health 는 `/api/v2/monitor/health`. ★★ **인증을 기본값으로 두지 않았다** — 기본 `auth_manager` 는 SimpleAuthManager(`admin:admin`)라 그대로면 이 UI 가 또 하나의 무인증 화면이 된다(Temporal UI 가 그 상태다). FAB 로 바꿔 사용자가 메타데이터 DB 에 살고 비밀번호는 우리 Secret 에서 온다. **실측 결과(2026-09-12)**: 파드 **4/4 Running · restarts 0** · 메타데이터 테이블 **71개**(FAB 포함) · DAG 등록 1건 **import 오류 0** · `paused=true` · 인증이 실제로 강제된다(비인증 API **401** · 토큰 발급 **201** · 토큰으로 DAG 조회 성공). 노드 메모리 84% -> **88%**. ★★★ **켜는 데 결함 여섯을 밟았고 전부 "조용히 어긋나는" 부류였다** — 넷을 Gotcha 로 남겼다: **151** `_CMD` 는 셸을 거치지 않아 `$VAR` 가 리터럴로 들어간다(증상은 `password authentication failed` 인데 비밀번호는 멀쩡하다) · **152** exec 프로브의 `timeoutSeconds` 기본값 1초가 3.1초짜리 `airflow` CLI 를 자른다(검사는 rc=0 으로 **성공**하고 로그도 멀쩡한데 CrashLoop 다) · **153** ConfigMap 볼륨의 `..data` 링크를 Airflow 가 **재귀 루프**로 판정한다(dag-processor 만 죽어 "DAG 이 안 보인다" 로만 보인다) · 그리고 **113 재발** — 볼륨 타입을 바꾸자 SSA 가 이름으로 병합해 한 항목에 두 타입이 들어갔다(git 은 멀쩡하고 적용만 거부된다. 처방은 문서대로 **이름 바꾸기**였다). 나머지 둘은 배포 전에 막았다 — `/health` 는 라우트 목록에 보이는데 실제로는 **404**, 그리고 `pipefail`+`grep -q` 가 "있는데 없다"를 만든다(Gotcha 109). ★ 이 목록이 이 도입의 진짜 비용이다 — 매니페스트를 쓰는 시간보다 **어긋난 것을 찾는 시간**이 훨씬 길었다. ★★ **태스크 로그는 MinIO 에 보존한다(2026-09-12)** — `s3://airflow-logs/`. **root 자격을 쓰지 않는다**: LocalExecutor 는 DAG 코드를 scheduler 파드 안에서 돌리므로 그 파드가 든 자격은 DAG 작성자 누구나 쓴다 — root 면 아무 DAG 이나 `warehouse` 를 지운다. `minio-bootstrap` 이 `airflow` 사용자를 만들고 그 버킷만 허용하는 정책을 붙인다. 실측: 쓰기·읽기·목록 성공 · **`warehouse` 쓰기는 `AccessDenied`**(대조군) · 태스크 성공 실행의 로그 **10,457 B / 30줄**이 자동 업로드되고 API 가 `s3://airflow-logs/...` 에서 읽는다 · 실패한 태스크의 가드 메시지도 그 로그에서 읽힌다. ★★★ **그 과정에서 더 큰 결함이 드러났다 — 모든 태스크가 실패하고 있었다.** `core.execution_api_server_url` 의 기본값이 `{api.base_url}/execution/` 인데, port-forward UI 링크를 맞추려 `api.base_url` 을 `localhost:18080` 으로 둔 탓에 태스크 supervisor 가 없는 주소로 붙어 `Connection refused` 였다(Gotcha 154). 증상이 멀다 — DAG 은 그냥 failed 이고 로그는 `Pre Execute` 한 줄에서 끊긴다. **가르는 수단이 `platform_smoke`(로그만 남기고 반드시 성공하는 수동 전용 DAG)였다** — 실패하도록 설계된 DAG 으로는 "DAG 이 문제인가 실행 경로가 문제인가" 를 구분할 수 없다, 그리고 첫 DAG 이 local 의 OpenMeter CronJob 을 가리키므로 **dev/prod 에서는 의미가 없다**(paused 라 무해하다) ★★★ **2026-09-12 에 전환을 끝냈다.** 그때까지 DAG 은 정지였고 CronJob 넷이 돌고 있었다 — 즉 Airflow 는 도입만 되고 **일감이 없었다**. 지금은 반대다: git 이 넷을 `suspend: true` 로 박았고 DAG 이 기본으로 켜진 채 태어난다(`is_paused_upon_creation=False`). 전환 전에 전제를 실측했다 — scheduler 안에 `kubernetes` 36.0.3 이 있고, `airflow-scheduler` SA 가 cronjobs get · jobs create/get · pods list · pods/log get 을 전부 갖고 있으며, 임포트 오류 0건. ★ 켜는 순서가 중요하다: **CronJob 을 먼저 멈추고** DAG 을 켠다(반대로 하면 인보이스를 두 번 진행한다). ★★ 그리고 Airflow 3 은 **정지된 DAG 의 트리거를 큐에 넣고 돌리지 않는다** — "수동으로 한 번 성공시킨 뒤 켠다" 는 시험 계획이 성립하지 않아, 가드를 믿고 켠 뒤 관찰하는 순서로 바꿨다. 실측 결과: 수동분·스케줄분 모두 다섯 태스크 전부 success. ★ 되돌릴 조건 — DAG 이 과금을 멈추는 쪽으로 실패하면(태스크 실패가 아니라 아예 안 도는 경우) `airflow dags pause` 후 네 CronJob 의 `suspend` 를 git 에서 되돌린다. |

### 9-2. 유지하기로 한 것 — Jenkins

**결정: 유지한다 (2026-09-10).**

실측은 유지 근거가 아니었다:

```
plugins.txt 4줄 → 실제 설치 59개(전이 의존) · jobs 0개 · builds 0회 · 448Mi 예약
CI 는 GitLab CI + gitlab-runner 가 하고 있다(.gitlab-ci.yml 6스테이지)
```

그럼에도 남기는 이유는 **플러그인 생태계(1,800여 종)가 GitLab CI 에 없는
것**이기 때문이다. GitLab CI 의 모델은 "도구 = 컨테이너 이미지" 이고 그것으로
대부분이 풀리지만, 다음 넷은 풀리지 않는다:

- **이질적·레거시 빌드 대상** — Windows 에이전트, 임베디드/하드웨어 랩, 컨테이너 이야기가 없는 상용 도구
- **리치 UI** — 테스트 추이 그래프, 커버리지 플롯, 정적분석 집계(warnings-ng), 아티팩트 fingerprint 추적
- **multibranch 자동 발견** — 여러 SCM 을 한 서버가 훑는 것
- **shared library** — 여러 레포가 빌드 로직을 공유하는 것

★ **다음 사람에게**: "잡이 0개니 지우자" 는 **이미 검토했고 기각됐다.** 다시
꺼내지 말 것.

★★ 대신 확인할 것은 **JCasC 커버리지**다. 플러그인이 만드는 설정은
`$JENKINS_HOME` 안의 가변 XML 이라 **git 밖이고 ArgoCD 가 모른다.** 이 레포는
`CASC_JENKINS_CONFIG=/var/jenkins_casc/jenkins.yaml` + ConfigMap 으로 그것을
막아 두었다(`docker/jenkins/Dockerfile`). **플러그인을 늘릴 때 JCasC 로
선언되지 않는 설정이 생기면 그만큼 GitOps 밖으로 새어 나간다** — 파드를 다시
만들 때 무엇이 따라오는지 사람이 기억해야 하는 상태가 된다.

★ 그리고 플러그인은 **Jenkins 의 주된 취약점 표면**이다. 이 클러스터는 Trivy
Operator · Dependency-Track · Kyverno 가 상시로 도니, 플러그인을 늘리는 만큼
그 라인이 길어진다. 늘릴 때 그 비용을 함께 계산할 것.

### 9-3. 그래서 배포하는 것

위 결정을 빼고 남은 것 — **§6 Phase 3~4 의 실제 범위**다. (※ 이 문서에서 `§8-NNN` 은 LOCAL-DEPLOYMENT 문서의 절이다 — 이 절과 혼동하지 말 것.)

| 순서 | 컴포넌트 | 채우는 칸 | 선행 조건 |
|:---:|---|---|---|
| 1 | ✅ **Kafka Connect + Debezium** (2026-09-10 완료) | §D 의 CDC. ★ **Iceberg sink 는 빼졌다** — 바로 쓸 번들이 어디에도 없다(Gotcha 116) | ★★ 선행 조건을 **잘못 적어 두었던 칸이다.** "PostgreSQL wal_level" 은 엉뚱한 DB 를 겨눈 것이고, 실제 업무 데이터는 **MariaDB `cmmn`**(테이블 2개)에 있어 필요한 것은 `log_bin` 이었다. 완료됨 |
| 2 | ✅ **Camel K 2.11.0** (2026-09-10 완료 · 2026-09-11 빌드 경로 검증) | §C Micro Integrator | 기존 파이프라인은 옮기지 말 것(§6). 오퍼레이터는 install-operators.sh §9, IntegrationPlatform CR 은 `base/integration/` — 둘을 나눠 둔다. ★★ **빌드 경로를 실측으로 검증했다** — 최소 Integration 하나로 빌드 8분29초 → 레지스트리 push → 그 레지스트리에서 pull → 실행(`camel.exchanges.succeeded=1.0`)까지 밟고 지웠다. **그 과정에서 결함 셋을 찾아 고쳤다**: 빌드 timeout 기본 5분이 모자람(→20m) · jib 메모리 1536Mi 가 빠듯함(→2Gi) · **레지스트리에서 pull 이 아예 안 되던 것**(노드에 `registries.yaml` 이 없어 평문 HTTP 를 HTTPS 로 붙었다 — Gotcha 126). 지금 Integration 은 0건이고 오퍼레이터만 돈다(30Mi) |
| 3 | ✅ **Backstage 1.54.0** (2026-09-10 완료 · 2026-09-11 **Keycloak OIDC 전환**) | §G Choreo · 카탈로그 | PostgreSQL 재사용(스키마 분할). 카탈로그에 실측 엔티티 **10건**(User:portal·Group:platform 포함 — 사인인 리졸버가 짝지을 대상이다). ★★ **2026-09-11 에 guest → Keycloak OIDC 로 바꿨다.** 그러려면 자체 앱 빌드가 전제였고(`docker/backstage/`), 실제로 그것이 유일한 길이었다 — 예제 이미지는 백엔드·프런트 **양쪽이** guest 에 묶여 있다(Gotcha 135). 여전히 게이트웨이 경로 밖이다 — NetworkPolicy 로 ingress 를 전면 차단하고 port-forward 로만 접근한다. ★ 브라우저가 Keycloak 을 **클러스터 안 이름 그대로** 봐야 해서 hosts 한 줄이 필요하다(ACCESS.md §1-c · Gotcha 136) |
| 4 | ✅ **Gravitee APIM CE 4.12.19** (2026-09-10 배포 · **2026-09-12 경로 편입**) | §A API Manager | **Istio 앞 · Gravitee 뒤**로 공존시켰다 — `바깥 -> Istio Gateway -> Gravitee Gateway -> cmmn-api`. ★★★ 순서가 이 배치의 전부다: 모든 트래픽이 Istio 를 **먼저** 지나므로 계량 지점(액세스 로그 -> Kafka `api-usage` -> OpenMeter)이 움직이지 않는다. 거꾸로 두면 Gotcha 15 에 정면으로 걸린다. ★★ 겹치는 칸을 나눴다 — Istio 가 **계량·쓰로틀**(원천 `pricing-catalog.yaml`), Gravitee 가 **카탈로그·포털·구독/키·변환**. Gravitee 의 플랜·쿼터는 **켜지 않는다**: 켜면 "이 고객이 무엇을 샀는가" 의 원천이 둘이 된다(Gotcha 71). 실측: 토큰 없이 403 · 토큰과 함께 200(두 경로 다) · HTTPRoute `accepted=True`. ★★★ 그 과정에서 **Gravitee 에 관리자가 없다는 것이 드러났다** — 우리 ConfigMap 이 `gravitee.yml` 을 통째로 덮으며 `security:` 절이 빠져 사용자가 0명이었고, 그래서 며칠째 API 0 · 플랜 0 이었다(Gotcha 155). ★★ **2026-09-12 에 ADR-079 가 `Accepted` 로 닫혔다 — 쓰기로 결정했다.** 그래서 HTTPRoute 를 `overlays/local/gravitee-route/` 에서 **`base/service-mesh/ingress-gateway.yaml` 로 승격**했다(local 전용 배치는 "결정이 열려 있는 동안" 의 조치였다). ★★★ 결정 직후 **재현성 결함이 드러났다** — API 정의가 **Mongo 에만 1건, git 에는 0건**이었다. 그 상태로 클러스터를 다시 세우면 라우트는 남고 Gravitee 는 비어 `/managed` 만 404 가 된다(게이트웨이도 파드도 정상이라 원인이 멀다). 원천을 git 으로 옮겼다 — `local/gravitee-apis/*.json` + `local/gravitee-bootstrap.sh`(멱등). **말로 확인하지 않고 실제로 시험했다**: API 와 플랜을 지워 0건으로 만든 뒤 스크립트만 돌려 생성·게시·START 까지 복원되는 것을 보았고(2회차는 "이미 있다"), 곧바로 `/managed/api/menu` 가 다시 200 이었다. ★ 비용: 4파드가 **1,856 Mi** 를 예약한다(노드 89%). 되돌릴 조건은 §5 와 ADR-079 의 복귀 조건에 적었다 |

## 부록 A — Vault Enterprise → OpenBao + OSS

> 이 문서는 WSO2 로 시작했지만, **"상용 제품의 기능을 OSS 조합으로 채운다"**
> 라는 같은 작업이라 여기 함께 둔다. 배포 기록은 §8-80 이다.
>
> 아래 OpenBao 열은 **실측**이다(v2.4.1 컨테이너에 직접 물었다).

### A-1. OpenBao 가 이미 갖고 있는 것 — Vault 에서는 유료다

| Vault Enterprise 기능 | OpenBao 2.4.1 | 근거 |
|---|---|---|
| **Namespaces (멀티테넌시)** | ✅ **내장** | `bao namespace create` 성공 |
| Vault Agent · Proxy | ✅ (Vault 도 OSS) | — |

★ Namespaces 는 Vault Enterprise 를 사는 대표적인 이유 중 하나다. 그것이
OpenBao 에서는 무료다. B2B 테넌트별 시크릿 격리가 여기서 성립한다.

### A-2. OSS 조합으로 채우는 것

| Vault Enterprise 기능 | 대체 | 이 레포 |
|---|---|---|
| **Secrets Sync** (외부 매니저로 동기화) | ★ **External Secrets Operator** — 방향은 반대지만 목적(앱이 K8s Secret 으로 받는다)은 같다 | ✅ **동작 확인**(§8-81) |
| **Transform** (FPE · 토큰화 · 마스킹) | ★ **ShardingSphere** 의 암호화·마스킹 — **이미 배포돼 있다**(§8-75) · PostgreSQL `pgcrypto` | ✅ ShardingSphere |
| **Audit log filtering** | ★ audit device → **stdout** → 기존 컨테이너 로그 파이프라인 | ✅ **켜져 있음**(§8-81) |
| **Login MFA** | ★ **Keycloak MFA + OIDC auth method** 로 앞단에서 처리 | ✅ Keycloak 26.7.3 |
| **Sentinel 정책 (RGP/EGP)** | ⚠️ **OPA** 로 외부 인가 · 단순한 것은 OpenBao ACL 정책 | ❌ OPA 미도입 |
| **Control Groups** (M-of-N 승인) | ⚠️ 승인 워크플로를 밖에 둔다 — **midPoint** 또는 **Temporal** | ❌ |
| **Lease count quotas** | ⚠️ rate limit quota 는 OSS 에 있다. 앞단 제한은 **Envoy ratelimit** | ❌ |
| **자동 스냅샷** | ★ raft + CronJob → MinIO (6시간 주기 · 보존 30일) | ✅ **동작 확인**(§8-81) |
| **DR Replication** | ⚠️ 복제가 아니라 **백업·복구**로 바꾼다(위 스냅샷) | ✅ 스냅샷 있음 · **복구는 미검증** |
| **Performance Replication** | ⚠️ 읽기 확장은 **ESO 가 K8s Secret 으로 물질화**하는 것으로 상당 부분 대체된다 — 앱은 OpenBao 를 직접 때리지 않는다 | ✅ ESO 동작(§8-81) |

### A-3. OSS 로 못 채우는 것 — 3개

| 기능 | 왜 못 채우나 |
|---|---|
| **HSM auto-unseal · Seal Wrap** | 하드웨어 신뢰 근원이다. 소프트웨어 대체가 성립하지 않는다. 클라우드로 가면 KMS auto-unseal 이 답이고, **로컬에서는 사이드카가 최선이며 그것은 봉인을 약화시킨다**(§8-80) |
| **FIPS 140-2 검증 빌드** | 인증은 빌드에 붙는 것이라 포크가 물려받지 못한다. 규제 요건이 있으면 이 칸이 결정적이다 |
| **KMIP secrets engine** | KMIP 를 말하는 클라이언트가 있을 때만 문제다. **이 플랫폼에는 하나도 없다** — 아래 A-5 참조 |

### A-5. KMIP 서버가 왜 필요 없는가 — 실측 (2026-09-07)

"저장 시 암호화를 하려면 KMIP 서버가 필요한가" 는 자연스러운 질문이다.
**필요 없다.** 배포된 것 중 KMIP 를 쓸 컴포넌트가 하나도 없기 때문이다.

| 컴포넌트 | 실제 이미지 | 저장 시 암호화 경로 | KMIP |
|---|---|---|---|
| MongoDB | `percona/percona-server-mongodb:8.0.29-13` | **Vault 네이티브** 키 관리(`--vaultServerName` 등) | 불필요 |
| MinIO | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | SSE → **KES** → **Vault 네이티브** | 불필요 |
| MariaDB | `mariadb:12.3.3` (커뮤니티) | `file_key_management` · `aws_key_management` | **KMIP 는 Enterprise 전용** — 서버를 세워도 못 쓴다 |
| PostgreSQL | `postgres:18.6` (커뮤니티) | TDE 자체가 없다(pgcrypto 는 컬럼 단위) | 해당 없음 |
| ClickHouse · Elasticsearch | — | 설정 · 파일시스템 수준 | 해당 없음 |

★ **핵심은 이것이다** — envelope 암호화를 할 수 있는 둘(Percona MongoDB ·
MinIO)이 **모두 Vault 프로토콜을 네이티브로 말한다.** OpenBao 가 그것을 그대로
받으므로 KMIP 는 한 겹 더 얹는 것일 뿐 얻는 것이 없다.

KMIP 가 실제로 필요한 곳은 **자체 암호화 드라이브(SAN·NetApp·Pure) ·
VMware vSphere 암호화 · 백업 어플라이언스 · MongoDB Enterprise ·
MySQL Enterprise** 다. 이 플랫폼에는 하나도 없다.

> 저장 시 암호화 자체는 **아직 비어 있다** — 실측으로 설정된 컴포넌트가 0건이고
> G22 가 그것을 기록하고 있다. 다만 채우는 방법이 KMIP 가 아니다.
> 미룬 이유와 순서는 [LOCAL-DEPLOYMENT.md §9-9](LOCAL-DEPLOYMENT.md) 에 있다.

### A-4. 이 플랫폼에서의 결론

- **Namespaces 가 무료**라 멀티테넌시는 해결된다 — 외부 소비자가 생긴다는 전제에서 큰 항목이다
- **Transform 은 ShardingSphere 가 이미 그 자리에 있다** — 새로 도입할 것이 없다
- 진짜 남는 위험은 **HSM 부재로 인한 봉인 약화** 하나다. 로컬에서는 수용하고
  (§8-80 에 트레이드오프를 명시), 클라우드로 나갈 때 KMS auto-unseal 로 바꾼다
- **FIPS 가 요건이 되면 이 선택은 무효다** — 그때는 상용으로 돌아가야 한다

## 관련 문서

- [ADR-079](ADR-CANDIDATES.md) — 이 매핑의 결정 기록
- [docs/LOCAL-DEPLOYMENT.md](LOCAL-DEPLOYMENT.md) — §8-54~63(게이트웨이·계량) ·
  §8-79(레지스트리·스캔) · §9-2(과금) · §9-6(HA) · §11-4(메모리) · §19(프로파일)
- [docs/ARCHITECTURE.md](ARCHITECTURE.md) — 계층 구조와 갭
- [CLAUDE.md](../CLAUDE.md) — Gotcha 15·16(계량 지점) · 23(과금 토픽) · 29(미터 정의)
