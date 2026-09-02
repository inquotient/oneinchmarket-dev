# Apache HBase
#
# 공식 이미지가 없다 — Docker Hub 에 `apache/hbase` 저장소가 **존재하지 않는다**(404).
# v1 은 `v1/hbase/Dockerfile` 로 직접 만들었고, 이 파일은 그것을 고쳐 옮긴 것이다.
#
# ── v1 대비 고친 것 ────────────────────────────────────────────────
#  ① FROM ubuntu:devel  ->  eclipse-temurin:17-jre-noble
#     `devel` 은 아직 릴리스되지 않은 Ubuntu 를 가리킨다(현재 resolute/26.04).
#     매일 바뀌므로 재현이 불가능하고, 어느 날 깨져도 원인을 알 수 없다.
#  ② HBase 2.6.3 -> 2.6.6
#     **2.6.3 은 dlcdn 에서 내려갔다(404).** v1 Dockerfile 은 오늘 빌드하면
#     그 자리에서 실패한다. dlcdn 은 현행 릴리스만 보관한다.
#  ③ SHA-512 검증 추가. v1 은 tarball 을 검증 없이 받았다.
#  ④ krb5-user·libkrb5-3 제거. Kerberos 를 채택하지 않았다(§8-14).
#  ⑤ openjdk-17-jdk -> JRE 베이스. 실행에 컴파일러가 필요 없다.
#  ⑥ `curl` 이 같은 apt 줄에 두 번 있던 것을 정리.
#  ⑦ docs/ 제거 — 이미지에서 수십 MB 를 차지하고 쓰이지 않는다.
#
# ── uid 주의 ──────────────────────────────────────────────────────
#  Ubuntu noble 베이스에는 uid 1000 의 `ubuntu` 사용자가 이미 있다.
#  그래서 hbase 는 **1001** 이다(v1 과 같다). 매니페스트의 runAsUser 와
#  반드시 일치해야 한다.
#  HDFS 는 uid 가 아니라 **사용자 이름**으로 권한을 판단하므로,
#  HDFS 쪽 /hbase 소유자를 `hbase` 로 맞춰 두면 된다(hdfs-bootstrap Job).
# ★ podman 은 short-name 을 해석하지 않는다. 레지스트리를 명시한다
#   (ranger-usersync 에서 이미 겪은 것이다).
FROM docker.io/library/eclipse-temurin:17-jre-noble

ARG HBASE_VERSION=2.6.6
# https://dlcdn.apache.org/hbase/2.6.6/hbase-2.6.6-bin.tar.gz.sha512
ARG HBASE_SHA512=7724703971a397f7b78aa82bef97eae6b5fd2fc83a2039d42b4c9ce02f67b192c502cb6cfbf3a0f205f1384871456087aa54b282469e22cabf715ae594076a5d

USER root

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash coreutils procps curl ca-certificates netcat-openbsd dnsutils \
      libsnappy1v5 zlib1g liblz4-1 libzstd1; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1001 hbase; \
    useradd -u 1001 -g 1001 -m -s /bin/bash hbase

RUN set -eux; \
    curl -fSL -o /tmp/hbase.tar.gz \
      "https://dlcdn.apache.org/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz"; \
    echo "${HBASE_SHA512}  /tmp/hbase.tar.gz" | sha512sum -c -; \
    mkdir -p /opt/hbase; \
    tar -xzf /tmp/hbase.tar.gz -C /opt/hbase --strip-components=1; \
    rm -f /tmp/hbase.tar.gz; \
    rm -rf /opt/hbase/docs; \
    mkdir -p /opt/hbase/logs /opt/hbase/tmp; \
    chown -R hbase:hbase /opt/hbase

ENV HBASE_HOME=/opt/hbase \
    HBASE_CONF_DIR=/opt/hbase/conf \
    HBASE_LOG_DIR=/opt/hbase/logs \
    PATH=/opt/hbase/bin:$PATH \
    MALLOC_ARENA_MAX=2 \
    HBASE_OPTS="-Djava.security.egd=file:/dev/./urandom"

# ★ JAVA_TOOL_OPTIONS 로 힙을 넘기지 않는다.
#   v1 은 -XX:MaxRAMPercentage=70 을 여기에 넣었는데, 이 변수는 이미지에서
#   실행되는 **모든** JVM(hbase shell·hbck 등 보조 명령 포함)에 적용된다.
#   힙은 매니페스트에서 HBASE_HEAPSIZE 로 컴포넌트마다 준다.

WORKDIR /opt/hbase
USER hbase

# 엔트리포인트는 두지 않는다. 매니페스트가 `hbase master start` /
# `hbase regionserver start` 를 직접 지정한다 — 역할이 이미지가 아니라
# 워크로드에 있기 때문이다.
