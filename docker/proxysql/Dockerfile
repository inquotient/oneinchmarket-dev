# ProxySQL 4.0.11 — 공식 컨테이너 이미지가 없어 직접 굽는다 (§8-76)
#
# ★★ 왜 자체 빌드인가
#   ProxySQL 은 **패키지와 컨테이너 이미지의 릴리스 주기가 다르다.**
#   실측(2026-09-07):
#     · GitHub 최신 릴리스        : v4.0.11
#     · Docker Hub proxysql/proxysql : 3.0.11 이 최신 (전체 300개 태그에 4.x 없음)
#     · ghcr.io/sysown/proxysql   : 없음
#     · v4.0.11 릴리스 자산       : rpm · deb · tar.gz + 서명/해시 뿐. Docker 언급 0건
#   4.x 는 GenAI 플러그인 · MCP 엔드포인트 · RAG/벡터 도구가 들어간 기능 계열이고
#   3.x 가 안정 계열로 보인다(4.0.11 바이너리 스스로
#   `Latest ProxySQL version available: 3.0.11-...` 을 보고한다).
#
# ★ 이 이미지는 유지보수 짐이다. Ranger 플러그인 3종과 같은 성격이라
#   업스트림이 4.x 컨테이너를 내기 시작하면 **이 디렉터리를 지울 것.**
#
# ★★ MCP 는 켜지 않는다. `mcp-enabled` 기본값이 비활성이고, 노출 범위와
#   베어러 토큰 보관이 미결이다. 켜려면 §8-76 의 "남는 것" 을 먼저 볼 것 —
#   DB 프록시가 processlist·쿼리 통계를 AI 에 노출하는 것은 데이터 노출면이다.

ARG PROXYSQL_VERSION=4.0.11
# ★ 릴리스가 게시한 값이다. 올릴 때 **반드시 함께 갱신할 것.**
#   https://github.com/sysown/proxysql/releases/download/v<VER>/proxysql-<VER>-linux-amd64.tar.gz.sha256
ARG PROXYSQL_SHA256=635f0eb0385c61b205562b9226aa64abb0a3ebd0286c66748ffe4f88a0aa65cb

FROM docker.io/library/debian:13.6-slim AS fetch
ARG PROXYSQL_VERSION
ARG PROXYSQL_SHA256
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    curl -sSL --fail -o /tmp/proxysql.tgz \
      "https://github.com/sysown/proxysql/releases/download/v${PROXYSQL_VERSION}/proxysql-${PROXYSQL_VERSION}-linux-amd64.tar.gz"; \
    echo "${PROXYSQL_SHA256}  /tmp/proxysql.tgz" | sha256sum -c -; \
    mkdir -p /opt; \
    tar xzf /tmp/proxysql.tgz -C /opt; \
    mv "/opt/proxysql-${PROXYSQL_VERSION}-linux-amd64" /opt/proxysql; \
    rm -f /tmp/proxysql.tgz; \
    rm -rf /opt/proxysql/systemd /opt/proxysql/etc/logrotate.d
# ★★ 위 `curl` 에 `--max-time` 을 붙이지 말 것. 이 파일은 95 MB 라 타임아웃에
#   걸리면 **잘린 채로 저장되고, 그래도 tar 는 풀리고 바이너리는 실행된다.**
#   실측으로 29.7 MB·40.5 MB 짜리 부분 파일이 두 번 나왔고 둘 다 "동작하는 것처럼"
#   보였다. 위의 sha256sum -c 만이 그것을 잡는다(Gotcha 12).

FROM docker.io/library/debian:13.6-slim
LABEL org.opencontainers.image.title="proxysql" \
      org.opencontainers.image.version="4.0.11" \
      org.opencontainers.image.description="ProxySQL 4.0.11 - upstream publishes no container image for 4.x. See docs/LOCAL-DEPLOYMENT.md 8-76." \
      org.opencontainers.image.licenses="GPL-3.0"

# ★ 의존은 추측하지 않고 `ldd` 로 확인한 것만 넣는다 — 미해결은
#   libgnutls.so.30 하나였다. ca-certificates 는 MCP/GenAI 가 외부로 나갈 때
#   필요하지만 지금은 꺼져 있으므로 넣지 않는다(넣으면 노출면이 늘어난다).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libgnutls30; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1000 proxysql; \
    useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin proxysql; \
    mkdir -p /var/lib/proxysql; \
    chown -R 1000:1000 /var/lib/proxysql

COPY --from=fetch --chown=1000:1000 /opt/proxysql /opt/proxysql

USER 1000
# 6033 클라이언트 트래픽 · 6032 관리(파드 안에서만 연다)
EXPOSE 6033
# ★ `bin/proxysql` 은 LD_LIBRARY_PATH 를 ../lib 로 잡아 주는 래퍼다.
#   proxysql.bin 을 직접 부르면 libproxysql 계열을 찾지 못한다.
CMD ["/opt/proxysql/bin/proxysql", "-f", "--idle-threads", "-D", "/var/lib/proxysql"]
