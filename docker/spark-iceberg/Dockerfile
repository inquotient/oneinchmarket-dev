# Spark + Iceberg 런타임. ETL Job · History Server · Connect Server ·
# Livy 가 생성하는 driver/executor 가 모두 이 이미지를 쓴다.
#
# JAR 을 이미지에 굽는다. --packages 로 런타임에 내려받지 않는다.
# 근거: hive-metastore initContainer 가 기동 시 인터넷에서 JDBC 드라이버를
#       받는 구성이 SEC-512 로 지적되어 있다. 같은 실수를 반복하지 않는다.
FROM docker.io/apache/spark:3.5.6

USER root

ARG ICEBERG_VERSION=1.7.1
ARG SCALA_VERSION=2.12
ARG SPARK_VERSION=3.5.6
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
