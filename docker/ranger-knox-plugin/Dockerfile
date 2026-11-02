# Ranger 2.9.0 Knox 플러그인 — Knox 3.0.0 · Jersey 2 로 빌드한다 (2026-11-03)
#
# ★ 왜 이 이미지가 존재하는가
#   Ranger 2.9 배포물의 Knox 플러그인은 그대로 쓸 수 없다. 두 가지 이유가 있다.
#   ① REST 클라이언트가 Jersey 1(com.sun.jersey)이다. 배포물에는 jersey-client
#      1.19.4 만 들어 있고 그것이 기대는 jersey-core 1 은 없다. Knox 3.0 의
#      dep/ 에도 없다(Jersey 2.47 만 있다). docker/ranger-hdfs-plugin 과 같은
#      문제이고 같은 백포트를 쓴다 — 설명은 그 파일 머리말.
#   ② 배포물은 Knox 2.0.0 으로 컴파일됐다. Knox 3.0.0 은 **Java 17 로 컴파일**
#      돼 있어(class file version 61, 실측) 그것을 대상으로 다시 빌드하려면
#      JDK 17 이 필요하다. Maven Central 에 gateway-spi 3.0.0 이 있다(실측).
#
# ★ Knox 3.0 쪽 전제(이미지에서 확인한 것):
#   · 서블릿은 여전히 javax(javax.servlet-api 4.0.1 · Jetty ee8) — 필터가
#     jakarta 로 옮길 필요가 없다.
#   · Jersey 2.47 이 dep/ 에 있어 플러그인의 Jersey 2 클라이언트가 그것을 쓴다.
#     그래서 우리 배포물에서는 jersey-client-1.19.4 를 **뺀다** — 남겨 두면
#     child-first 클래스로더가 그것을 먼저 집는다.
#   · 클래스패스는 `../ext/*.jar` 다(bin/gateway.cfg). 셋째 단계의 /plugin 을
#     initContainer 가 ext/ 로 복사한다. ext/ 에는 원래 README 둘뿐이다.
#
# ★ 빌드된 jar 를 커밋하지 않는다(ranger-hdfs-plugin 과 같은 이유).
# ★ 한시적이다 — Ranger 3.0.0 이 Knox 3·Jersey 2 로 나오면 지울 것.

# ── ★★ JDK 두 개가 필요하다(docker/ranger-hbase-plugin 과 같은 이유) ──
#   Knox 3.0 은 Java 17 바이트코드라 JDK 8 이 읽지 못하고, agents-common 은
#   Nashorn(jdk.nashorn.*) 때문에 JDK 17 에서 컴파일되지 않는다 — 실측:
#     NashornScriptEngineCreator.java:[26,32] package jdk.nashorn.api.scripting does not exist
#   (Hive 판 머리말은 "JDK 21 에서 통과했다" 고 적었지만 여기서는 재현되지 않았다.)
#   그래서 1단계(JDK 8)가 agents-common 을 install 하고 2단계(JDK 17)가
#   knox-agent·shim 만 `-am` 없이 컴파일한다.
FROM docker.io/library/maven:3.9-eclipse-temurin-8 AS jdk8
WORKDIR /src
RUN curl -sSL --fail -o s.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/apache-ranger-2.9.0.tar.gz" \
 && tar xzf s.tgz && rm s.tgz
WORKDIR /src/apache-ranger-2.9.0

# ── ① Jersey 2 백포트 — docker/ranger-hdfs-plugin 과 **같은 SHA·같은 치환** ──
#   둘이 어긋나면 같은 Ranger 2.9 가 플러그인마다 다른 REST 클라이언트를 갖는다.
#   SHA 를 올릴 때는 두 파일을 함께 올릴 것(Gotcha 117).
RUN set -eux; \
    AC=agents-common/src/main/java/org/apache/ranger; \
    RANGER_SHA=b7f823187f09711a45ce33db609105460b75f3c5; \
    RAW="https://raw.githubusercontent.com/apache/ranger/${RANGER_SHA}/agents-common/src/main/java/org/apache/ranger"; \
    for P in plugin/util/RangerRESTClient.java \
             plugin/util/RangerJersey2ClientBuilder.java; do \
      curl -sSL --fail -o "$AC/$P" "$RAW/$P"; \
      grep -q "package org.apache.ranger.plugin.util;" "$AC/$P" \
        || { echo "[guard] $P 내용이 기대와 다르다" >&2; exit 1; }; \
    done; \
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
    ! grep -rn 'com\.sun\.jersey' agents-common/src/main/java; \
    printf '%s\n' \
      '    <dependency><groupId>org.glassfish.jersey.core</groupId><artifactId>jersey-client</artifactId><version>2.47</version></dependency>' \
      '    <dependency><groupId>org.glassfish.jersey.core</groupId><artifactId>jersey-common</artifactId><version>2.47</version></dependency>' \
      '    <dependency><groupId>org.glassfish.jersey.inject</groupId><artifactId>jersey-hk2</artifactId><version>2.47</version></dependency>' \
      '    <dependency><groupId>jakarta.ws.rs</groupId><artifactId>jakarta.ws.rs-api</artifactId><version>2.1.6</version></dependency>' \
      > /tmp/deps.xml; \
    awk 'NR==FNR{d=d $0 ORS; next} /<dependencies>/ && !done {print; printf "%s", d; done=1; next} {print}' \
        /tmp/deps.xml agents-common/pom.xml > /tmp/pom.new; \
    mv /tmp/pom.new agents-common/pom.xml; \
    grep -q jersey-client agents-common/pom.xml

RUN mvn -B -q install -pl agents-common,ranger-plugin-classloader -am \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true

# ── ② JDK 17 — Knox 3.0.0 대상으로 컴파일 ─────────────────────────
#   knox-agent 는 Knox 쪽에서 gateway-spi·gateway-server 만 쓴다.
FROM docker.io/library/maven:3.9-eclipse-temurin-17 AS build
COPY --from=jdk8 /root/.m2 /root/.m2
COPY --from=jdk8 /src /src
WORKDIR /src/apache-ranger-2.9.0
RUN mvn -B -pl knox-agent,ranger-knox-plugin-shim \
        -Dknox.gateway.version=3.0.0 \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true \
        package

# ── ③ 업스트림 배포물에 우리 jar 를 얹고 Jersey 1 을 뺀다 ──────────
RUN set -eux; \
    curl -sSL --fail -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/knox/ranger-2.9.0-knox-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-knox-plugin/lib/. /plugin/; \
    cp agents-common/target/ranger-plugins-common-2.9.0.jar      /plugin/ranger-knox-plugin-impl/; \
    cp knox-agent/target/ranger-knox-plugin-2.9.0.jar             /plugin/ranger-knox-plugin-impl/; \
    cp ranger-knox-plugin-shim/target/ranger-knox-plugin-shim-2.9.0.jar /plugin/; \
    rm -f /plugin/ranger-knox-plugin-impl/jersey-client-1.*.jar; \
    ! ls /plugin/ranger-knox-plugin-impl | grep -q '^jersey-client-1'

FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-knox-plugin (Knox 3 / Jersey 2)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 Knox plugin rebuilt against Knox 3.0.0 with the Jersey 2 REST client backport." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /plugin /plugin
