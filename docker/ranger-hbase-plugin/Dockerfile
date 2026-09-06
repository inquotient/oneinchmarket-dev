# Ranger 2.9.0 HBase 플러그인 — HBase 3.0.0 으로 이식해 빌드한다 (§8-69)
#
# ★★ 이것은 백포트가 **아니다**. docker/ranger-hdfs-plugin 과 성격이 다르다.
#   그쪽은 upstream 이 master 에서 이미 한 Jersey 2 이관을 옮긴 것이지만,
#   HBase 3 지원은 **미출시 master 에도 없다** — Ranger master 의 pom 이 여전히
#   <hbase.version>2.6.0</hbase.version> 이고 코프로세서도 구 protobuf 를
#   import 한다. 즉 아래 이식은 **우리가 만든 것이고 대조할 구현이 없다.**
#   그래서 검증도 우리 몫이다 — §8-69 의 시험 표를 볼 것.
#
# ── 이식 내역 (전부 컴파일러가 지목한 지점) ────────────────────────
#  ① 코프로세서 클래스가 세 곳에 있다 — hbase-agent(구현),
#     ranger-hbase-plugin-shim(HBase 가 실제로 로드하는 위임자), 레거시 별칭.
#  ② protobuf 좌표 이동
#       org.apache.hadoop.hbase.protobuf.generated.AccessControlProtos
#         -> org.apache.hadoop.hbase.shaded.protobuf.generated.AccessControlProtos
#       com.google.protobuf.*  ->  org.apache.hbase.thirdparty.com.google.protobuf.*
#  ③ ObserverContext 의 와일드카드는 **메서드마다 다르다**(RegionObserver 는
#     <? extends E>, MasterObserver 는 대체로 <E>). 일괄 치환하면 멀쩡한 것을
#     깨뜨린다(실측 166건). 그래서 javap 로 **실제 시그니처를 읽어 규칙을
#     생성**한다. BulkLoadObserver 는 와일드카드를 쓰지 않으므로 되돌린다.
#  ④ 인자 목록이 바뀐 8개 — pre/postModifyTable·preModifyTableAction·
#     postCompletedModifyTableAction(+currentDesc), pre/postModifyNamespace
#     (+currentNs), pre/postUnassign(-force). preModifyTable 은 반환형까지
#     void -> TableDescriptor 로 바뀌어 `return htd;` 를 넣는다(관찰자가 기술자를
#     바꾸지 않을 때의 규약은 받은 것을 그대로 돌려주는 것이다).
#     ★ 인가 판단은 테이블명·네임스페이스·리전으로 하므로 인자만 맞추면 의미가
#       보존된다. 그래도 DDL 단위 시험으로 확인할 것.
#  ⑤ 개명·제거된 API — Filter.filterKeyValue -> filterCell,
#     TableDescriptorBuilder.addColumnFamily -> setColumnFamily,
#     HBaseAdmin 제거(가용성 확인을 커넥션 개폐로 대체 — 조회 경로다),
#     Admin.close() 가 IOException 을 안 던져 catch 가 도달 불가가 된 것.
#  ⑥ HBase 3 이 없앤 hbase-hadoop2-compat 를 테스트 스코프에서 제거.
#
# ── ★★ JDK 두 개가 필요하다 ────────────────────────────────────────
#   HBase 3 은 **Java 17 로 컴파일**돼 있어(class file version 61) JDK 8 은
#   그 클래스 파일을 읽지 못한다. 그런데 Ranger 2.9 의 agents-common 은
#   Nashorn(jdk.nashorn.*)을 써서 **JDK 15+ 에서 컴파일되지 않는다.**
#   서로 배타적이라 Ranger 코드를 건드리지 않기 위해 2단계로 나눈다.
#   (런타임은 원래 JDK 17 이다 — docker/hbase 가 temurin:17-jre 다.)
#
# ★ 한시적이다. Ranger 가 HBase 3 을 정식 지원하면 이 이미지를 지운다.

# ── 1단계 : JDK 8 — agents-common 계열을 로컬 저장소에 install ──────
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

