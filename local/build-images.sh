#!/usr/bin/env bash
# 커스텀 이미지 8종 빌드 후 k3s containerd 로 직접 반입한다.
# 레지스트리(registry.oneinchmarket.co.kr)를 참조하는 매니페스트가 없고
# imagePullSecrets 도 없으므로, 로컬에서는 import 가 정답이다.
#
# 왜 podman 인가 —
#   ① 데몬이 없다. 빌드가 끝나면 메모리를 전혀 남기지 않는다.
#      48GB 예산에서 상주 데몬 하나가 아깝다.
#   ② docker.io 의 containerd 는 k3s 와 소켓 경로를 다툰다. 이 호스트에서는
#      /run/containerd/containerd.sock 이 디렉터리로 존재해 기동에 실패했다
#      (Docker Desktop WSL 통합 잔재로 추정):
#        containerd: failed to create unix socket ...: is a directory
#   ③ Docker Desktop 은 자체 WSL 배포판을 띄워 같은 예산을 경합한다.
set -Eeuo pipefail
trap 'echo "[build][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log() { echo "[build] $*"; }

# k3s 와 경합하지 않도록 도커 계열 서비스를 내린다 (패키지는 남긴다)
for s in docker.socket docker containerd; do
  systemctl list-unit-files "$s"* >/dev/null 2>&1 && sudo systemctl disable --now "$s" 2>/dev/null || true
done

# ★ 빌드는 --network host 로 한다.
#   `podman network ls` 에 k3s 가 만든 `cilium`(cilium-cni) 네트워크가 함께
#   보이고, 빌드 컨테이너가 그쪽을 잡으면 밖으로 나가지 못한다.
#   실제로 HBase tarball 을 받다 curl(28) Failed to connect 로 죽었다.
#   호스트에서는 되고 컨테이너에서만 안 되므로 원인을 찾는 데 시간이 든다.
if ! command -v podman >/dev/null 2>&1; then
  log "podman 설치"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman
fi
podman --version

log "oneinch/spark-iceberg 빌드"
sudo podman build --format docker --network host \
  -t oneinch/spark-iceberg:latest -t oneinch/spark-iceberg:3.5.6 \
  "${REPO_ROOT}/docker/spark-iceberg"

log "oneinch/livy 빌드"
sudo podman build --format docker --network host \
  -t oneinch/livy:latest -t oneinch/livy:0.9.0-incubating \
  "${REPO_ROOT}/docker/livy"

log "oneinch/ranger-usersync 빌드"
# Ranger UserSync 는 공식 이미지가 없다. Dockerfile 은 upstream 에 있다
#   apache/ranger @ release-ranger-2.9.0
#     dev-support/ranger-docker/Dockerfile.ranger-usersync
# 베이스(apache/ranger-base)와 릴리스 tarball 모두 Apache 배포물이다.
sudo podman build --format docker --network host \
  -t oneinch/ranger-usersync:latest -t oneinch/ranger-usersync:2.9.0 \
  "${REPO_ROOT}/docker/ranger-usersync"

log "oneinch/hbase 빌드"
# HBase 는 공식 이미지가 없다(Docker Hub 에 apache/hbase 저장소가 없음).
# v1/hbase/Dockerfile 을 고쳐 docker/hbase 로 옮겼다 — 상세는 그 파일 주석.
sudo podman build --format docker --network host \
  -t oneinch/hbase:latest -t oneinch/hbase:3.0.0 \
  "${REPO_ROOT}/docker/hbase"

log "oneinch/ranger-hdfs-plugin 빌드"
# Ranger 2.9 의 REST 클라이언트는 Jersey 1 을 쓰는데 Hadoop 3.5 가 그것을
# 걷어냈다. upstream 이 master 에서 이미 Jersey 2 로 옮겼고, 그 수정을 2.9.0 에
# 백포트해 빌드한다 — 상세와 실패했던 우회들은
# docker/ranger-hdfs-plugin/Dockerfile 주석과 §8-68 에 있다.
# Ranger 3.0.0 이 릴리스되면 이 이미지는 지운다.
# ★ 오래 걸린다 — Maven 이 Ranger 부모 모듈 의존성을 받는다.
sudo podman build --format docker --network host \
  -t oneinch/ranger-hdfs-plugin:latest -t oneinch/ranger-hdfs-plugin:2.9.0-jersey2 \
  "${REPO_ROOT}/docker/ranger-hdfs-plugin"

