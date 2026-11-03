# Ranger 2.9.0 Kafka 플러그인 — Kafka 4.3.1 · Jersey 2 로 빌드한다 (2026-11-03)
#
# ★ 왜 이 이미지가 존재하는가
#   ① REST 클라이언트가 Jersey 1(com.sun.jersey)이다 — docker/ranger-hdfs-plugin 과
#      같은 백포트(Jersey 2)를 쓴다.
#   ② 배포물은 kafka-clients 3.9.1 로 컴파일됐다. Kafka 4.3 브로커에서 돌리려면
#      4.3.1 로 다시 컴파일한다. 플러그인이 쓰는 것은 kafka-clients 의 공개 API
#      (org.apache.kafka.server.authorizer.Authorizer 등)뿐이다.
#   ③ ★ Kafka 4.x 는 Scala 2.12 아티팩트를 내지 않는다 — pom 의 test 의존성
#      kafka_${scala.binary.version} 이 2.12 라 해석 단계에서 실패한다. 2.13 으로 준다.
#
# ★ Kafka 4.3 쪽 전제(이미지에서 확인한 것):
#   · JRE 21 · libs/ 에 **Jersey 3**(jakarta.ws.rs 3.1)만 있다. 플러그인의 Jersey 2
#     클라이언트는 javax.ws.rs 라 패키지가 달라 충돌하지 않지만, **부모에 없으므로
#     impl 디렉터리에 Jersey 2 를 함께 넣어야 한다**(Knox 는 dep/ 에 Jersey 2 가 있어
#     필요 없었다 — 같은 플러그인 계열이라도 처방이 다르다, Gotcha 41 ③).
#   · ★★ impl 에 kafka-clients 를 남기지 말 것 — 자식 우선 클래스로더가 그것을 먼저
#     집으면 Authorizer 인터페이스가 두 벌이 되어 shim 이 위임할 때 LinkageError 다.
#     브로커의 kafka-clients 를 부모에서 쓴다.
#
# ★ 빌드된 jar 를 커밋하지 않는다. 한시적이다 — Ranger 3.0.0 이 나오면 지울 것.

# ── JDK 두 개 (docker/ranger-knox-plugin 과 같은 이유) ──
#   agents-common 은 Nashorn 때문에 JDK 17 에서 컴파일되지 않고, kafka-clients 4.x 는
#   JDK 8 이 읽지 못한다(class 55+).
FROM docker.io/library/maven:3.9-eclipse-temurin-8 AS jdk8
WORKDIR /src
RUN curl -sSL --fail -o s.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/apache-ranger-2.9.0.tar.gz" \
 && tar xzf s.tgz && rm s.tgz
WORKDIR /src/apache-ranger-2.9.0

# ── ① Jersey 2 백포트 — docker/ranger-hdfs-plugin · ranger-knox-plugin 과 **같은 SHA·같은 치환** ──
#   셋이 어긋나면 같은 Ranger 2.9 가 플러그인마다 다른 REST 클라이언트를 갖는다(Gotcha 117).
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

# ── ② JDK 17 — kafka-clients 4.3.1 대상으로 컴파일 ─────────────────
FROM docker.io/library/maven:3.9-eclipse-temurin-17 AS build
COPY --from=jdk8 /root/.m2 /root/.m2
COPY --from=jdk8 /src /src
WORKDIR /src/apache-ranger-2.9.0
RUN mvn -B -pl plugin-kafka,ranger-kafka-plugin-shim \
        -Dkafka.version=4.3.1 -Dscala.binary.version=2.13 \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true \
        package \
 && mvn -B -q -pl agents-common \
        dependency:copy-dependencies -DincludeScope=runtime -DoutputDirectory=/deps \
        -DincludeGroupIds=org.glassfish.jersey.core,org.glassfish.jersey.inject,org.glassfish.hk2,org.glassfish.hk2.external,jakarta.ws.rs,jakarta.inject,jakarta.annotation,org.javassist
RUN mvn -B -q -pl agents-common dependency:copy \
        -Dartifact=org.glassfish.jersey.core:jersey-server:2.47 -DoutputDirectory=/deps \
 && mvn -B -q -pl agents-common dependency:copy \
        -Dartifact=jakarta.validation:jakarta.validation-api:2.0.2 -DoutputDirectory=/deps
