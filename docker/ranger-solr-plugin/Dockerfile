# Ranger 2.9.0 Solr 플러그인을 Solr 10.0.0 대상으로 이식한 이미지 (2026-11-03)
#
# ★ 왜: Ranger Service Manager 에 Solr 를 실제로 강제되는 서비스(oim-solr)로 두려면 Solr 안에
#   플러그인(RangerSolrAuthorizer)이 있어야 한다 — 플러그인 없는 저장소는 통제되는 것처럼
#   보이기만 한다(Gotcha 39). Ranger 2.9 의 Solr 플러그인은 Solr 8.11.3 대상이고 이 클러스터는
#   Solr 10.0.0(Jakarta 서블릿 · Lucene 10.3)이다.
# ★ 이식 내용(solr10-patch.py — 각 수정은 바뀐 것을 세고 아니면 실패한다):
#   · javax.servlet -> jakarta.servlet
#   · Solr 9/10 에서 없어진 권한·작업 이름(autoscaling · metrics history · MIGRATESTATEFORMAT ·
#     INVOKE · DELETEALIAS · FORCEPREPAREFORLEADERSHIP) case 제거 — 대응할 요청이 없어 공백이 아니다
#   · init(NamedList) -> init(NamedList<?>) · CoveringQuery -> lucene sandbox · shim 의 StringUtils
#   · SolrJ·Lucene·서블릿을 provided 로 명시(Solr 가 런타임에 준다)
#   · services/solr(Ranger Admin 쪽 리소스 조회 클라이언트)는 뺀다 — Admin 이 자기 판을 든다
#   · 감사 목적지 모듈(dest-hdfs·dest-solr) 의존을 뺀다 — Solr 플러그인 자신의 감사는 끈다
#     (감사를 Solr 에 쓰는 요청이 다시 감사되는 순환)
#   · ★★ 단독(standalone) 모드의 구멍을 막는다 — Solr 는 단독 모드에서 컬렉션 목록을 비워 두고,
#     원본은 그 목록을 돌며 검사해서 READ/UPDATE 가 **검사 없이 허용**됐다(실측: analyst 의
#     select·update 200). KnoxUserAuthPlugin 이 경로에서 뽑은 코어 이름(X-Oim-Solr-Core,
#     클라이언트가 보낸 값은 버린다)으로 검사하고, 없으면 "*" 로 검사한다(fail-closed).
#   · Hadoop 클라이언트 3.4.2 -> 3.5.0 — Solr 10 의 JVM 이 Java 25 라 getSubject 가 막힌다(아래 ③)
# ★ KnoxUserAuthPlugin(src/) — Knox 가 붙인 user.name 을 Solr 의 사용자로 받는 인증 플러그인.
#   신뢰 전제는 그 소스 머리말(solr-authz.yaml 이 Solr 에 닿는 신원을 좁힌다).
# ★ 두 단계 빌드인 이유는 다른 Ranger 플러그인 이미지와 같다 — agents-common 은 JDK 8,
#   Solr 10 은 Java 21 바이트코드라 JDK 21.

# ── ① JDK 8 — agents-common 을 Jersey 2 로 포팅해 설치한다(Kafka·Knox 이미지와 같다) ──
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

