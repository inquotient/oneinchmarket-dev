# Ranger 2.9.0 Hive 플러그인 — Hive 4 로 백포트해 빌드한다 (§8-70)
#
# ★ 이것은 **백포트**다 — HBase(§8-69)와 다르다.
#   upstream master 의 pom 이 <hive.version>4.0.1</hive.version> 이고 인가자가
#   Hive 4 에 맞춰져 있다. 즉 대조할 구현이 있다.
#
# ★ 그런데 master 파일을 떼어 오는 방식은 **실패한다.**
#   master 의 RangerHiveAuthorizer 는 master 의 RangerHiveAccessRequest·
#   RangerHiveResource·HiveAccessType 과 함께 진화해서, 그 파일만 가져오면
#   내부 계약이 어긋난다(실측: 생성자 24건·타입 48건·비교 17건). 게다가
#   2.9.0 은 HiveObjectType·HiveAccessType 을 RangerHiveAuthorizer.java 맨
#   아래에 **패키지 전용 top-level enum** 으로 선언해 두어, 그 파일을 갈아끼우면
#   같은 패키지의 다른 파일들이 타입을 잃는다.
#   -> **2.9.0 자체 코드를 고치는 쪽이 오히려 좁다.** Hive 4 와 어긋나는 지점이
#      아래 두 가지뿐이기 때문이다. HBase 와 정반대 판단이고, 판단 기준은
#      "어느 쪽 변경 표면이 좁은가" 하나다.
#
# ── 고치는 것 ──────────────────────────────────────────────────────
# ① NoSuchFieldError: PREEXECHOOKS
#    Hive 4 가 HiveConf.ConfVars 상수를 개명했다. upstream master 의 수정을
#    그대로 쓴다 — 컴파일 시점 enum 상수 대신 **런타임 키 조회**다:
#      hiveConf.getVar(ConfVars.PREEXECHOOKS)
#        -> hiveConf.getVar(HiveConf.getConfVars("hive.exec.pre.hooks"))
#    설정 키 이름은 Hive 3·4 가 같아 양쪽에서 성립한다.
#
# ② 인덱스 연산 case 라벨
#    Hive 4 가 인덱스 기능을 통째로 걷어내 HiveOperationType 에서
#    CREATEINDEX·DROPINDEX·ALTERINDEX_*·SHOWINDEXES 가 사라졌다.
#    DROPVIEW_PROPERTIES 도 없다(ALTERVIEW_PROPERTIES 로 흡수).
#    ★ 지워도 **인가 공백이 아니다** — 그 연산 자체가 Hive 4 에 존재하지 않는다.
#      DROPVIEW_PROPERTIES 는 같은 case 그룹의 ALTERVIEW_PROPERTIES 가 덮고
#      둘 다 HiveAccessType.ALTER 로 간다.
#    ★★ CREATEINDEX 는 **두 곳**에 있다. 하나는 혼자 있는 블록이라 라벨만
#      지우면 문장이 고아가 되고, 다른 하나는 라벨 줄만 지우면 된다.
#      한쪽만 처리하면 나머지가 남는다(실측으로 그렇게 한 번 막혔다).
#
# ★ 한시적이다. Ranger 3.0.0 이 릴리스되면 이 이미지를 지운다.

FROM docker.io/library/maven:3.9-eclipse-temurin-8 AS build
WORKDIR /src
RUN curl -sSL -o s.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/apache-ranger-2.9.0.tar.gz" \
 && tar xzf s.tgz && rm s.tgz
WORKDIR /src/apache-ranger-2.9.0

# ① PREEXECHOOKS -> 런타임 키 조회
RUN set -eux; \
    HA=hive-agent/src/main/java/org/apache/ranger/authorization/hive/authorizer; \
    for F in "$HA/RangerHiveAuthorizerBase.java" "$HA/RangerHiveAuthorizer.java"; do \
      sed -i 's|ConfVars\.PREEXECHOOKS|HiveConf.getConfVars("hive.exec.pre.hooks")|g' "$F"; \
    done; \
    ! grep -rq 'ConfVars\.PREEXECHOOKS' "$HA/"

# ② Hive 4 가 없앤 인덱스 연산 case 라벨 제거
RUN set -eux; \
    F=hive-agent/src/main/java/org/apache/ranger/authorization/hive/authorizer/RangerHiveAuthorizer.java; \
    sed -i -z 's@[ \t]*case CREATEINDEX:\n[ \t]*accessType = HiveAccessType\.INDEX;\n[ \t]*break;\n@@g' "$F"; \
    sed -i -E '/^[[:space:]]*case (CREATEINDEX|DROPINDEX|ALTERINDEX_PROPS|ALTERINDEX_REBUILD|SHOWINDEXES|DROPVIEW_PROPERTIES):[[:space:]]*$/d' "$F"; \
    test "$(grep -cE 'case (CREATEINDEX|DROPINDEX|ALTERINDEX_PROPS|ALTERINDEX_REBUILD|SHOWINDEXES|DROPVIEW_PROPERTIES):' "$F")" = "0"

RUN mvn -B -pl hive-agent,ranger-hive-plugin-shim -am \
        -Dhive.version=4.0.1 \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true \
        package

# 업스트림 배포물에 우리 jar 두 개를 얹는다. 나머지는 업스트림 그대로다.
RUN set -eux; \
    curl -sSL -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/hive/ranger-2.9.0-hive-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-hive-plugin/lib/. /plugin/; \
    cp hive-agent/target/ranger-hive-plugin-2.9.0.jar /plugin/ranger-hive-plugin-impl/; \
    cp ranger-hive-plugin-shim/target/ranger-hive-plugin-shim-2.9.0.jar /plugin/

FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-hive-plugin (Hive 4 backport)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 Hive plugin backported to Hive 4 APIs. See docs/LOCAL-DEPLOYMENT.md 8-70." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /plugin /plugin
