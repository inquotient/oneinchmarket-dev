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
| `cmmn-api` | Spring Boot REST | **`openapi/cmmn-api.yaml`** — 2026-09-08 작성(§8-99) |
| `cmmn-api` → Kafka | 변경 이벤트 | **`schemas/dev.api.cmmn.multilanguage-refresh-value.avsc`** — 작성됨. `asyncapi/cmmn-api.yaml` 과 menu 쪽 스키마는 **아직 없다** |
| `admin` | 프론트엔드(포트 3000) | 없음. REST 계약 주체가 아니다 |

Kafka 토픽 — **이 목록은 틀렸다**(2026-09-08 정정, §8-99).
소비 그룹은 `dev.api.cmmn.menu` · `dev.api.cmmn.multilanguage` 를 읽지만,
**게시하는 토픽에는 `-refresh` 접미가 붙는다.** 앱이 낸 예외가
그렇게 말했다 — `Subject 'dev.api.cmmn.multilanguage-refresh-value' not found`.

```
dev.api.cmmn.menu                    (소비)
dev.api.cmmn.multilanguage           (소비)
dev.api.cmmn.multilanguage-refresh   (게시)  -> subject ...-refresh-value
dev.api.cmmn.menu-refresh            (추정 — menu POST 는 201 로 성공해
                                       예외가 없었고, 그래서 스키마를 받지
                                       못했다. **확인 전에 쓰지 말 것**)
```

★★ 지금 `POST /api/multiLanguage` 는 **DB 에는 쓰고 500 을 낸다** —
위 subject 가 레지스트리에 없기 때문이다. `AUTO_REGISTER_SCHEMAS=false`
이므로 앱은 스스로 등록하지 않는다. **게시 훅이 돌면 해소된다** — 그것이
이 디렉터리가 존재하는 이유다. (2026-11-03 실측: 게시 뒤 subject 가 등록됐다.
아래 **게시** 절)

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
contracts/ 수정 ─▶ python3 local/render-contracts.py   (요청 본문 ConfigMap 을 다시 만든다 — 함께 커밋)
                 ─▶ CI validate: Spectral 린트
                 ─▶ ArgoCD 동기화 ─▶ PostSync 훅 apicurio-contracts 가 게시
                                      (레지스트리 규칙이 여기서 한 번 더 막는다)
                 ─▶ 앱은 레지스트리에서 읽어 쓴다 (auto-register 꺼짐)
```

## 게시 — 클러스터 안 PostSync 훅 (2026-11-03)

예전에는 GitLab CI 의 `publish-contracts` 잡이 게시했는데, 베어메탈 재구축(2026-10-04)
뒤로 클러스터 안 GitLab 에 레포가 없어 **한 번도 돌 수 없었다** — 레지스트리의 아티팩트가
0개였다. ArgoCD 가 읽는 git(GitHub) 하나가 원천이 되도록 게시를 클러스터로 옮겼다.

```
contracts/*                     원천
local/render-contracts.py       요청 본문(JSON)을 미리 만든다 — 이미지에 python·jq 가 없다
  -> kubernetes/base/bootstrap/apicurio-contracts-configmap.yaml   (생성물, `--check` 게이트)
kubernetes/base/bootstrap/apicurio-contracts.yaml                  (PostSync Job)
```

- **계약을 고치면 생성기를 돌려 함께 커밋할 것.** 생성물을 안 고치면 레지스트리는 옛 내용
  그대로다. `local/render-contracts.py --check` 가 뒤처짐을 1 로 알린다.
- **멱등이다** — ccompat 은 같은 스키마에 기존 id 를 돌려주고, v3 는
  `ifExists=FIND_OR_CREATE_VERSION` 이다. 실측: 두 번 돌려도 네 계약 모두 버전 1.
- **PostSync 라 실패해도 플랫폼 동기화의 wave 를 세우지 않는다.** 규칙에 걸린 계약은
  동기화를 Failed 로 보이게 하고 Job 로그에 레지스트리의 사유를 남긴다.
- JSON 스키마(`*.json`)는 ccompat 에 `schemaType: JSON` 으로, Avro(`*.avsc`)는
  `AVRO` 로 올린다 — 예전 CI 잡은 타입을 보내지 않아 JSON 스키마도 Avro 로 해석됐을 것이다.
