#!/usr/bin/env bash
# 커스텀 이미지 2종 빌드 후 k3s containerd 로 직접 반입한다.
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

if ! command -v podman >/dev/null 2>&1; then
  log "podman 설치"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman
fi
podman --version

log "oneinch/spark-iceberg 빌드"
sudo podman build --format docker \
  -t oneinch/spark-iceberg:latest -t oneinch/spark-iceberg:3.5.6 \
  "${REPO_ROOT}/docker/spark-iceberg"

log "oneinch/livy 빌드"
sudo podman build --format docker \
  -t oneinch/livy:latest -t oneinch/livy:0.9.0-incubating \
  "${REPO_ROOT}/docker/livy"

log "oneinch/ranger-usersync 빌드"
# Ranger UserSync 는 공식 이미지가 없다. Dockerfile 은 upstream 에 있다
#   apache/ranger @ release-ranger-2.9.0
#     dev-support/ranger-docker/Dockerfile.ranger-usersync
# 베이스(apache/ranger-base)와 릴리스 tarball 모두 Apache 배포물이다.
sudo podman build --format docker \
  -t oneinch/ranger-usersync:latest -t oneinch/ranger-usersync:2.9.0 \
  "${REPO_ROOT}/docker/ranger-usersync"

log "k3s containerd 로 반입 (namespace k8s.io)"
for img in oneinch/spark-iceberg:latest oneinch/livy:latest oneinch/ranger-usersync:latest; do
  sudo podman save --format docker-archive "localhost/$img" \
    | sudo k3s ctr -n k8s.io images import --base-name "docker.io/$img" -
  log "  imported $img"
done

log "반입 확인"
sudo k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep oneinch || true
log "완료 — 상주 데몬 없음"
