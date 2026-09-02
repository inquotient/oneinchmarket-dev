# 애플리케이션 연동 가이드

> 작성 기준일 2026-09-03 · 브랜치 `local` · 네임스페이스 `local`
>
> **이 문서는 실제로 호출해 확인한 것만 적는다.** 확인하지 못한 것은 "미검증"으로
> 표시한다. 다른 문서는 목표를 함께 기술하지만 여기는 아니다 — 개발자가 이 문서를
> 보고 코드를 쓰기 때문이다.

이 플랫폼 위에 애플리케이션을 올릴 때 **무엇에 어떻게 붙는지**를 정리한다.
운영 기록은 [LOCAL-DEPLOYMENT.md](./LOCAL-DEPLOYMENT.md) 8절을 참조하라.

---

## 1. 요약 — 붙을 수 있는 곳

`app.kubernetes.io/component: application` 라벨을 가진 파드가 **NetworkPolicy 를
통과해 도달할 수 있는 대상**이다. 라벨이 없으면 전부 막힌다(5절).

| 용도 | 주소 | 확인 |
|---|---|:-:|
| 트레이스·메트릭·로그(OTLP) | `otel-agent:4318` (HTTP) · `otel-agent:4317` (gRPC) | 확인 |
| 오류 추적 | `glitchtip:8000` | 확인 |
| 프로파일링 | `pyroscope:4040` | 확인 |
| Kafka (네이티브) | `kafka-headless:9092` | 확인 |
| Kafka (HTTP) | `kafka-bridge:8080` | 확인 |
| 스키마 레지스트리 | `apicurio-registry-headless:8080/apis/ccompat/v7` | 확인 |
| Redis | `redis-headless:6379` | 확인 |
| MongoDB | `mongodb-headless:27017` | 확인 |
| Spark Connect | `spark-connect:15002` | 확인 |
| HiveServer2 (JDBC) | `hive-server-headless:10000` | 확인 |
| MariaDB · PostgreSQL | **앱 이름으로 허용된다** — 5절 참조 | — |

---

## 2. 관측성 — OTel 로 한 번에 보낸다

애플리케이션은 Tempo·Loki·Prometheus 에 직접 붙지 않는다. OTLP 로 에이전트에 보내면
에이전트가 게이트웨이로, 게이트웨이가 각 백엔드로 나눈다.

```
앱 --OTLP--> otel-agent (DaemonSet) --> otel-gateway --+--> Tempo       (트레이스)
                                                       +--> Loki        (로그)
                                                       +--> Prometheus  (메트릭)
```

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: http://otel-agent:4318          # HTTP. gRPC 는 4317
  - name: OTEL_EXPORTER_OTLP_PROTOCOL
    value: http/protobuf
  - name: OTEL_SERVICE_NAME
    value: cmmn-api                        # Tempo·Loki 에서 이 이름으로 찾는다
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: service.namespace=oneinchmarket,deployment.environment=local
```

검증한 것:

```
POST http://otel-agent:4318/v1/traces -> 200
POST http://otel-agent:4318/v1/logs   -> 200
```

### 왜 게이트웨이가 아니라 에이전트인가

게이트웨이는 **에이전트에서 오는 트래픽만** 받는다. 그리고 `k8sattributes` 프로세서가
에이전트 쪽에 있어 소스 IP 로 보낸 파드를 식별해 `k8s.pod.name` 등을 붙인다.
게이트웨이로 직접 보내면 소스가 에이전트 IP 로 보여 그 정보가 사라진다.

`otel-agent` Service 는 `internalTrafficPolicy: Local` 이라 **같은 노드의 에이전트로만**
간다. 노드가 늘어도 이 주소 그대로 쓰면 된다.

> 이 Service 는 2026-09-03 에 만들었다. 그전까지 에이전트는 hostPort·hostNetwork·
> Service 가 모두 없어 **애플리케이션이 주소를 지정할 방법 자체가 없었다.**
> NetworkPolicy 는 네임스페이스 전체를 열어 두었으므로 "열려 있는데 갈 수 없는"
> 상태였다. hostPort 로도 되지 않는다 — 이 클러스터의 Cilium 구성에서는 바인드되지
> 않아 노드에 리슨이 잡히지 않는다.

### 메트릭을 Prometheus 로 직접 노출하려면

OTLP 대신(또는 함께) 스크레이프 방식도 쓸 수 있다. 옵트인이다.

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: "/actuator/prometheus"
```

> 어노테이션은 **포트를 하나만** 지정할 수 있다. 관리 포트가 따로 있으면 그쪽을 적는다.

---

## 3. 오류 추적 — GlitchTip (Sentry SDK 호환)

**Sentry SDK 를 그대로 쓴다.** DSN 만 바꾸면 된다 — GlitchTip 이 Sentry 프로토콜을
받는다(ADR-036 ⓓ).