# ── 2단계 : JDK 17 — 이식 + HBase 모듈 컴파일 ──────────────────────
FROM docker.io/library/maven:3.9-eclipse-temurin-17 AS jdk17
COPY --from=jdk8 /root/.m2 /root/.m2
COPY --from=jdk8 /src /src
WORKDIR /src/apache-ranger-2.9.0

# HBase 3 jar 를 받아 둔다 — javap 로 실제 시그니처를 읽기 위해서다.
RUN set -eux; \
    curl -sSL -o /tmp/hb.tgz \
      "https://archive.apache.org/dist/hbase/3.0.0/hbase-3.0.0-bin.tar.gz"; \
    mkdir -p /hb3lib; \
    tar xzf /tmp/hb.tgz -C /tmp; \
    cp /tmp/hbase-3.0.0/lib/hbase-server-3.0.0.jar /hb3lib/; \
    rm -rf /tmp/hb.tgz /tmp/hbase-3.0.0

# ② protobuf 좌표 + HRegionInfo -> RegionInfo
RUN set -eux; \
    FILES="hbase-agent/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/com/xasecure/authorization/hbase/XaSecureAuthorizationCoprocessor.java"; \
    for F in $FILES; do \
      sed -i \
        -e 's|org\.apache\.hadoop\.hbase\.protobuf\.generated\.AccessControlProtos|org.apache.hadoop.hbase.shaded.protobuf.generated.AccessControlProtos|g' \
        -e 's|org\.apache\.hadoop\.hbase\.protobuf\.ProtobufUtil|org.apache.hadoop.hbase.shaded.protobuf.ProtobufUtil|g' \
        -e 's|\bcom\.google\.protobuf\.|org.apache.hbase.thirdparty.com.google.protobuf.|g' \
        -e 's|\bHRegionInfo\b|RegionInfo|g' \
        "$F"; \
      ! grep -qE 'org\.apache\.hadoop\.hbase\.protobuf\.|^import com\.google\.protobuf' "$F"; \
    done

# ③ ObserverContext — javap 로 실제 시그니처에서 규칙을 생성한다(추측 금지)
RUN set -eux; \
    FILES="hbase-agent/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/com/xasecure/authorization/hbase/XaSecureAuthorizationCoprocessor.java"; \
    for I in org.apache.hadoop.hbase.coprocessor.MasterObserver \
             org.apache.hadoop.hbase.coprocessor.RegionObserver \
             org.apache.hadoop.hbase.coprocessor.RegionServerObserver; do \
      javap -cp /hb3lib/hbase-server-3.0.0.jar "$I"; \
    done > /tmp/api.txt; \
    grep -oE '(pre|post)[A-Za-z]+\(org\.apache\.hadoop\.hbase\.coprocessor\.ObserverContext<\? extends org\.apache\.hadoop\.hbase\.coprocessor\.[A-Za-z]+>' /tmp/api.txt \
      | sed -E 's|^([a-zA-Z]+)\(.*coprocessor\.([A-Za-z]+)>$|s@\1(ObserverContext<\2>@\1(ObserverContext<? extends \2>@g|' \
      | sort -u > /tmp/wild.sed; \
    test -s /tmp/wild.sed; \
    for F in $FILES; do \
      sed -i -f /tmp/wild.sed "$F"; \
      sed -i 's|ObserverContext<RegionCoprocessorEnvironment>|ObserverContext<? extends RegionCoprocessorEnvironment>|g' "$F"; \
      sed -i -E 's@((prePrepareBulkLoad|preCleanupBulkLoad)\(ObserverContext)<\? extends (RegionCoprocessorEnvironment)>@\1<\3>@g' "$F"; \
    done

