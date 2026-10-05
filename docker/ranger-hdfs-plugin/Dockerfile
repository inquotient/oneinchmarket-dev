# Ranger 2.9.0 HDFS 플러그인 — Jersey 2 로 포팅해 빌드한다 (§8-68)
#
# ★ 왜 이 이미지가 존재하는가
#   Hadoop 3.5 는 Jersey 1 구현을 걷어내고 org.glassfish.jersey 2.46 으로
#   이관했다. Ranger 2.9 의 REST 클라이언트는 com.sun.jersey(Jersey 1)를
#   쓰므로 NameNode 가 기동하지 못한다:
#     NoClassDefFoundError: com/sun/jersey/api/client/ClientHandlerException
#
#   Jersey 1 jar 를 런타임에 보충하는 우회는 **실패한다**(실측 2회):
#     · jsr311-api 까지 넣으면 javax.ws.rs 가 두 벌이 되어 LinkageError
#     · 구현만 넣으면 기동은 하지만 Client.create() 의 provider 초기화가 깨져
#       정책 버전이 -1 에 머문다. 그런데 add-hadoop-authorization 폴백 때문에
#       HDFS 는 멀쩡히 돌아 **인가만 조용히 사라진다** — 가장 나쁜 실패다.
#
#   근본 수정은 Ranger 쪽 Jersey 2 이관이고 upstream 이 이미 했다. 다만 그것은
#   미출시 master(3.0.0-SNAPSHOT)에만 있다. 그래서 여기서 **필요한 만큼만**
#   2.9.0 으로 백포트한다.
#
# ★ 왜 master 를 통째로 가져오지 않는가
#   master 의 RangerAdminRESTClient·PasswordUtils 를 함께 가져오면
#   ServiceGdsInfo(898줄, GDS 기능)·RangerSupportedCryptoAlgo·JwtProvider 등
#   3.0 전용 코드가 연쇄로 딸려 온다(실측). 그래서 **좁은 경로**를 쓴다:
#     · RangerRESTClient  -> master 판 (진짜 재작성이 필요한 유일한 파일)
#     · 나머지 4개        -> 2.9.0 원본 + Jersey1→2 기계적 치환
#
# ★ 빌드된 jar 를 커밋하지 않는다
#   포팅 로직이 이 Dockerfile 안에 있어야 다음 사람이 무엇을 바꿨는지 본다.
#   바이너리를 커밋하면 그 근거가 사라진다.
#
# ★ 한시적이다
#   Ranger 3.0.0 이 릴리스되면 이 이미지는 필요 없어진다. 그때 지울 것.

ARG RANGER_VERSION=2.9.0

# ── 1단계 : 포팅 + 빌드 ────────────────────────────────────────────
FROM docker.io/library/maven:3.9-eclipse-temurin-8 AS build
ARG RANGER_VERSION
WORKDIR /src

RUN curl -sSL -o s.tgz \
      "https://archive.apache.org/dist/ranger/${RANGER_VERSION}/apache-ranger-${RANGER_VERSION}.tar.gz" \
 && tar xzf s.tgz && rm s.tgz

WORKDIR /src/apache-ranger-2.9.0

# master 에서 최소한만 가져온다. RangerRESTClient 는 Jersey 2 재작성이 필요한
# 유일한 파일이고, 나머지는 그것이 참조하는 것이다.
#
# ★★★ 2026-10-05: `master` 를 **커밋 SHA 로 고정했다.** 그 전까지는 브랜치
#   이름으로 받고 있어서 **우리가 아무것도 바꾸지 않아도 빌드가 깨졌다** —
#   실제로 깨졌다: 상류가 `plugin/authn/JwtProvider.java` 를 다른 모듈로
#   옮기고 이름까지 바꿨다(`authz-remote/.../authn/RangerRemoteJwtProvider.java`).
#   받던 URL 이 404 가 되고 `curl --fail` 이 빌드를 중단시켰다. 로그 끝은
#   `curl: (22) ... error: 404` 한 줄이고, 그 위의 `+ curl ...` 줄을 봐야
#   어느 파일인지 알 수 있다. Gotcha 45·60 과 같은 부류다 —
#   **참조 뒤의 내용물이 움직인다.**
# ★ 그 파일은 **이제 필요 없다** — master 의 RangerRESTClient 가 더 이상
#   JwtProvider 를 import 하지 않는다(실측: import 목록에 없다). 상류가 JWT
#   취득을 `ranger.common.auth.jwt.retriever.class` 로 분리했다.
# ★★ SHA 를 올릴 때는 **그 커밋의 RangerRESTClient import 목록을 먼저 읽을 것** —
#   참조가 다시 늘면 여기에 파일을 더해야 한다.
RUN set -eux; \
    AC=agents-common/src/main/java/org/apache/ranger; \
    RANGER_SHA=b7f823187f09711a45ce33db609105460b75f3c5; \
    RAW="https://raw.githubusercontent.com/apache/ranger/${RANGER_SHA}/agents-common/src/main/java/org/apache/ranger"; \
    for P in plugin/util/RangerRESTClient.java \
             plugin/util/RangerJersey2ClientBuilder.java; do \
      curl -sSL --fail -o "$AC/$P" "$RAW/$P"; \
    done; \
    for P in plugin/util/RangerRESTClient.java \
             plugin/util/RangerJersey2ClientBuilder.java; do \
      grep -q "package org.apache.ranger.plugin.util;" "$AC/$P" \
        || { echo "[guard] $P 내용이 기대와 다르다 — 상류가 또 움직였다" >&2; exit 1; }; \
    done

