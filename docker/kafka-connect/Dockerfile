# ─────────────────────────────────────────────────────────────────────────
# oneinch/kafka-connect — Kafka Connect + Debezium MariaDB 커넥터.
#
# 왜 커스텀 이미지인가:
#   상류에는 `quay.io/debezium/connect` 라는 기성품이 있고 그것을 쓰면 이
#   파일이 필요 없다. 쓰지 않는 이유는 크기와 표면이다 — 그 이미지는
#   **715 MiB(압축)** 에 커넥터를 15종 담고 있는데 여기서 쓰는 것은 하나다.
#   이 클러스터는 Trivy Operator·Dependency-Track 이 상시로 도니 쓰지 않는
#   커넥터 14종은 취약점 라인만 늘린다.
#
#   반대로 이 이미지는 **브로커와 같은 베이스**(apache/kafka:4.3.1) 위에
#   플러그인 11 MiB 를 얹는다. 베이스는 이미 노드 containerd 에 있으므로
#   실제로 추가되는 것은 그 11 MiB 뿐이다.
#
# ★ 버전이 브로커와 같아야 하는 이유:
#   Connect 워커는 Kafka 클라이언트다. 다른 배포판을 쓰면 브로커와 클라이언트
#   버전이 갈리고, Kafka 4.x 는 아주 낡은 프로토콜을 이미 버렸다(KIP-896).
#   **`kubernetes/base/messaging/kafka/kafka-statefulset.yaml` 의 image 를
#   올릴 때 이 FROM 도 함께 올릴 것.** 어긋나면 조용히 호환성 문제가 된다.
#
# ★★ 런타임에 플러그인을 내려받지 않는다 — 그것은 SEC-512(런타임 외부 의존)다.
#   빌드 시점에 굽고, **체크섬을 못 박아** 내용물이 바뀌면 빌드가 실패하게
#   한다(Gotcha 45: 버전 태그·원격 아티팩트는 불변이 아니다).
# ─────────────────────────────────────────────────────────────────────────

# ── 1단계: 플러그인을 받아 검증하고 푼다 ──────────────────────────────────
# 베이스 이미지에 curl·tar 가 있다고 가정하지 않기 위해 단계를 나눈다.
FROM docker.io/library/alpine:3.22 AS fetch

ARG DEBEZIUM_VERSION=3.6.2.Final
# 2026-09-10 에 실제로 받아 계산한 값이다. 상류가 아티팩트를 바꾸면
# 여기서 빌드가 **실패해야 한다** — 조용히 다른 것을 굽는 것보다 낫다.
ARG DEBEZIUM_MARIADB_SHA256=407a4a8d5c8715e025008e885937413591e63b5d49a6bb0e2d6ca284e0672166

RUN apk add --no-cache curl tar

RUN set -eux; \
    f="debezium-connector-mariadb-${DEBEZIUM_VERSION}-plugin.tar.gz"; \
    url="https://repo1.maven.org/maven2/io/debezium/debezium-connector-mariadb/${DEBEZIUM_VERSION}/${f}"; \
    mkdir -p /plugins; \
    curl -fsSL --retry 3 -o "/tmp/${f}" "$url"; \
    echo "${DEBEZIUM_MARIADB_SHA256}  /tmp/${f}" | sha256sum -c -; \
    tar xzf "/tmp/${f}" -C /plugins; \
    test -d /plugins/debezium-connector-mariadb; \
    ls /plugins/debezium-connector-mariadb/*.jar >/dev/null

# ── 2단계: 브로커와 같은 베이스 위에 얹는다 ───────────────────────────────
FROM docker.io/apache/kafka:4.3.1

# plugin.path 가 가리키는 곳. 베이스에는 이 디렉터리가 없다.
# uid/gid 1000 은 이 이미지의 appuser 다 — Connect 워커가 그 사용자로 돈다.
COPY --from=fetch --chown=1000:1000 /plugins /opt/kafka/plugins

USER 1000