# ④ 인자 목록이 바뀐 8개
RUN set -eux; \
    FILES="hbase-agent/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/org/apache/ranger/authorization/hbase/RangerAuthorizationCoprocessor.java \
           ranger-hbase-plugin-shim/src/main/java/com/xasecure/authorization/hbase/XaSecureAuthorizationCoprocessor.java"; \
    printf '%s\n' \
      '/public TableDescriptor preModifyTable\(/ { inm=1 }' \
      'inm && /^\t\}/ { print "\t\treturn htd;"; inm=0 }' \
      '{ print }' > /tmp/ret.awk; \
    for F in $FILES; do \
      sed -i -E 's@(void (preModifyTable|postModifyTable|preModifyTableAction|postCompletedModifyTableAction)\(ObserverContext<MasterCoprocessorEnvironment> [a-zA-Z]+,[[:space:]]*TableName [a-zA-Z]+,[[:space:]]*)TableDescriptor@\1TableDescriptor currentDesc, TableDescriptor@g' "$F"; \
      sed -i -E 's@(void (preModifyNamespace|postModifyNamespace)\(ObserverContext<MasterCoprocessorEnvironment> [a-zA-Z]+,[[:space:]]*)NamespaceDescriptor@\1NamespaceDescriptor currentNs, NamespaceDescriptor@g' "$F"; \
      sed -i -E 's@((pre|post)Unassign\(ObserverContext<MasterCoprocessorEnvironment> [a-zA-Z]+,[[:space:]]*RegionInfo [a-zA-Z]+), boolean force@\1@g' "$F"; \
      sed -i -E 's@((pre|post)Unassign\([a-zA-Z]+, [a-zA-Z]+), force\)@\1)@g' "$F"; \
      sed -i -E 's@((preModifyTable|postModifyTable|preModifyTableAction|postCompletedModifyTableAction)\([a-zA-Z]+, [a-zA-Z]+), (htd|desc|tableDescriptor)\)@\1, currentDesc, \3)@g' "$F"; \
      sed -i -E 's@((preModifyNamespace|postModifyNamespace)\([a-zA-Z]+), (ns|nsDescriptor)[[:space:]]*\)@\1, currentNs, \3)@g' "$F"; \
      sed -i -E 's@public void preModifyTable\(@public TableDescriptor preModifyTable(@g' "$F"; \
      awk -f /tmp/ret.awk "$F" > /tmp/f.new && mv /tmp/f.new "$F"; \
    done

# ⑤ 개명·제거된 API 4종 + ⑥ 없어진 테스트 의존 제거
RUN set -eux; \
    AG=hbase-agent/src/main/java/org/apache/ranger; \
    sed -i 's@filterKeyValue(Cell@filterCell(Cell@g' "$AG/authorization/hbase/RangerAuthorizationFilter.java"; \
    sed -i 's@\.addColumnFamily(@.setColumnFamily(@g' "$AG/authorization/hbase/RangerAuthorizationCoprocessor.java"; \
    sed -i -e '/^import org\.apache\.hadoop\.hbase\.client\.HBaseAdmin;/d' \
           -e 's@HBaseAdmin\.available(conf);@org.apache.hadoop.hbase.client.ConnectionFactory.createConnection(conf).close();@' \
           "$AG/services/hbase/client/HBaseClient.java"; \
    sed -i -z 's@admin\.close();\n\([ \t]*\)} catch (IOException e) {@admin.close();\n\1} catch (Exception e) {@g' \
           "$AG/services/hbase/client/HBaseClient.java"; \
    printf '%s\n' \
      '/<dependency>/ { buf=$0 ORS; ind=1; next }' \
      'ind { buf=buf $0 ORS; if (/<\/dependency>/) { if (buf !~ /hbase-hadoop2-compat/) printf "%s", buf; ind=0; buf="" } next }' \
      '{ print }' > /tmp/strip.awk; \
    awk -f /tmp/strip.awk hbase-agent/pom.xml > /tmp/pom.new && mv /tmp/pom.new hbase-agent/pom.xml; \
    ! grep -q hbase-hadoop2-compat hbase-agent/pom.xml

