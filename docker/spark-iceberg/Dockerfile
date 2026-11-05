# Spark + Iceberg 런타임. ETL Job · History Server · Connect Server ·
# Livy 가 생성하는 driver/executor 가 모두 이 이미지를 쓴다.
#
# JAR 을 이미지에 굽는다. --packages 로 런타임에 내려받지 않는다.
# 근거: hive-metastore initContainer 가 기동 시 인터넷에서 JDBC 드라이버를
#       받는 구성이 SEC-512 로 지적되어 있다. 같은 실수를 반복하지 않는다.
#
# ★★ 베이스는 **Java 17 판**이어야 한다(2026-11-06). Iceberg 1.10+ 는 Java 17 로 빌드되는데
#   `apache/spark:3.5.6` 은 Java 11 이라, spark.sql.extensions 의 Iceberg 확장을 싣는 순간
#   `UnsupportedClassVersionError: org/apache/iceberg/spark/ExtendedParser ... class file version
#   61.0 ... up to 55` 로 SparkSession 이 만들어지지 않았다 — Livy 세션의 첫 문장에서 드러났다.
#   ★ 빌드는 성공하고 파드도 Ready 라(Spark Connect 는 첫 SQL 전까지 확장을 싣지 않는다) 실제로
#   질의해야만 드러난다. 그래서 아래 가드가 JVM 메이저를 확인한다(Gotcha 43 — 바이트코드에 물을 것).
#   python3 이 함께 든 판을 쓴다(Livy 의 PySpark · spark.pyspark.python=python3).
FROM docker.io/apache/spark:3.5.6-scala2.12-java17-python3-ubuntu

USER root

# fail-closed: Iceberg 1.11 은 class 61(Java 17) 이다. 베이스를 바꿀 때 Java 11 로 되돌아가면 빌드가 멈춘다.
RUN v=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.specification.version = //p') \
 && echo "java.specification.version=$v" \
 && [ "${v%%.*}" -ge 17 ] \
 && command -v python3

ARG ICEBERG_VERSION=1.11.0
ARG SCALA_VERSION=2.12
ARG SPARK_VERSION=3.5.6

# ★★ 아래 둘은 **최신으로 올리지 말 것.** 여기서 "최신" 은 오답이다.
#   apache/spark:3.5.6 이 번들하는 것은 `hadoop-client-api-3.3.4.jar` 이고,
#   hadoop-aws 는 같은 계열의 hadoop-common 을 전제한다. 3.5.0 을 넣으면
#   런타임에 NoSuchMethodError 로 깨진다 — 빌드는 성공하므로 드러나지 않는다.
#   그리고 AWS SDK 계열도 hadoop-aws 가 정한다: 3.3.x 는 **v1**
#   (`aws-java-sdk-bundle`), 3.4+ 는 v2(`bundle`)다. 즉 SDK v1 이 EOL 계열임에도
#   여기서 v2 로 바꿀 수 없다 — 바꾸려면 Spark 자체를 올려야 한다.
#   ★ 이 값들의 상한을 정하는 것은 레지스트리가 아니라 **베이스 이미지**다.
ARG HADOOP_AWS_VERSION=3.3.4
ARG AWS_SDK_VERSION=1.12.767

# 레포 표준 securityContext(runAsUser 1000)에 맞춘다.
# apache/spark 공식 이미지는 uid 185 라 그대로 쓰면 예외 문서화가 필요하다.
RUN groupadd -g 1000 sparkgrp || true \
 && useradd -u 1000 -g 1000 -m -s /bin/bash sparkuser \
 && mkdir -p /opt/spark/jobs /opt/spark/conf \
 && chown -R 1000:1000 /opt/spark

ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_${SCALA_VERSION}/${ICEBERG_VERSION}/iceberg-spark-runtime-3.5_${SCALA_VERSION}-${ICEBERG_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar \
  /opt/spark/jars/

# Spark Connect 서버는 apache/spark 배포판에 포함되어 있지 않다.
#   Failed to load class org.apache.spark.sql.connect.service.SparkConnectServer
#   You need to specify Spark Connect jars with --jars or --packages
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/spark/spark-connect_${SCALA_VERSION}/${SPARK_VERSION}/spark-connect_${SCALA_VERSION}-${SPARK_VERSION}.jar \
  /opt/spark/jars/

RUN chmod 0644 /opt/spark/jars/*.jar

# TODO-44: JAR 체크섬 검증 추가 (SEC-512 완전 해소)
USER 1000
WORKDIR /opt/spark