```yaml
env:
  - name: SENTRY_DSN
    valueFrom:
      secretKeyRef: { name: <앱>-secret, key: sentry-dsn }
  - name: SENTRY_ENVIRONMENT
    value: local
```

DSN 은 GlitchTip UI 에서 프로젝트를 만들면 발급된다.

```bash
kubectl -n local port-forward deploy/glitchtip-web 8000:8000
# http://localhost:8000
# 조직 생성은 잠겨 있다(ENABLE_ORGANIZATION_CREATION=false). 첫 조직·사용자는
# 관리자가 만든다.
```

DSN 의 호스트는 **클러스터 내부 주소**여야 한다 — `http://<key>@glitchtip:8000/<project>`.
브라우저에서 직접 보내는 프런트엔드는 외부 진입점이 필요하다(6절 제약).

---

## 4. 프로파일링 — Pyroscope

`pyroscope:4040` 이 수신 지점이다. **다만 지금은 애플리케이션을 프로파일링할 수단이
정해지지 않았다**(TODO-51).

| 방법 | 상태 |
|---|---|
| Pyroscope Java 에이전트를 이미지에 넣는다 | **불가** — 앱 Dockerfile 이 레포에 없다(G9) |
| Grafana Alloy eBPF 프로파일링 | **미검증** — 앱 변경은 필요 없으나 WSL2 에서 eBPF 가 될지 확인 안 됨 |

새 애플리케이션을 **직접 빌드한다면** 에이전트를 넣는 쪽이 확실하다.

```dockerfile
ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/pyroscope.jar"
ENV PYROSCOPE_SERVER_ADDRESS=http://pyroscope:4040
ENV PYROSCOPE_APPLICATION_NAME=cmmn-api
```

> 현재 Pyroscope 가 보는 것은 **자기 자신뿐**이다. 대시보드가 비어 있다면 고장이
> 아니라 아직 아무도 보내지 않아서다.

---

## 5. 새 워크로드가 지켜야 할 것

이걸 빠뜨리면 **조용히 실패한다.** 증상이 원인에서 멀다.

### 라벨 — 없으면 네트워크가 막힌다

```yaml
labels:
  app.kubernetes.io/name: <서비스명>
  app.kubernetes.io/component: application   # NetworkPolicy 가 이걸 본다
  app.kubernetes.io/part-of: oneinchmarket
  app.kubernetes.io/managed-by: kustomize
```

`component` 가 틀리면 1절의 대상에 **하나도 도달하지 못한다.** 증상은
`Connection timed out` 이지 `authentication failed` 가 아니라 인증 문제로 오진하기 쉽다.

> 오버레이가 `environment: local` 을 자동으로 붙인다. 직접 `kubectl apply` 하는 임시
> 파드에는 **직접 넣어야 한다** — NetworkPolicy 셀렉터에 그 라벨이 들어 있다.

### securityContext — prod 에서 Kyverno 가 차단한다

```yaml
spec:
  securityContext:                  # 파드 레벨. 컨테이너가 상속한다
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
```

### 프로브 — startupProbe 를 빠뜨리지 말 것

`livenessProbe` 는 컨테이너 시작과 동시에 돌기 시작한다. JVM 처럼 기동이 느린 앱은
준비되기 전에 SIGTERM 을 맞고 `exit 143` 으로 죽는다 — 이 레포에서 여러 번 겪었다.

```yaml
startupProbe:                        # 기동 예산. 이게 끝나야 liveness 가 시작된다
  httpGet: { path: /actuator/health, port: http }
  failureThreshold: 30
  periodSeconds: 10
```

### 리소스 — limits 를 requests 아래로 내리지 말 것

`kustomize build` 도 `kubectl apply` 도 통과하고 **파드 생성만 실패**한다.
`kubectl get pods` 에는 아무것도 안 나온다 — CrashLoop 도 Pending 도 아니고 그냥 없다.

**JVM 이면 힙을 명시할 것.** 기본값은 컨테이너 limit 의 50% 이고, `-Xmx` 를 limit 과
같게 두면 메타스페이스·스레드 스택이 힙 밖이라 커널이 죽인다.

### DB 접근은 앱 이름으로 허용된다

`allow-postgresql-access`·`allow-mariadb-access` 는 `component` 가 아니라 **앱 이름**을
나열한다. 새 앱이 DB 를 쓰면 그 정책에 셀렉터를 추가해야 한다.

---

## 6. 지금은 안 되는 것