# 2.9.0 원본 4개는 유지하고 Jersey 1 사용처만 기계적으로 옮긴다.
#   · ClientResponse            -> javax.ws.rs.core.Response
#   · getEntity(X.class)        -> readEntity(X.class)
#   · getCookies()              -> JAX-RS 2 에서는 Map 이라 .values() 가 필요하다
#     (이것이 마지막 컴파일 오류였다: "for-each not applicable to expression type")
#   · com.sun.jersey Base64     -> commons-codec (encode/decode 가 byte[] 라 짝이 맞다)
RUN set -eux; \
    AC=agents-common/src/main/java/org/apache/ranger; \
    for F in "$AC/admin/client/RangerAdminRESTClient.java" \
             "$AC/admin/client/datatype/RESTResponse.java" \
             "$AC/plugin/contextenricher/RangerUserStoreRefresher.java"; do \
      sed -i \
        -e 's|import com.sun.jersey.api.client.ClientResponse;|import javax.ws.rs.core.Response;|' \
        -e 's|ClientResponse\.Status|Response.Status|g' \
        -e 's|\bClientResponse\b|Response|g' \
        -e 's|\.getEntity(\([A-Za-z]\)|.readEntity(\1|g' \
        -e 's|for (NewCookie \([a-zA-Z]*\) : \([a-zA-Z]*\)\.getCookies())|for (NewCookie \1 : \2.getCookies().values())|g' \
        "$F"; \
    done; \
    sed -i \
      -e 's|import com.sun.jersey.core.util.Base64;|import org.apache.commons.codec.binary.Base64;|' \
      -e 's|Base64\.encode(|Base64.encodeBase64(|g' \
      -e 's|Base64\.decode(|Base64.decodeBase64(|g' \
      "$AC/plugin/util/PasswordUtils.java"; \
    ! grep -rn 'com\.sun\.jersey' agents-common/src/main/java

# Jersey 2 를 컴파일 의존으로 넣는다. 런타임에는 Hadoop 3.5 가 같은 2.46 을
# 제공하므로 이 jar 들을 배포물에 넣을 필요는 없다.
RUN set -eux; \
    printf '%s\n' \
      '    <dependency><groupId>org.glassfish.jersey.core</groupId><artifactId>jersey-client</artifactId><version>2.46</version></dependency>' \
      '    <dependency><groupId>org.glassfish.jersey.core</groupId><artifactId>jersey-common</artifactId><version>2.46</version></dependency>' \
      '    <dependency><groupId>org.glassfish.jersey.inject</groupId><artifactId>jersey-hk2</artifactId><version>2.46</version></dependency>' \
      '    <dependency><groupId>jakarta.ws.rs</groupId><artifactId>jakarta.ws.rs-api</artifactId><version>2.1.6</version></dependency>' \
      > /tmp/deps.xml; \
    awk 'NR==FNR{d=d $0 ORS; next} /<dependencies>/ && !done {print; printf "%s", d; done=1; next} {print}' \
        /tmp/deps.xml agents-common/pom.xml > /tmp/pom.new; \
    mv /tmp/pom.new agents-common/pom.xml; \
    grep -q jersey-client agents-common/pom.xml

# ★ sortpom 은 pom 의 알파벳 정렬을 강제하는 스타일 게이트다. 위 삽입이 그것을
#   어기므로 끈다 — 코드 검증과 무관하다.
RUN mvn -B -pl hdfs-agent -am \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true -Dsortpom.skip=true \
        package

# ── 2단계 : 업스트림 배포물에 우리 jar 두 개를 얹는다 ──────────────
# 나머지 jar 는 업스트림 그대로다. 바꾼 것은 REST 경로뿐임을 분명히 한다.
RUN set -eux; \
    curl -sSL -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/hdfs/ranger-2.9.0-hdfs-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-hdfs-plugin/lib/. /plugin/; \
    cp agents-common/target/ranger-plugins-common-2.9.0.jar /plugin/ranger-hdfs-plugin-impl/; \
    cp hdfs-agent/target/ranger-hdfs-plugin-2.9.0.jar       /plugin/ranger-hdfs-plugin-impl/

# ── 3단계 : 옮길 것만 담은 얇은 이미지 ─────────────────────────────
# initContainer 가 /plugin 을 emptyDir 로 복사한다. 셸이 필요하므로 busybox.
FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-hdfs-plugin (Jersey 2 backport)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 HDFS plugin, REST client ported to Jersey 2 for Hadoop 3.5. See docs/LOCAL-DEPLOYMENT.md 8-68." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /plugin /plugin
