#!/usr/bin/env bash
# 커스텀 이미지 2종 빌드 후 k3s containerd 로 직접 반입한다.
# 레지스트리(registry.oneinchmarket.co.kr)는 어떤 매니페스트도 참조하지
# 않고 imagePullSecrets 도 없으므로, 로컬에서는 import 가 정답이다.
#
# Docker Desktop 대신 배포판 내 docker.io 를 쓴다 — Docker Desktop 은
# 자체 WSL 배포판을 띄워 같은 48GB 예산을 경합한다.
# 빌드가 끝나면 데몬을 정지해 메모리를 되돌린다.
set -Eeuo pipefail
trap 'echo "[build][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log() { echo "[build] $*"; }

if ! systemctl is-active --quiet docker 2>/dev/null; then
  if ! dpkg -s docker.io >/dev/null 2>&1; then
    log "docker.io 설치"
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io
  fi
  log "dockerd 기동"
  sudo systemctl start docker
fi
sudo docker version --format '{{.Server.Version}}'

log "oneinch/spark-iceberg:latest 빌드"
sudo docker build -t oneinch/spark-iceberg:latest -t oneinch/spark-iceberg:3.5.6 \
  "${REPO_ROOT}/docker/spark-iceberg"

log "oneinch/livy:latest 빌드"
sudo docker build -t oneinch/livy:latest -t oneinch/livy:0.9.0-incubating \
  "${REPO_ROOT}/docker/livy"

log "k3s containerd 로 반입 (namespace k8s.io)"
for img in oneinch/spark-iceberg:latest oneinch/livy:latest; do
  sudo docker save "$img" | sudo k3s ctr -n k8s.io images import -
  log "  imported $img"
done

log "반입 확인"
sudo k3s ctr -n k8s.io images ls | grep oneinch || true

log "dockerd 정지 (메모리 회수)"
sudo systemctl stop docker

log "완료"