| | 상태 |
|---|---|
| **외부 진입점** | 없다. Ingress·Gateway·NodePort·LoadBalancer 객체 0개. 접근은 전부 `port-forward` 다. 브라우저에서 직접 호출하는 프런트엔드 계측(세션 리플레이 등)이 여기서 막힌다 |
| **앱 이미지 빌드** | `v1/admin/Dockerfile`·`v1/cmmn-api/Dockerfile` 이 없다(G9). CI 의 build 잡도 이 경로를 참조해 동작하지 않는다. **에이전트를 이미지에 넣는 모든 방법이 여기 묶여 있다** |
| **앱 프로파일링** | TODO-51. 4절 참조 |
| **시크릿** | SOPS 가 미작동이라 로컬은 `local/create-secrets.sh` 가 런타임에 만든다. dev/prod 는 미해결(G2·G3) |

---

## 7. API 계약 — 계약 우선 (ADR-067)

`contracts/` 의 파일이 원천이고 구현이 거기 맞춘다. 그 반대가 아니다.

```
contracts/openapi/     REST 계약
contracts/asyncapi/    이벤트 계약
contracts/schemas/     Avro·JSON 스키마
```

- CI 가 `.spectral.yaml` 로 린트하고 Apicurio 에 게시한다
- Apicurio 전역 규칙: `VALIDITY=FULL` · `COMPATIBILITY=BACKWARD`
- **런타임 자동 등록은 끈다** — 계약이 원천이므로 앱이 스키마를 만들지 않는다

```yaml
env:
  - name: SPRING_KAFKA_PROPERTIES_SCHEMA_REGISTRY_URL
    value: http://apicurio-registry-headless:8080/apis/ccompat/v7
  - name: SPRING_KAFKA_PROPERTIES_AUTO_REGISTER_SCHEMAS
    value: "false"
  - name: SPRING_KAFKA_PROPERTIES_USE_LATEST_VERSION
    value: "true"
```

> `contracts/` 는 아직 비어 있다. 기구는 다 섰고 계약 파일 작성만 남았다.

---

## 8. 실제 예시 — cmmn-api 의 연결 설정

지금 도는 워크로드에서 그대로 뽑은 값이다.

```
DB_HOST=jdbc:mariadb://mariadb-headless:3306/cmmn
SPRING_DATA_REDIS_HOST=redis-headless
SPRING_DATA_REDIS_PORT=6379
SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka-headless:9092
SPRING_KAFKA_CONSUMER_BOOTSTRAP_SERVERS=kafka-headless:9092
SPRING_KAFKA_PRODUCER_BOOTSTRAP_SERVERS=kafka-headless:9092
SPRING_KAFKA_PROPERTIES_SCHEMA_REGISTRY_URL=http://apicurio-registry-headless:8080/apis/ccompat/v7
```

> **`SPRING_KAFKA_BOOTSTRAP_SERVERS` 만 주면 안 된다.** `application-kafka.yml` 이
> consumer·producer 를 개별 지정하면 **더 구체적인 키가 이긴다.** 상위 키가 조용히
> 무시된다 — 이 앱에서 실제로 겪었다. 세 개를 모두 지정한 이유다.

---

## 9. Kafka — 두 가지 경로

| | 언제 |
|---|---|
| `kafka-headless:9092` | 네이티브 클라이언트. 컨슈머 그룹·정확한 오프셋 제어가 필요할 때 |
| `kafka-bridge:8080` | HTTP 만 쓸 수 있을 때. 외부 클라이언트·간단한 produce |

브리지 사용 예(실제로 왕복을 확인한 호출이다):

```bash
# produce
curl -X POST http://kafka-bridge:8080/topics/<topic> \
  -H 'Content-Type: application/vnd.kafka.json.v2+json' \
  -d '{"records":[{"key":"k1","value":{"hello":"world"}}]}'

# consume — 컨슈머 생성 -> 구독 -> 폴
curl -X POST http://kafka-bridge:8080/consumers/<group> \
  -H 'Content-Type: application/vnd.kafka.v2+json' \
  -d '{"name":"c1","format":"json","auto.offset.reset":"earliest"}'
```

> **브리지에는 자체 인증이 없다**(SEC-206). 도달 가능한 누구나 produce·consume 한다.
> NetworkPolicy 가 사실상 유일한 통제이므로 **외부에 직접 노출하지 말 것.**
> 컨슈머 세션이 파드에 고정되므로 레플리카를 늘리면 세션 어피니티가 필요하다.

---

## 관련 문서

- [LOCAL-DEPLOYMENT.md](./LOCAL-DEPLOYMENT.md) — 실배포 기록. 여기 나온 제약의 근거
- [ARCHITECTURE.md](./ARCHITECTURE.md) — 계층 구조, 갭(G1~G41), TODO
- [SECURITY.md](./SECURITY.md) — SEC-xxx, 워크로드 보안 커버리지
- [ADR-CANDIDATES.md](./ADR-CANDIDATES.md) — ADR-036(GlitchTip)·ADR-067(계약 우선)
- `contracts/README.md` — 계약 작성 규약