# shim 의 hbase-server 의존에는 와일드카드 제외가 걸려 전이 의존이 잘린다.
# yetus 는 컴파일 전용 주석이라 HBase 배포물에 없다 — 없으면 javac 가 클래스
# 파일을 **읽지 못한다**("cannot access ByteArrayComparable").
RUN set -eux; \
    printf '%s\n' \
      '    <dependency><groupId>org.apache.hbase.thirdparty</groupId><artifactId>hbase-shaded-protobuf</artifactId><version>4.1.14</version></dependency>' \
      '    <dependency><groupId>org.apache.hbase</groupId><artifactId>hbase-protocol-shaded</artifactId><version>3.0.0</version></dependency>' \
      '    <dependency><groupId>org.apache.hbase</groupId><artifactId>hbase-common</artifactId><version>3.0.0</version></dependency>' \
      '    <dependency><groupId>org.apache.hbase</groupId><artifactId>hbase-client</artifactId><version>3.0.0</version></dependency>' \
      '    <dependency><groupId>org.apache.yetus</groupId><artifactId>audience-annotations</artifactId><version>0.15.0</version><scope>provided</scope></dependency>' \
      > /tmp/deps.xml; \
    for P in ranger-hbase-plugin-shim/pom.xml hbase-agent/pom.xml; do \
      awk 'NR==FNR{d=d $0 ORS; next} /<dependencies>/ && !done {print; printf "%s", d; done=1; next} {print}' \
          /tmp/deps.xml "$P" > /tmp/p.new; \
      mv /tmp/p.new "$P"; \
      grep -q hbase-shaded-protobuf "$P"; \
    done

RUN mvn -B -pl hbase-agent,ranger-hbase-plugin-shim \
        -Dhbase.version=3.0.0 \
        -DskipTests -Dmaven.test.skip=true -Dmaven.javadoc.skip=true \
        -Drat.skip=true -Dcheckstyle.skip=true -Dsort.skip=true \
        -Dsortpom.skip=true -Dspotbugs.skip=true -Dfindbugs.skip=true \
        package

# 업스트림 배포물에 우리 jar 두 개를 얹는다. 나머지는 업스트림 그대로다.
RUN set -eux; \
    curl -sSL -o /tmp/p.tgz \
      "https://archive.apache.org/dist/ranger/2.9.0/plugins/hbase/ranger-2.9.0-hbase-plugin.tar.gz"; \
    tar xzf /tmp/p.tgz -C /tmp; \
    mkdir -p /plugin; \
    cp -r /tmp/ranger-2.9.0-hbase-plugin/lib/. /plugin/; \
    cp hbase-agent/target/ranger-hbase-plugin-2.9.0.jar /plugin/ranger-hbase-plugin-impl/; \
    cp ranger-hbase-plugin-shim/target/ranger-hbase-plugin-shim-2.9.0.jar /plugin/

# ★★ JAX-RS 를 보충한다 — HBase 3 은 Jersey 를 shade 해 버렸다.
#   코프로세서는 적재되지만 PolicyRefresher 생성에서 죽는다:
#     NoClassDefFoundError: javax/ws/rs/core/Cookie
#   HBase 3 의 lib 에는 hbase-shaded-jersey 만 있고 **평문 javax.ws.rs 가 없다.**
#
#   ★ Hadoop 3.5 와 결론이 반대인 이유(§8-68 과 비교할 것):
#     그쪽은 jakarta.ws.rs-api 2.1 이 이미 javax.ws.rs 를 제공해서 JSR-311 을
#     함께 넣으면 **같은 패키지가 두 벌**이 되어 LinkageError 가 났다. 여기는
#     평문 javax.ws.rs 가 아예 없으므로 중복이 생기지 않는다. 그래서 HDFS 에서는
#     소스를 Jersey 2 로 이식해야 했지만, HBase 에서는 **jar 보충으로 충분하다.**
#     같은 증상이라도 클래스패스에 무엇이 이미 있는지에 따라 처방이 달라진다.
RUN set -eux; \
    M=https://repo1.maven.org/maven2; \
    for J in com/sun/jersey/jersey-client/1.19.4/jersey-client-1.19.4.jar \
             com/sun/jersey/jersey-core/1.19.4/jersey-core-1.19.4.jar \
             javax/ws/rs/jsr311-api/1.1.1/jsr311-api-1.1.1.jar; do \
      curl -sSL --fail -o "/plugin/ranger-hbase-plugin-impl/$(basename $J)" "$M/$J"; \
    done; \
    test -f /plugin/ranger-hbase-plugin-impl/jsr311-api-1.1.1.jar

FROM docker.io/library/busybox:1.36
LABEL org.opencontainers.image.title="ranger-hbase-plugin (HBase 3 port)" \
      org.opencontainers.image.description="Apache Ranger 2.9.0 HBase plugin ported to HBase 3.0.0 APIs. NOT an upstream backport - see docs/LOCAL-DEPLOYMENT.md 8-69." \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=jdk17 /plugin /plugin