# ── ② JDK 21 — Solr 10.0.0 대상으로 컴파일 ─────────────────────────
FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
RUN apt-get -qq update \
 && apt-get -qq install -y --no-install-recommends python3 >/dev/null \
 && rm -rf /var/lib/apt/lists/*
COPY --from=jdk8 /root/.m2 /root/.m2
COPY --from=jdk8 /src /src
COPY solr10-patch.py solr10-pom.py /tmp/
COPY src /tmp/oim-src
WORKDIR /src/apache-ranger-2.9.0

# 서블릿 패키지 이름 · Admin 쪽 조회 클라이언트 제거 · 감사 목적지 의존 제거 · Solr 10 API 수정.
RUN set -eux; \
    PS=plugin-solr; SH=ranger-solr-plugin-shim; \
    grep -rl 'javax\.servlet' $PS/src/main/java $SH/src/main/java \
      | xargs -r sed -i 's/javax\.servlet/jakarta.servlet/g'; \
    if grep -rq 'javax\.servlet' $PS/src/main/java $SH/src/main/java; then \
      echo "[guard] javax.servlet 이 남았다" >&2; exit 1; \
    fi; \
    rm -rf $PS/src/main/java/org/apache/ranger/services/solr/client \
           $PS/src/main/java/org/apache/ranger/services/solr/RangerServiceSolr.java; \
    python3 /tmp/solr10-pom.py; \
    python3 /tmp/solr10-patch.py /src/apache-ranger-2.9.0

RUN mvn -B -q -pl plugin-solr,ranger-solr-plugin-shim \
        -Dsolr.version=10.0.0 -Dmaven.compiler.release=21 \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true -Dpmd.skip=true \
        package

# Jersey 2 런타임. jersey-server 2.47 은 쓰려고가 아니라 **가리려고** 넣는다 — Solr 10 도
#   Jersey 3 을 들고 있어 Kafka 와 같은 ClassCastException(정책 다운로드 실패 = 전부 거부)이
#   날 수 있다(Gotcha 204 ⑦).
RUN set -eux; \
    mvn -B -q -pl agents-common dependency:copy-dependencies \
        -DincludeScope=runtime -DoutputDirectory=/deps \
        -DincludeGroupIds=org.glassfish.jersey.core,org.glassfish.jersey.inject,org.glassfish.hk2,org.glassfish.hk2.external,jakarta.ws.rs,jakarta.inject,jakarta.annotation,org.javassist; \
    mvn -B -q -pl agents-common dependency:copy \
        -Dartifact=org.glassfish.jersey.core:jersey-server:2.47 -DoutputDirectory=/deps; \
    mvn -B -q -pl agents-common dependency:copy \
        -Dartifact=jakarta.validation:jakarta.validation-api:2.0.2 -DoutputDirectory=/deps; \
    ls /deps

# KnoxUserAuthPlugin — Solr 가 직접 싣는다(공유 lib 최상위). solr-core·solrj·서블릿에 대고 컴파일한다.
RUN set -eux; \
    M=/root/.m2/repository; \
    CP="$M/org/apache/solr/solr-core/10.0.0/solr-core-10.0.0.jar"; \
    CP="$CP:$M/org/apache/solr/solr-solrj/10.0.0/solr-solrj-10.0.0.jar"; \
    CP="$CP:$M/jakarta/servlet/jakarta.servlet-api/6.0.0/jakarta.servlet-api-6.0.0.jar"; \
    for j in $(echo "$CP" | tr ':' ' '); do test -f "$j"; done; \
    mkdir -p /tmp/oim-out; \
    javac --release 21 -cp "$CP" -d /tmp/oim-out $(find /tmp/oim-src -name '*.java'); \
    jar cf /tmp/oim-solr-knox-auth.jar -C /tmp/oim-out .; \
    jar tf /tmp/oim-solr-knox-auth.jar | grep -q '^org/oneinchmarket/solr/KnoxUserAuthPlugin.class$'

# ── ③ 업스트림 배포물에 우리 jar 를 얹는다 ─────────────────────────
#   빼는 것: Jersey 1 · 옛 Lucene(8.11 — Solr 의 10.3 과 섞이면 안 된다) · 감사 목적지(감사는 끈다) ·
#   배포물의 Jersey 2 (버전이 섞이지 않게 /deps 의 2.47 로 바꾼다).
RUN set -eux; \
    curl -sSL --fail -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/solr/ranger-2.9.0-solr-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-solr-plugin/lib/. /plugin/; \
    IMPL=/plugin/ranger-solr-plugin-impl; \
    test -d "$IMPL"; \
    cp agents-common/target/ranger-plugins-common-2.9.0.jar           "$IMPL/"; \
    cp plugin-solr/target/ranger-solr-plugin-2.9.0.jar                "$IMPL/"; \
    cp ranger-solr-plugin-shim/target/ranger-solr-plugin-shim-2.9.0.jar /plugin/; \
    cp /tmp/oim-solr-knox-auth.jar /plugin/; \
    rm -f "$IMPL"/jersey-*.jar "$IMPL"/jsr311-api-*.jar \
          "$IMPL"/lucene-*.jar "$IMPL"/ranger-audit-dest-*.jar; \
    cp /deps/*.jar "$IMPL/"; \
    if ls "$IMPL" | grep -qE '^(jersey-client-1|jersey-core-1|jsr311-api|lucene-|ranger-audit-dest-)'; then \
      echo "[guard] 빼야 할 jar 가 남았다" >&2; ls "$IMPL" >&2; exit 1; \
    fi; \
    n=$(ls "$IMPL" | grep -cE '^jersey-(client|common|hk2|server)-2\.47\.jar$'); \
    if [ "$n" -ne 4 ]; then echo "[guard] Jersey 2.47 네 개가 아니다: $n" >&2; ls "$IMPL" >&2; exit 1; fi; \
    if [ "$(ls "$IMPL" | grep -cE '^jersey-')" -ne 4 ]; then echo "[guard] Jersey 버전이 섞였다" >&2; exit 1; fi; \
    echo "== top"; ls /plugin; echo "== impl"; ls "$IMPL"

# ★★ Hadoop 클라이언트를 3.4.2 -> 3.5.0 으로 바꾼다 (2026-11-04).
#   Solr 10 이미지의 JVM 은 **Java 25** 이고, JDK 24 부터 Subject.getSubject() 가
#   UnsupportedOperationException 을 던진다(SecurityManager 제거, JEP 486). 배포물의
#   hadoop-client 3.4.2 는 UserGroupInformation.getCurrentUser() 에서 그것을 부르고,
#   RangerConfiguration 이 XML 을 읽는 도중에 그 예외가 나서 **"Unable to load the resource"**
#   로만 보였다(실측 — 원인은 DEBUG 로그에만 있다). 그러면 서비스 이름·Admin URL 이 비어
#   플러그인이 초기화되지 않고 **모든 요청이 503** 이다.
#   ★ `-Djava.security.manager=allow` 로는 못 푼다 — JDK 25 는 그 값으로 JVM 기동을 거부한다(실측).
#   ★ 3.5.0 은 Subject.current() 로 옮겨 통과한다(JDK 25 에서 getLoginUser·getCurrentUser 실측).
#     Ranger 자신의 jar 에는 Subject.getSubject 직접 호출이 없다(javap 로 셌다).
ARG HADOOP_CLIENT=3.5.0
RUN set -eux; \
    IMPL=/plugin/ranger-solr-plugin-impl; \
    rm -f "$IMPL"/hadoop-client-api-*.jar "$IMPL"/hadoop-client-runtime-*.jar; \
    for a in api runtime; do \
      curl -sSL --fail -o "$IMPL/hadoop-client-${a}-${HADOOP_CLIENT}.jar" \
        "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-${a}/${HADOOP_CLIENT}/hadoop-client-${a}-${HADOOP_CLIENT}.jar"; \
    done; \
    [ "$(ls "$IMPL" | grep -c '^hadoop-client-')" -eq 2 ]; \
    jar tf "$IMPL/hadoop-client-api-${HADOOP_CLIENT}.jar" | grep -q '^org/apache/hadoop/security/UserGroupInformation.class$'

FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-solr-plugin (Solr 10 / Jersey 2)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 Solr plugin ported to Solr 10.0.0, plus a Knox user.name authentication plugin." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /plugin /plugin
