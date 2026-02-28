#!/usr/bin/env bash
# install-reloader.sh - Stakater Reloader 설치
# Secret/ConfigMap 변경 시 관련 Pod 자동 Rolling Restart
# 사용법: KUBECONFIG=./kubeconfig.yaml ./install-reloader.sh
set -euo pipefail

RELOADER_VERSION="${RELOADER_VERSION:-v1.2.0}"

echo "=== Stakater Reloader ${RELOADER_VERSION} 설치 ==="
kubectl apply -f \
  "https://raw.githubusercontent.com/stakater/Reloader/${RELOADER_VERSION}/deployments/kubernetes/reloader.yaml"

echo "=== Reloader Pod 대기 ==="
kubectl wait --for=condition=Ready pod -l app=reloader-reloader --timeout=120s

echo "=== Reloader 상태 확인 ==="
kubectl get pods -l app=reloader-reloader

echo ""
echo "=== 사용 방법 ==="
echo "StatefulSet/Deployment에 다음 어노테이션을 추가하세요:"
echo '  metadata:'
echo '    annotations:'
echo '      reloader.stakater.com/auto: "true"'

echo "=== Stakater Reloader 설치 완료 ==="
