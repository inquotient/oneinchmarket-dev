# Apache Livy 0.9.0-incubating — Spark on Kubernetes REST 게이트웨이
# LIVY-702(K8s 지원) · LIVY-1010(Spark 3.5.6 지원)
#
# Livy 서버는 spark-submit 을 호출하므로 Spark 배포판이 함께 있어야 한다.
FROM localhost/oneinch/spark-iceberg:latest

USER root

ARG LIVY_VERSION=0.9.0-incubating

ADD https://downloads.apache.org/incubator/livy/${LIVY_VERSION}/apache-livy-${LIVY_VERSION}_2.12-bin.zip /tmp/livy.zip

RUN apt-get update \
 && apt-get install -y --no-install-recommends unzip \
 && unzip -q /tmp/livy.zip -d /opt \
 && mv /opt/apache-livy-${LIVY_VERSION}_2.12-bin /opt/livy \
 && mkdir -p /opt/livy/logs /opt/livy/conf \
 && chown -R 1000:1000 /opt/livy

# TODO-44: 배포판 서명(.asc)·체크섬 검증 추가
USER 1000
WORKDIR /opt/livy
EXPOSE 8998
ENTRYPOINT ["/opt/livy/bin/livy-server"]
