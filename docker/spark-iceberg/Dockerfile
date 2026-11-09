# Spark + Iceberg 런타임. ETL Job · History Server · Connect Server ·
# Livy 가 생성하는 driver/executor 가 모두 이 이미지를 쓴다.
#
# JAR 을 이미지에 굽는다. --packages 로 런타임에 내려받지 않는다.
# 근거: hive-metastore initContainer 가 기동 시 인터넷에서 JDBC 드라이버를
#       받는 구성이 SEC-512 로 지적되어 있다. 같은 실수를 반복하지 않는다.
#
# ★★ 2026-11-09 에 Spark 3.5.9(Scala 2.12) -> 4.1.2(Scala 2.13) 로 옮겼다.
#   상한을 정하는 것은 Iceberg 다 — Iceberg 1.12.0 의 Spark 런타임은 4.0·4.1 까지만 있다
#   (iceberg-spark-runtime-4.2/4.3 은 Central 에 없다, 실측 404). Spark 를 4.2+ 로 올리려면
#   그 런타임이 먼저 나와야 한다. Livy 는 master 를 소스에서 빌드한다(docker/livy).
# ★ Java 17 판을 쓴다 — Iceberg 1.10+ 는 class 61(Java 17)이고, Livy master 도 java.version 17 로
#   빌드된다(Java 21 판을 쓰면 서버·드라이버·익스큐터의 JVM 이 갈린다). 아래 가드가 JVM 메이저를
#   확인한다(Gotcha 43 — 바이트코드에 물을 것). python3 이 함께 든 판이다(Livy PySpark).
FROM docker.io/apache/spark:4.1.2-scala2.13-java17-python3-ubuntu

USER root

# fail-closed: Iceberg 는 class 61(Java 17) 이다. 베이스를 바꿀 때 Java 11 로 되돌아가면 빌드가 멈춘다.
RUN v=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.specification.version = //p') \
 && echo "java.specification.version=$v" \
 && [ "${v%%.*}" -ge 17 ] \
 && command -v python3

ARG ICEBERG_VERSION=1.12.0
ARG SCALA_VERSION=2.13
ARG ICEBERG_SPARK_LINE=4.1

# ★★ hadoop-aws 는 베이스가 번들한 hadoop-client-api 와 **정확히 같은 판**이어야 한다.
#   apache/spark:4.1.2 는 `hadoop-client-api-3.4.2.jar` 를 들고 있다 — 다른 판을 넣으면 런타임에
#   NoSuchMethodError 로 깨지고 빌드는 성공한다. 아래 가드가 둘을 대조한다.
#   ★★ AWS SDK 는 **v2 한 벌**만 두고, 그것은 **AWS 공식 `bundle`** 이다(2026-11-09 실측으로 정했다).
#   처음에는 iceberg-aws-bundle(SDK 2.54.17 을 이름 그대로 담는다) 하나로 S3A 까지 쓰려 했는데, 배포하자
#   Connect·History 가 `NoClassDefFoundError: software/amazon/awssdk/transfer/s3/model/ObjectTransfer` 로
#   죽었다 — hadoop-aws 3.4 는 Transfer Manager · Apache HTTP 클라이언트 · bundle 안에서만 이름이 바뀐
#   httpclient(`software.amazon.awssdk.thirdparty.org.apache.http`)를 직접 참조한다. 앞의 둘은 jar 를 보태면
#   되지만 셋째는 bundle 에만 있다. 그래서 iceberg-aws-bundle 을 빼고 bundle 을 넣는다. 판은 Iceberg 1.12 가
#   쓰는 2.54.17(hadoop-aws 3.4.2 가 빌드된 2.29.52 보다 새 판 — SDK v2 는 같은 메이저 안에서 하위 호환).
#   대가: bundle 이 709 MB 라 이미지가 그만큼 커진다.
#   ★ 판정은 기동이 아니라 **jdeps** 로 했다: 이미지의 jar 위에서 hadoop-aws · Iceberg 의 aws 클래스가 푸는 것을
#   세면 남는 것은 기본으로 꺼진 기능뿐이다 — 클라이언트 측 암호화(amazon-s3-encryption-client) ·
#   S3 Analytics Accelerator · SDK v1 어댑터(com.amazonaws). 그것을 켜려면 해당 jar 를 먼저 넣을 것.
#   ★ url-connection-client 는 bundle 에 없어 따로 넣는다 — Iceberg 의 `http-client.type=urlconnection` 용이다.
#   3.3.x 시절의 SDK v1(`aws-java-sdk-bundle`)은 걷어냈다 — 그래서 S3A 자격 제공자도 v2 클래스 이름을 쓴다
#   (spark-defaults-configmap.yaml).
ARG HADOOP_AWS_VERSION=3.4.2
ARG AWS_SDK_V2_VERSION=2.54.17

