FROM ubuntu:devel

ARG DEBIAN_FRONTEND=noninteractive
ARG VERSION=2.6.3

RUN groupadd -g 1001 hbase && useradd -u 1001 -g 1001 -m -s /bin/bash hbase
# 필수 패키지 설치
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    krb5-user libkrb5-3 \
    libsnappy1v5 zlib1g liblz4-1 libzstd1 openssl \
    openjdk-17-jdk \
    bash coreutils procps netcat-openbsd dnsutils curl ca-certificates jq curl\
    && rm -rf /var/lib/apt/lists/*

RUN curl -fSL -o hbase.tar.gz https://dlcdn.apache.org/hbase/${VERSION}/hbase-${VERSION}-bin.tar.gz; \
    mkdir -p /usr/local/hbase && \
    tar -zxf hbase.tar.gz -C /usr/local/hbase --strip-components=1 && \
    rm -rf hbase.tar.gz

# 비루트 실행 사용자
USER hbase

# 런타임 환경 변수 (네이티브/압축/JVM)
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$JAVA_HOME/bin:${PATH}"
ENV MALLOC_ARENA_MAX=2 \
    HADOOP_OPTS="-Djava.security.egd=file:/dev/./urandom" \
    JAVA_TOOL_OPTIONS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=70"

ENV PATH=$PATH:/usr/local/hbase/bin

WORKDIR /opt