log "oneinch/ranger-hbase-plugin 빌드"
# HBase 3 이 구 protobuf 패키지를 걷어내 Ranger 2.9 코프로세서가 적재되지
# 못한다(마스터 ABORT). ★ 이것은 §8-68 의 Jersey 건과 달리 **백포트가 아니다** —
# Ranger master 조차 hbase 2.6.0 을 겨냥해 대조할 구현이 없다. 우리가 이식했다.
# 상세는 docker/ranger-hbase-plugin/Dockerfile 주석과 §8-69.
# ★ docker/hbase 의 HBASE_VERSION 과 **짝이 맞아야 한다.**
# ★ 오래 걸린다 — JDK 8/17 두 단계로 Ranger 를 빌드한다.
sudo podman build --format docker --network host \
  -t oneinch/ranger-hbase-plugin:latest -t oneinch/ranger-hbase-plugin:2.9.0-hbase3 \
  "${REPO_ROOT}/docker/ranger-hbase-plugin"

log "oneinch/ranger-hive-plugin 빌드"
# Hive 4 가 HiveConf.ConfVars 상수를 개명하고 인덱스 연산을 걷어내 Ranger 2.9
# Hive 플러그인이 기동하지 못한다(NoSuchFieldError: PREEXECHOOKS).
# ★ 이것은 §8-69 의 HBase 와 달리 **백포트**다 — upstream master 가 Hive 4 를
# 겨냥한다. 상세는 docker/ranger-hive-plugin/Dockerfile 주석과 §8-70.
sudo podman build --format docker --network host \n  -t oneinch/ranger-hive-plugin:latest -t oneinch/ranger-hive-plugin:2.9.0-hive4 \n  "${REPO_ROOT}/docker/ranger-hive-plugin"

log "oneinch/jenkins 빌드"
# 공식 이미지에는 플러그인이 없다. JCasC 로 관리자 계정을 선언하려면
# configuration-as-code 플러그인이 필요하고, 런타임에 받으면 SEC-512 다.
# 상세는 docker/jenkins/Dockerfile 주석.
sudo podman build --format docker --network host \
  -t oneinch/jenkins:latest -t oneinch/jenkins:lts \
  "${REPO_ROOT}/docker/jenkins"

log "k3s containerd 로 반입 (namespace k8s.io)"
# ★ 매니페스트가 참조하는 **정확한 태그**를 반입해야 한다. :latest 만 넣으면
#   버전 태그를 쓰는 워크로드가 ImagePullBackOff 로 멈춘다 —
#   ranger-hdfs-plugin 이 실제로 그랬다(hadoop-namenode 가 10분 Init 대기).
for img in oneinch/spark-iceberg:latest oneinch/livy:latest oneinch/ranger-usersync:latest \
           oneinch/hbase:latest oneinch/hbase:3.0.0 \
           oneinch/jenkins:latest \
           oneinch/ranger-hdfs-plugin:latest oneinch/ranger-hdfs-plugin:2.9.0-jersey2 \
           oneinch/ranger-hbase-plugin:latest oneinch/ranger-hbase-plugin:2.9.0-hbase3 \n           oneinch/ranger-hive-plugin:latest oneinch/ranger-hive-plugin:2.9.0-hive4; do
  sudo podman save --format docker-archive "localhost/$img" \
    | sudo k3s ctr -n k8s.io images import --base-name "docker.io/$img" -
  # ★ --base-name 이 항상 docker.io 이름을 만들어 주지는 않는다.
  #   아카이브가 이미 localhost/... 이름을 갖고 있으면 그대로 들어가고
  #   매니페스트가 참조하는 docker.io/... 는 생기지 않아 ImagePullBackOff 가
  #   난다 — jenkins 에서 실제로 그랬다. 명시적으로 태그해 확정한다.
  sudo k3s ctr -n k8s.io images tag --force "localhost/$img" "docker.io/$img" >/dev/null 2>&1 || true
  log "  imported $img"
done

log "반입 확인"
sudo k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep oneinch || true
log "완료 — 상주 데몬 없음"
