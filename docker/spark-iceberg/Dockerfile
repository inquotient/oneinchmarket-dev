# Spark + Iceberg 런타임. ETL Job · History Server · Connect Server ·
# Livy 가 생성하는 driver/executor 가 모두 이 이미지를 쓴다.
#
# JAR 을 이미지에 굽는다. --packages 로 런타임에 내려받지 않는다.
# 근거: hive-metastore initContainer 가 기동 시 인터넷에서 JDBC 드라이버를
#       받는 구성이 SEC-512 로 지적되어 있다. 같은 실수를 반복하지 않는다.
#
# ★★★ 2026-11-09: Spark 4.2.1 · **Iceberg 는 main 을 소스에서 빌드한다**(사용자 결정 — Livy 와 같은 방식).
#   Spark 판의 상한은 Iceberg 의 Spark 런타임이 정한다. 릴리스 1.12.0 은 Spark 4.1 까지이고, main 에
#   spark/v4.2(Spark 4.2.1)가 있다. 4.3 은 main 에도 없다 — Spark 4.3 은 그 모듈이 생긴 뒤에.
#   ★ 커밋을 고정한다(ICEBERG_COMMIT). 올릴 때는 그 값과 이미지 태그(build-images.sh·매니페스트)를 함께 바꿀 것.
#   ★ 포맷: main 의 기본 테이블 포맷은 여전히 v2 다(TableMetadata.DEFAULT_TABLE_FORMAT_VERSION) — Trino 와
#   공유하므로 `format-version` 을 3 이상으로 올리지 말 것(Trino 가 읽는지 먼저 확인할 것).
#   ★ 복귀 조건: Spark 4.2 런타임을 담은 Iceberg 정식 릴리스가 나오면 Central 의 jar 로 되돌릴 것.
# ★ Java 17 판을 쓴다 — Iceberg 는 class 61(Java 17)이고 Livy master 도 java.version 17 이다.

# ── 1단계: Iceberg 의 Spark 4.2 런타임을 main 의 고정 커밋에서 빌드한다
FROM docker.io/library/eclipse-temurin:17.0.21_9-jdk-jammy AS iceberg
ARG ICEBERG_COMMIT=ac42e6f6e713ba06a03802f84209dcf6eb9c99c4
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
# git 으로 그 커밋만 받는다 — 빌드가 판 문자열을 git 에서 만든다(tarball 에는 .git 이 없다).
WORKDIR /src/iceberg
RUN git init -q . \
 && git remote add origin https://github.com/apache/iceberg.git \
 && git fetch -q --depth 1 origin "${ICEBERG_COMMIT}" \
 && git checkout -q FETCH_HEAD \
 && [ "$(git rev-parse HEAD)" = "${ICEBERG_COMMIT}" ]
# Spark 4.2 · Scala 2.13 만 켠다(Flink·Kafka·Hive 모듈은 빌드하지 않는다). 테스트는 건너뛴다.
RUN ./gradlew --no-daemon -q \
      -DsparkVersions=4.2 -DscalaVersion=2.13 -DflinkVersions= -DkafkaVersions= -DhiveVersions= \
      :iceberg-spark:iceberg-spark-runtime-4.2_2.13:shadowJar -x test \
 && mkdir /out \
 && cp $(ls spark/v4.2/spark-runtime/build/libs/iceberg-spark-runtime-4.2_2.13-*.jar | grep -vE -- '-(sources|javadoc|tests)\.jar$') /out/ \
 && ls -l /out

# ── 2단계: 실행 이미지
FROM docker.io/apache/spark:4.2.1-scala2.13-java17-python3-ubuntu

USER root

# fail-closed: Iceberg 는 class 61(Java 17) 이다. 베이스를 바꿀 때 Java 11 로 되돌아가면 빌드가 멈춘다.
RUN v=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java.specification.version = //p') \
 && echo "java.specification.version=$v" \
 && [ "${v%%.*}" -ge 17 ] \
 && command -v python3

ARG SCALA_VERSION=2.13

# ★★ hadoop-aws 는 베이스가 번들한 hadoop-client-api 와 **정확히 같은 판**이어야 한다.
#   apache/spark:4.2.1 은 `hadoop-client-api-3.5.0.jar` 를 들고 있다 — 다른 판을 넣으면 런타임에
#   NoSuchMethodError 로 깨지고 빌드는 성공한다. 아래 가드가 둘을 대조한다.
#   ★★ AWS SDK 는 **v2 한 벌**만 두고, 그것은 **AWS 공식 `bundle`** 이다(Gotcha 228). hadoop-aws 는
#   Transfer Manager · Apache HTTP 클라이언트 · bundle 안에서만 이름이 바뀐 httpclient
#   (`software.amazon.awssdk.thirdparty.org.apache.http`)를 직접 참조한다 — iceberg-aws-bundle 로는 S3A 가
#   `NoClassDefFoundError: ...ObjectTransfer` 로 죽는다(실측). 판은 Iceberg main 이 쓰는 2.57.8
#   (hadoop-aws 3.5.0 이 빌드된 2.35.4 보다 새 판 — SDK v2 는 같은 메이저 안에서 하위 호환).
#   대가: bundle 이 700 MB 남짓이라 이미지가 그만큼 크다.
#   ★ 판정은 jdeps 로 했다 — 남는 미해결 참조는 기본으로 꺼진 기능뿐이다(클라이언트 측 암호화 ·
#   S3 Analytics Accelerator · SDK v1 어댑터). 켜려면 해당 jar 를 먼저 넣을 것.
#   ★ url-connection-client 는 bundle 에 없어 따로 넣는다 — Iceberg 의 `http-client.type=urlconnection` 용이다.
#   SDK v1(`aws-java-sdk-bundle`)은 없다 — S3A 자격 제공자는 v2 클래스 이름을 쓴다(spark-defaults-configmap.yaml).
ARG HADOOP_AWS_VERSION=3.5.0
ARG AWS_SDK_V2_VERSION=2.57.8
# ★ hadoop-aws 3.5 는 S3 Analytics Accelerator 를 **필수**(compile) 의존으로 선언하고, S3AFileSystem 초기화가
#   그 클래스(`request.ObjectClient`)를 싣는다 — 3.4 에서는 꺼진 기능이었는데 3.5 에서는 없으면
#   `NoClassDefFoundError` 로 FileSystem.get 이 죽는다(2026-11-09 아래 smoke 가 잡았다). 판은 hadoop-project 3.5.0 의
#   `amazon-s3-analyticsaccelerator-s3.version`. 그 jar 의 미해결 참조(httpclient5)는 analytics 입력 스트림
#   (`fs.s3a.input.stream.type=analytics`, 기본 아님) 경로에서만 쓰인다.
ARG S3_ANALYTICS_ACCELERATOR_VERSION=1.3.1

