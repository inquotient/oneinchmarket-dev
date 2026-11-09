# Apache Livy (master 소스 빌드) — Spark on Kubernetes REST 게이트웨이
#
# ★★ 2026-11-09 부터 **릴리스가 아니라 master 를 소스에서 빌드한다**(사용자 결정).
#   마지막 릴리스 0.9.0-incubating 은 Spark 3 · Scala 2.12 전용이고 Spark 4 를 지원하는 릴리스가 없다.
#   master(1.0.0-SNAPSHOT)는 기본값이 Spark 4.1.2 · Scala 2.13 · Java 17 이다(pom.xml).
#   ★ 커밋을 고정한다 — 브랜치를 따라가면 같은 태그가 다른 코드가 된다(Gotcha 45). 올릴 때는
#   LIVY_COMMIT 과 이미지 태그(build-images.sh·livy-statefulset.yaml)를 함께 바꿀 것.
#   ★ 레포가 apache/incubator-livy -> apache/livy 로 옮겨졌다(졸업). 옛 이름은 리다이렉트다.
#   ★ 릴리스가 아니므로 서명 검증 대상이 없다 — tarball 의 sha256 을 고정해 내용을 묶는다.
#   ★ 복귀 조건: Spark 4 를 지원하는 정식 릴리스가 나오면 그 배포판(ADD)으로 되돌릴 것.
#
# Livy 서버는 spark-submit 을 호출하므로 Spark 배포판이 함께 있어야 한다 — 실행 단계는 spark-iceberg 위다.

FROM docker.io/library/maven:3.9.11-eclipse-temurin-17 AS build
ARG LIVY_COMMIT=bc234453011e55138767f1b0ad3de9d4f77f93e8
# 2026-11-09 실측값. GitHub archive 가 다른 바이트를 주면 빌드가 멈춘다(fail-closed) — 그때는 새 값을 재서 고칠 것.
ARG LIVY_SRC_SHA256=6c6f0efec112f669b22ad63f87bd6f27cd979853c3c1f67643612c5586a4c1e1
ADD https://github.com/apache/livy/archive/${LIVY_COMMIT}.tar.gz /src/livy.tar.gz
WORKDIR /src
RUN if [ -n "${LIVY_SRC_SHA256}" ]; then echo "${LIVY_SRC_SHA256}  livy.tar.gz" | sha256sum -c -; fi \
 && sha256sum livy.tar.gz \
 && tar -xzf livy.tar.gz && mv livy-${LIVY_COMMIT} livy
WORKDIR /src/livy
# 테스트는 Spark·R·Python 런타임을 띄우므로 건너뛴다. assembly 와 그것이 의존하는 모듈만 빌드한다.
RUN mvn -B -ntp -DskipTests -DskipITs -DskipRTests -Dmaven.javadoc.skip=true \
      -pl assembly -am package \
 && ls -l assembly/target/*.zip

FROM localhost/oneinch/spark-iceberg:latest
USER root
COPY --from=build /src/livy/assembly/target/apache-livy-1.0.0-SNAPSHOT_2.13-bin.zip /tmp/livy.zip
# unzip 대신 python3 zipfile — apt 를 쓰지 않아 베이스에 패키지를 더하지 않는다. 실행 비트는 zip 이 보존하지 않아 직접 준다.
RUN python3 -m zipfile -e /tmp/livy.zip /opt \
 && mv /opt/apache-livy-1.0.0-SNAPSHOT_2.13-bin /opt/livy \
 && rm /tmp/livy.zip \
 && chmod 0755 /opt/livy/bin/* \
 && mkdir -p /opt/livy/logs /opt/livy/conf \
 && ls /opt/livy/jars | grep -q '^livy-server' \
 && ls /opt/livy/repl_2.13-jars | grep -q '^livy-repl_2.13' \
 && chown -R 1000:1000 /opt/livy

USER 1000
WORKDIR /opt/livy
EXPOSE 8998
ENTRYPOINT ["/opt/livy/bin/livy-server"]