# ★★★ jersey-server 2.47 은 **쓰려고가 아니라 가리려고** 넣는다(2026-11-03 실측).
#   Jersey 2 와 3 은 JAX-RS API 만 javax->jakarta 로 바뀌었고 **org.glassfish.jersey.*
#   클래스 이름은 똑같다.** Jersey 2 클라이언트는 기동할 때 META-INF/services 의
#   AutoDiscoverable·ForcedAutoDiscoverable 를 클래스패스 **전체**(부모 포함)에서 찾는데,
#   Kafka 의 libs/jersey-server-3.1 이 WadlAutoDiscoverable·MonitoringAutodiscoverable·
#   ServerFiltersAutoDiscoverable 를 등록해 둔다. 자식 쪽에 같은 이름이 없으면 부모의
#   Jersey 3 판이 로드되고 Jersey 2 인터페이스로 캐스트하다
#     ClassCastException: ...WadlAutoDiscoverable cannot be cast to ...AutoDiscoverable
#   로 **정책 다운로드가 매번 실패한다** — 정책 0건 = 전부 거부라 브로커가 자기 컨트롤러에
#   등록하지 못하고(CLUSTER_AUTHORIZATION_FAILED) 죽었다. 자식에 jersey-server 2.47 을
#   두면 자식 우선 클래스로더가 그 이름들을 Jersey 2 판으로 푼다. jersey-common·jersey-hk2
#   가 등록하는 이름(LoggingFeatureAutoDiscoverable·Hk2InjectionManagerFactory)은 이미
#   2.47 이 자식에 있어 문제가 없었다.
#   ★ 자동 탐색을 끄는 속성(jersey.config.disableAutoDiscovery)으로는 안 된다 —
#     Forced 쪽은 그래도 로드된다.
# ★ Jersey 2 는 **agents-common** 에서 가져온다 — 그 pom 에 2.47 을 직접 선언했으므로
#   (①) 최근접 규칙으로 2.47 이 고정된다. plugin-kafka 에서 copy-dependencies 를 하면
#   전이 의존성이 섞여 jersey-client 2.35 · jersey-common 2.47 이 나란히 들어오고
#   Jersey 1(1.19.4)까지 다시 딸려 왔다(실측 2026-11-03). 그룹으로 걸러 다른 것은 받지 않는다.

# ── ③ 업스트림 배포물에 우리 jar 를 얹고 Jersey 1·kafka-clients 를 빼고 Jersey 2 를 넣는다 ──
RUN set -eux; \
    curl -sSL --fail -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/kafka/ranger-2.9.0-kafka-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-kafka-plugin/lib/. /plugin/; \
    IMPL=/plugin/ranger-kafka-plugin-impl; \
    test -d "$IMPL"; \
    cp agents-common/target/ranger-plugins-common-2.9.0.jar          "$IMPL/"; \
    cp plugin-kafka/target/ranger-kafka-plugin-2.9.0.jar               "$IMPL/"; \
    cp ranger-kafka-plugin-shim/target/ranger-kafka-plugin-shim-2.9.0.jar /plugin/; \
    rm -f "$IMPL"/jersey-client-1.*.jar "$IMPL"/jersey-core-1.*.jar "$IMPL"/jersey-bundle-1.*.jar \
          "$IMPL"/jsr311-api-*.jar "$IMPL"/kafka-clients-*.jar /plugin/kafka-clients-*.jar; \
    rm -f "$IMPL"/jersey-client-2.*.jar "$IMPL"/jersey-common-2.*.jar "$IMPL"/jersey-hk2-2.*.jar; \
    cp /deps/*.jar "$IMPL/"; \
    ls /deps; \
    # ★ 가드를 `! cmd` 로 쓰지 말 것 — set -e 는 부정한 명령의 실패를 무시해 그 줄이
    #   **아무것도 막지 않는다**(실측: Jersey 1 이 남았는데 통과했다). if 로 끝낸다.
    if ls "$IMPL" /plugin | grep -qE '^(jersey-client-1|jersey-core-1|jersey-bundle-1|kafka-clients-)'; then \
      echo "[guard] Jersey 1 또는 kafka-clients 가 남았다" >&2; ls "$IMPL" >&2; exit 1; \
    fi; \
    n=$(ls "$IMPL" | grep -cE '^jersey-(client|common|hk2|server)-2\.47\.jar$'); \
    if [ "$n" -ne 4 ]; then echo "[guard] Jersey 2.47 네 개가 아니다: $n" >&2; ls "$IMPL" >&2; exit 1; fi; \
    if [ "$(ls "$IMPL" | grep -cE '^jersey-')" -ne 4 ]; then echo "[guard] Jersey 버전이 섞였다" >&2; ls "$IMPL" | grep jersey >&2; exit 1; fi; \
    echo "== impl"; ls "$IMPL"

FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-kafka-plugin (Kafka 4.3 / Jersey 2)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 Kafka plugin rebuilt against kafka-clients 4.3.1 with the Jersey 2 REST client backport." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /plugin /plugin
