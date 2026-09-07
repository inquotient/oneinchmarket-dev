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
| **SCIM 2.0 프로비저닝** | ⚠️ Keycloak SCIM 확장(커뮤니티) · **midPoint**(IGA 로 상위 대체) | ❌ **공백** |
| XACML 엔타이틀먼트 (PDP) | ★ **OpenFGA**(ReBAC) / **OPA**(Rego) / Cerbos / Permify / SpiceDB | ❌ |
| 조직 · B2B 멀티테넌시 | ★ **Keycloak Organizations**(26.x GA) / Zitadel | ✅ 버전 충족 |
| 계정 셀프서비스(가입·복구·잠금) | ★ Keycloak | ✅ |
| **ID 운영 승인 워크플로** | ★ **midPoint** / Temporal | ❌ |
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
| 스트리밍 SQL · CEP (패턴·시퀀스·윈도우·조인) | ★ **Apache Flink** (Flink SQL + Flink CEP) / RisingWave / Materialize / ksqlDB | ❌ (Spark 는 배치 ✅) |
| CDC | ★ **Debezium** / Flink CDC | ❌ |
| 스트림 알림 | ★ Flink → Alertmanager | Alertmanager ✅ |

### E. WSO2 Message Broker

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| JMS · AMQP · MQTT · STOMP 큐/토픽 | ★ **ActiveMQ Artemis** / RabbitMQ / EMQX(MQTT) | Kafka ✅ 이나 **JMS 아님** |

> 레거시 JMS 클라이언트가 없다면 이 칸은 비워 두어도 된다. Kafka 로 충분하다.

### F. WSO2 Business Process (BPMN)

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| BPMN 2.0 · 휴먼 태스크 · 승인 | ★ **Flowable** / Camunda 7(Apache 2.0) / **Temporal**(코드 우선) | ❌ |

### G. WSO2 Choreo (iPaaS · 내부 개발자 플랫폼)

| WSO2 기능 | OSS 후보 | 이 레포 |
|---|---|---|
| 빌드·배포·관측을 묶은 셀프서비스 플랫폼 | ★ **Backstage** + **ArgoCD** + GitLab CI + Kubernetes | ❌ 셋 다 없음 |

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
스트리밍·CEP           Apache Flink         + Debezium (CDC)
BPM                    Flowable  또는  Temporal
JMS 가 필요하면        ActiveMQ Artemis
과금                   OpenMeter (미완)     (부족하면 Lago)
GitOps·멀티환경        ArgoCD
카탈로그·개발자 포털   Backstage
시크릿                 OpenBao + External Secrets
WAF                    Coraza + CRS         ※ SafeLine 과 역할 정리 필요
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

### 판단

- **소비자가 셀프서비스로 구독·키 발급을 해야 한다면** → Gravitee CE.
  단 §6 의 Phase 0 을 먼저 끝낼 것.
- **그렇지 않다면** → Istio + `envoyproxy/ratelimit` + 기존 Redis 로 쓰로틀만 채운다.
  추가 메모리 100Mi 안팎이고 소비자 식별자는 이미 있다 — Keycloak 토큰의 클레임을
  ratelimit descriptor 키로 쓰면 요금제별 쿼터가 성립한다.

## 6. 도입 순서

### Phase 0 — 전제 (지금 깨져 있다)

1. **시크릿** — OpenBao + External Secrets (ADR-024). 모든 것이 여기 얹힌다.
   현재 Vault 는 `0/1`(봉인)이고 시크릿 관리는 미작동이다(CLAUDE.md).
2. **ArgoCD** — Multi-environment · API Promotion 두 칸과 ADR-068 머지 관문이
   전부 여기 달려 있다. **현재 CRD 0 · 파드 0 · 네임스페이스 없음.**
3. **메모리 여유** — 프로파일 분리(§19 ③). §11-4 가 이미 `필요 56.6 vs 가용 47.6` 이다.

### Phase 1 — API Manager 완성 (절반은 이미 있다)

4. ~~**쓰로틀링**~~ — **끝났다**(§8-89). `envoyproxy/ratelimit` + 기존 Redis.
   descriptor 키는 토큰의 tenant 클레임이고, 실측으로 650회 버스트에서
   **600번째부터 429** 를 받았다. 요금제별 쿼터는 ConfigMap 의 `descriptors` 에
   테넌트를 명시해 준다 — 다만 **요금제와 한도를 잇는 자동화는 아직 없다**
5. **Apicurio 채우기** — `contracts/openapi/` 작성. 지금 **0건**이라
   Publisher · Compatibility · Governance **세 칸이 동시에 껍데기**다
6. **요금제 정의**(§9-2) — 제품 추가가 아니라 OpenMeter 설정
7. **Gravitee CE** — 소비자 셀프서비스가 필요하다는 전제라면 여기. §5 를 볼 것

### Phase 2 — Identity Server 완성

8. **OpenFGA 또는 OPA** — 엔타이틀먼트. **둘 다가 아니라 하나**
9. **midPoint** — SCIM · ID 운영 워크플로

### Phase 3 — Integrator · Streaming

10. **Camel K** — Micro Integrator 대체 (기존 파이프라인은 옮기지 말 것)
11. **Flink + Debezium** — Streaming Integrator(Siddhi) 대체
12. **Flowable 또는 Temporal** — BPM

### Phase 4

13. **Backstage** — Choreo · 카탈로그. 카탈로그에 넣을 저장소가 생긴 뒤에

## 7. 메모리 산정 — **추정이다, 실측이 아니다**

아래는 업스트림 기본값과 통상적인 JVM/Go 런타임 크기에서 나온 **추정치**다.
이 레포의 다른 수치(§11-4 · §18-3)는 실측이므로 **섞어 쓰지 말 것.**
도입할 때마다 `kubectl top pod` 로 실측해 이 표를 교체할 것.

| 컴포넌트 | 추정 | 비고 |
|---|---|---|
| Gravitee CE (gateway·mgmt API·console·portal) | 2.0 ~ 2.5 GiB | JVM 3종. MongoDB·ES 는 재사용 |
| Flink (JobManager + TaskManager) | 2.0 ~ 3.0 GiB | |
| midPoint | 1.0 ~ 1.5 GiB | JVM |
| Debezium (Kafka Connect) | 1.0 GiB | |
| ArgoCD (4 컴포넌트) | 0.5 ~ 1.0 GiB | |
| Backstage | 0.7 ~ 1.0 GiB | |
| ActiveMQ Artemis | 0.5 ~ 1.0 GiB | JMS 가 필요할 때만 |
| Flowable / Temporal | 0.5 ~ 0.8 GiB | |
| Camel K (operator + 통합 몇 개) | 0.5 ~ 1.0 GiB | 통합 개수에 비례 |
| OpenBao + External Secrets | 0.4 GiB | |
| OpenFGA | 0.15 ~ 0.25 GiB | Go |
| Envoy ratelimit | 0.1 GiB | Redis 재사용 |
| Coraza | 0.0 ~ 0.25 GiB | Envoy Wasm 이면 무시 가능 |
| **합계** | **8 ~ 14 GiB** | |

**Phase 0 의 프로파일 분리가 선행되지 않으면 들어갈 자리가 없다.** 이것은
취향이 아니라 산술이다.

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
