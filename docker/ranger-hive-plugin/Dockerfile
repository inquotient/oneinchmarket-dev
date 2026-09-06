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
#      아래 세 가지뿐이기 때문이다. HBase 와 정반대 판단이고, 판단 기준은
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

# ★ Hive 버전은 인자로 뺀다 — 매니페스트의 apache/hive 태그와 **짝이 맞아야
#   한다.** 플러그인은 그 버전의 API 로 컴파일되기 때문이다.
# ★ 이미지 태그는 4.2.1 이지만 Maven Central 에는 **4.2.1 아티팩트가 없다**
#   (hive-jdbc·hive-service 가 404). 바이너리만 릴리스된 경우다.
#   패치 차이라 API 는 같으므로 4.2.0 으로 컴파일해 4.2.1 위에서 돌린다.
ARG HIVE_VERSION=4.2.0

# ── ★★ 빌드 JDK 는 21 이어야 한다 (§8-71) ─────────────────────────
#   Hive 4.2 는 **Java 21 로 컴파일**돼 있다(class file version 65). JDK 8 은
#   그 클래스 파일을 읽지 못한다 — 증상은
#     RangerHiveAuthorizer.java:[44,36] error: cannot access FileUtils
#   이고 maven-compiler-plugin 3.3 이 **사유 줄을 삼켜** 원인이 드러나지 않는다.
#   "클래스를 못 찾는다" 로 읽히지만 실제로는 "읽을 수 없는 버전" 이다.
#   HBase 3(§8-69)에서 겪은 것과 같은 함정이고 거기서는 61(Java 17)이었다.
#   ★ 판정은 추측하지 말고 바이트코드에 물을 것 —
#       javap -verbose <class> | grep major     (52=8 · 55=11 · 61=17 · 65=21)
#   ★ 4.0.1 은 class version 52(Java 8)라 JDK 8 로 됐다. 4.2 로 올리며
#     비로소 드러난 것이다.
#
# ── ★ 2단계로 나눈 이유와, 그 이유가 틀린 것으로 드러난 것 ──────────
#   HBase 판을 본떠 "Ranger 2.9 의 agents-common 은 Nashorn(jdk.nashorn.*)을
#   써서 JDK 15+ 에서 컴파일되지 않는다" 를 전제로 1단계(JDK 8)를 두었다.
#   **그 전제는 실측에서 성립하지 않았다** — 2단계(JDK 21)가 `-am` 으로
#   agents-common 을 포함한 상위 10개 모듈을 전부 다시 컴파일했고
#   `Common library for Plugins ... SUCCESS` 로 통과했다.
#   그래서 이 이미지는 **단일 JDK 21 단계로 접을 수 있다.**
#   접지 않고 두는 이유는 하나뿐이다: 1단계가 로컬 저장소(~/.m2)를 채워 두면
#   2단계를 고쳐 다시 돌릴 때 의존성 재다운로드(약 950건)를 건너뛴다.
#   ★ 즉 이 분리는 **정확성이 아니라 반복 빌드 시간** 때문이다. 없애도 된다.

# ── 1단계 : JDK 8 — 로컬 저장소 워밍업 (정확성 목적이 아니다. 위 주석 참조) ──
FROM docker.io/library/maven:3.9-eclipse-temurin-8 AS jdk8
WORKDIR /src
RUN curl -sSL -o s.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/apache-ranger-2.9.0.tar.gz" \
 && tar xzf s.tgz && rm s.tgz
WORKDIR /src/apache-ranger-2.9.0
RUN mvn -B -q install -pl agents-common,ranger-plugin-classloader -am \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true

# ── 2단계 : JDK 21 — 백포트 + Hive 모듈 컴파일 ─────────────────────
FROM docker.io/library/maven:3.9-eclipse-temurin-21 AS build
ARG HIVE_VERSION
COPY --from=jdk8 /root/.m2 /root/.m2
COPY --from=jdk8 /src /src
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

# ③ Hive 4.2 의 IMetaStoreClient.getTables 가 TException 을 던진다
#    HiveClient.getTblListFromHM() 은 MetaException 만 잡고 있어 컴파일이 막힌다:
#      HiveClient.java:[365,67] error: unreported exception TException;
#                                      must be caught or declared to be thrown
#    ★ MetaException 은 TException 의 하위형이므로 catch 를 TException 으로
#      넓히면 기존 처리도 그대로 유지된다 — 잡는 범위만 커진다.
#      TException 은 이미 import 되어 있다(32행). 새 import 가 필요 없다.
#    ★ 이 파일에는 catch (MetaException e) 가 **두 곳**이다. 뒤쪽(653행)은
#      바로 다음에 catch (Throwable t) 가 있어 넓힐 필요가 없다. 그래서
#      `0,/.../` 로 **첫 번째만** 바꾸고, 남은 한 곳을 세어 확인한다.
#    ★ 4.2 로 올리며 처음 드러났다 — 4.0.1 의 getTables 는 MetaException 만
#      선언했다. 인가 로직이 아니라 **서비스 정의용 자원 조회 클라이언트**다
#      (Ranger Admin 이 DB·테이블 목록을 자동완성할 때 쓴다).
RUN set -eux; \
    F=hive-agent/src/main/java/org/apache/ranger/services/hive/client/HiveClient.java; \
    sed -i '0,/catch (MetaException e)/s//catch (TException e)/' "$F"; \
    grep -q 'import org.apache.thrift.TException;' "$F"; \
    test "$(grep -c 'catch (MetaException e)' "$F")" = "1"

# ★ `-am` 을 뺀다. 1단계가 install 해 둔 아티팩트를 그대로 쓰면 되고,
#   `-am` 은 상위 10개 모듈을 매번 다시 컴파일해 약 40초를 더 쓴다.
#   ★ 정확성 문제는 아니다 — `-am` 으로 돌려도 통과한다(위 주석 참조).
#     HBase 판(§8-69)에도 -am 이 없고, 거기서는 그것이 필수였다.
RUN mvn -B -pl hive-agent,ranger-hive-plugin-shim \
        -Dhive.version=${HIVE_VERSION} \
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
