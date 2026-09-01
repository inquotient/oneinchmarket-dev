# contracts/ — API 계약 원천

**계약 우선(contract-first)이다.** 여기 있는 파일이 원천이고, 구현이 여기에 맞춘다.
그 반대가 아니다.

> 결정 근거와 경위는 `docs/ADR-CANDIDATES.md` 의 **ADR-067** 을 볼 것.

## 배치

```
contracts/
  openapi/     REST API 계약        *.yaml
  asyncapi/    이벤트 채널 계약      *.yaml
  schemas/     메시지 페이로드 스키마 *.avsc · *.json
```

## 이 클러스터의 계약 표면

확인된 것은 둘뿐이다(2026-09-01).

| 주체 | 성격 | 계약 |
|---|---|---|
| `cmmn-api` | Spring Boot REST | `openapi/cmmn-api.yaml` — **아직 없다** |
| `cmmn-api` ↔ Kafka | 토픽 2개 | `asyncapi/cmmn-api.yaml` + `schemas/*.avsc` — **아직 없다** |
| `admin` | 프론트엔드(포트 3000) | 없음. REST 계약 주체가 아니다 |

Kafka 토픽:

```
dev.api.cmmn.menu
dev.api.cmmn.multilanguage
```

## 명명 — ccompat subject 와 맞춘다

`cmmn-api` 는 Apicurio 의 **Confluent 호환 엔드포인트**를 쓴다.

```
SPRING_KAFKA_PROPERTIES_SCHEMA_REGISTRY_URL
  = http://apicurio-registry-headless:8080/apis/ccompat/v7
```

ccompat 의 기본 subject 전략은 `TopicNameStrategy` 이므로 subject 는 다음과 같다.

```
<토픽>-value      예) dev.api.cmmn.menu-value
<토픽>-key        (키에 스키마를 쓸 때만)
```

**스키마 파일 이름을 subject 와 같게 둔다.** 게시 잡이 파일명을 그대로 subject 로 쓴다.

```
schemas/dev.api.cmmn.menu-value.avsc
schemas/dev.api.cmmn.multilanguage-value.avsc
```

OpenAPI/AsyncAPI 는 ccompat 이 아니라 Registry v3 API 로 올린다.

```
group      = default
artifactId = 파일명(확장자 제외)      예) cmmn-api
```

## ★ auto.register.schemas 는 꺼야 한다

Confluent serdes 의 기본값은 `auto.register.schemas=true` 다. 그대로 두면
**애플리케이션이 처음 메시지를 보낼 때 스키마를 스스로 등록한다.** 그것은 코드 우선이며
계약 우선과 정면으로 충돌한다.

`cmmn-api` 매니페스트에서 껐다.

```
SPRING_KAFKA_PROPERTIES_AUTO_REGISTER_SCHEMAS = false
SPRING_KAFKA_PROPERTIES_USE_LATEST_VERSION    = true
```

이제 앱은 **등록된 최신 스키마를 찾아 쓰고, 없으면 실패한다.** 계약이 먼저 있어야 한다는
뜻이고, 그것이 의도다.

## 게이트

레지스트리 전역 규칙이 서 있다(`bootstrap/apicurio-rules.yaml`).

```
VALIDITY      = FULL       내용이 해당 타입으로 파싱되는가
COMPATIBILITY = BACKWARD   새 버전이 직전 버전과 하위 호환인가
```

CI 는 `validate` 단계에서 Spectral 로 스타일을 본다(`.spectral.yaml`).
레지스트리 규칙이 구문·호환을, Spectral 이 스타일·거버넌스를 본다 — 역할이 다르다.

## 흐름

```
contracts/ 수정 ─▶ CI validate: Spectral 린트
                 ─▶ CI deploy:   Apicurio 게시 (규칙이 여기서 한 번 더 막는다)
                 ─▶ 앱은 레지스트리에서 읽어 쓴다 (auto-register 꺼짐)
```
