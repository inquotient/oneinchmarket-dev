#!/usr/bin/env bash
# install-istio.sh - Istio Ambient Mode 설치
# 사용법: KUBECONFIG=./kubeconfig.yaml ./install-istio.sh
set -euo pipefail

ISTIO_VERSION="${ISTIO_VERSION:-1.24.2}"

echo "=== Istio ${ISTIO_VERSION} 다운로드 ==="
curl -L https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh -
export PATH="$PWD/istio-${ISTIO_VERSION}/bin:$PATH"

echo "=== Istio Ambient Mode 설치 ==="
istioctl install --set profile=ambient -y

echo "=== Istio 네임스페이스 레이블 설정 ==="
kubectl label namespace default istio.io/dataplane-mode=ambient --overwrite

echo "=== Istio 상태 확인 ==="
istioctl verify-install
kubectl get pods -n istio-system

echo "=== Istio Ambient Mode 설치 완료 ==="