# 레포 표준 securityContext(runAsUser 1000)에 맞춘다.
# apache/spark 공식 이미지는 uid 185 라 그대로 쓰면 예외 문서화가 필요하다.
RUN groupadd -g 1000 sparkgrp || true \
 && useradd -u 1000 -g 1000 -m -s /bin/bash sparkuser \
 && mkdir -p /opt/spark/jobs /opt/spark/conf \
 && chown -R 1000:1000 /opt/spark

ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-${ICEBERG_SPARK_LINE}_${SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-${ICEBERG_SPARK_LINE}_${SCALA_VERSION}-${ICEBERG_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_SDK_V2_VERSION}/bundle-${AWS_SDK_V2_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/software/amazon/awssdk/url-connection-client/${AWS_SDK_V2_VERSION}/url-connection-client-${AWS_SDK_V2_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar \
  /opt/spark/jars/

# Spark Connect 서버는 4.x 부터 배포판에 들어 있다(jars/spark-connect_2.13-4.1.2.jar) — 따로 넣지 않는다.
# fail-closed 가드: ① hadoop-aws 와 hadoop-client-api 의 판이 같다 ② Connect jar 가 있다
#   ③ SDK v1 · iceberg-aws-bundle 이 섞이지 않았다 ④ S3 클라이언트가 정확히 jar 한 개에 있다
#   ⑤ hadoop-aws 가 직접 참조하는 셋(Transfer Manager · Apache 클라이언트 · bundle 의 이름 바뀐 httpclient)이 있다.
RUN cd /opt/spark/jars \
 && api=$(ls hadoop-client-api-*.jar | sed 's/hadoop-client-api-\(.*\)\.jar/\1/') \
 && { [ "$api" = "${HADOOP_AWS_VERSION}" ] || { echo "hadoop-client-api=$api != hadoop-aws=${HADOOP_AWS_VERSION}"; exit 1; }; } \
 && ls spark-connect_${SCALA_VERSION}-*.jar \
 && { ! ls aws-java-sdk-bundle-*.jar iceberg-aws-bundle-*.jar 2>/dev/null; } \
 && python3 -c 'import glob,sys,zipfile; h=[j for j in glob.glob("*.jar") if "software/amazon/awssdk/services/s3/S3Client.class" in zipfile.ZipFile(j).namelist()]; print("S3Client in", h); sys.exit(0 if len(h)==1 else 1)' \
 && python3 -c 'import sys,zipfile; n=set(zipfile.ZipFile(sys.argv[1]).namelist()); need=["software/amazon/awssdk/transfer/s3/model/ObjectTransfer.class","software/amazon/awssdk/http/apache/ApacheHttpClient.class","software/amazon/awssdk/thirdparty/org/apache/http/conn/ssl/SSLConnectionSocketFactory.class"]; miss=[c for c in need if c not in n]; print("missing", miss); sys.exit(1 if miss else 0)' bundle-${AWS_SDK_V2_VERSION}.jar \
 && chmod 0644 /opt/spark/jars/*.jar

# TODO-44: JAR 체크섬 검증 추가 (SEC-512 완전 해소)
USER 1000
WORKDIR /opt/spark
