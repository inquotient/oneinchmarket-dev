#!/usr/bin/env bash
# install-argocd.sh - ArgoCD + KSOPS 설치
# 사용법: KUBECONFIG=./kubeconfig.yaml ./install-argocd.sh
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.3}"

echo "=== ArgoCD 네임스페이스 생성 ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "=== ArgoCD ${ARGOCD_VERSION} 설치 ==="
kubectl apply -n argocd -f \
  "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "=== ArgoCD Pod 대기 ==="
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/part-of=argocd -n argocd --timeout=300s

echo "=== KSOPS ConfigManagementPlugin 설정 ==="
kubectl apply -n argocd -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: ksops
    spec:
      init:
        command: ["/bin/sh", "-c"]
        args: ["echo 'Initializing KSOPS'"]
      generate:
        command: ["/bin/sh", "-c"]
        args:
          - |
            kustomize build --enable-alpha-plugins .
EOF

echo "=== SOPS age 키 시크릿 생성 안내 ==="
echo "age 키를 생성한 후 다음 명령으로 등록하세요:"
echo "  kubectl create secret generic sops-age \\"
echo "    --namespace=argocd \\"
echo "    --from-file=keys.txt=keys.txt"

echo ""
echo "=== ArgoCD 초기 admin 비밀번호 ==="
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo ""

echo "=== ArgoCD 설치 완료 ==="