# 레포 표준 securityContext(runAsUser 1000)에 맞춘다.
# apache/spark 공식 이미지는 uid 185 라 그대로 쓰면 예외 문서화가 필요하다.
RUN groupadd -g 1000 sparkgrp || true \
 && useradd -u 1000 -g 1000 -m -s /bin/bash sparkuser \
 && mkdir -p /opt/spark/jobs /opt/spark/conf \
 && chown -R 1000:1000 /opt/spark

COPY --from=iceberg --chown=1000:1000 /out/ /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/${AWS_SDK_V2_VERSION}/bundle-${AWS_SDK_V2_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/software/amazon/awssdk/url-connection-client/${AWS_SDK_V2_VERSION}/url-connection-client-${AWS_SDK_V2_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar \
  /opt/spark/jars/
ADD --chown=1000:1000 \
  https://repo1.maven.org/maven2/software/amazon/s3/analyticsaccelerator/analyticsaccelerator-s3/${S3_ANALYTICS_ACCELERATOR_VERSION}/analyticsaccelerator-s3-${S3_ANALYTICS_ACCELERATOR_VERSION}.jar \
  /opt/spark/jars/

# Spark Connect 서버는 4.x 부터 배포판에 들어 있다(jars/spark-connect_2.13-*.jar) — 따로 넣지 않는다.
# fail-closed 가드: ① hadoop-aws 와 hadoop-client-api 의 판이 같다 ② Connect jar 가 있다
#   ③ SDK v1 · iceberg-aws-bundle 이 섞이지 않았다 ④ S3 클라이언트가 정확히 jar 한 개에 있다
#   ⑤ hadoop-aws 가 직접 참조하는 셋이 bundle 에 있다 ⑥ Iceberg Spark 4.2 런타임이 정확히 한 개다.
RUN cd /opt/spark/jars \
 && api=$(ls hadoop-client-api-*.jar | sed 's/hadoop-client-api-\(.*\)\.jar/\1/') \
 && { [ "$api" = "${HADOOP_AWS_VERSION}" ] || { echo "hadoop-client-api=$api != hadoop-aws=${HADOOP_AWS_VERSION}"; exit 1; }; } \
 && ls spark-connect_${SCALA_VERSION}-*.jar \
 && { ! ls aws-java-sdk-bundle-*.jar iceberg-aws-bundle-*.jar 2>/dev/null; } \
 && [ "$(ls iceberg-spark-runtime-4.2_${SCALA_VERSION}-*.jar | wc -l)" -eq 1 ] \
 && python3 -c 'import glob,sys,zipfile; h=[j for j in glob.glob("*.jar") if "software/amazon/awssdk/services/s3/S3Client.class" in zipfile.ZipFile(j).namelist()]; print("S3Client in", h); sys.exit(0 if len(h)==1 else 1)' \
 && python3 -c 'import sys,zipfile; n=set(zipfile.ZipFile(sys.argv[1]).namelist()); need=["software/amazon/awssdk/transfer/s3/model/ObjectTransfer.class","software/amazon/awssdk/http/apache/ApacheHttpClient.class","software/amazon/awssdk/thirdparty/org/apache/http/conn/ssl/SSLConnectionSocketFactory.class"]; miss=[c for c in need if c not in n]; print("missing", miss); sys.exit(1 if miss else 0)' bundle-${AWS_SDK_V2_VERSION}.jar \
 && chmod 0644 /opt/spark/jars/*.jar

# ★★ fail-closed smoke(2026-11-09): S3A FileSystem 과 Iceberg S3FileIO 의 클라이언트를 **실제로 만든다**.
#   jar 이름 가드는 "그 jar 가 있다" 까지만 말한다 — 빠진 의존은 클래스를 실을 때 드러난다
#   (ObjectTransfer · ObjectClient 둘 다 빌드는 성공했고 기동에서야 죽었다). 엔드포인트는 닿지 않는 주소라
#   네트워크가 필요 없고(bucket probe 0), 자격은 가짜 값이다.
COPY s3a-smoke.py /tmp/s3a-smoke.py
RUN /opt/spark/bin/spark-submit --master "local[1]" /tmp/s3a-smoke.py > /tmp/smoke.log 2>&1; \
    grep -E "S3A|Iceberg|SMOKE|NoClassDefFound|ClassNotFound" /tmp/smoke.log | head -20; \
    grep -q '^SMOKE-OK' /tmp/smoke.log || exit 1; \
    rm -rf /tmp/s3a-smoke.py /tmp/smoke.log /tmp/spark-*

# TODO-44: JAR 체크섬 검증 추가 (SEC-512 완전 해소)
USER 1000
WORKDIR /opt/spark
