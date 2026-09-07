#!/usr/bin/env bash
# ArgoCD 설치 — local 클러스터용 (§8-83)
#
# ★ `infra/scripts/install-argocd.sh` 를 쓰지 않는다:
#   · v2.13.3 을 핀하는데 현재는 v3.x 다
#   · CMP 플러그인을 `ksops` 로 등록하는데 Application 은 `kustomize-sops` 를
#     요구한다(CLAUDE.md 가 적어 둔 결함)
#   · **그리고 SOPS 자체가 필요 없어졌다** — 시크릿은 External Secrets 가
#     OpenBao 에서 가져온다(§8-81·82)
#
# ★ 선행 조건: 레포가 GitLab 에 있어야 한다. ArgoCD 는 git 을 읽어야 동작하고
#   이 GitLab 에는 코드 저장소가 0개였다 — `local/gitlab-repo-bootstrap.sh` 가
#   먼저다.
#
# ★★ 자동 동기화를 켜지 않는다. 이 클러스터에는 ArgoCD 밖에서 만든 것이 많고
#   (오퍼레이터 계층·create-secrets.sh·openbao-init.sh), prune 을 켜면 그것들이
#   "git 에 없다" 는 이유로 지워진다. 실측으로 **고아 리소스 113건**이 잡혔다.
set -Eeuo pipefail
trap 'echo "[argocd][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.2}"
log() { echo "[argocd] $*"; }

log "네임스페이스"
kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "ArgoCD ${ARGOCD_VERSION} 설치"
# ★ --server-side 로 적용한다. install.yaml 이 34,000줄이라 클라이언트 사이드
#   적용은 last-applied-configuration 어노테이션 한계에 걸린다.
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

log "기동 대기"
kubectl -n argocd rollout status deploy/argocd-repo-server            --timeout=600s || true
kubectl -n argocd rollout status deploy/argocd-server                 --timeout=600s || true
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s || true

log "AppProject·Application (local 전용 · 수동 동기화)"
kubectl apply -f "$(dirname "$0")/../argocd/projects/oneinchmarket-local.yaml"
kubectl apply -f "$(dirname "$0")/../argocd/applications/oneinchmarket-local.yaml"

log "상태"
kubectl -n argocd get application oneinchmarket-local --no-headers || true
echo
log "admin 비밀번호 조회:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
log "UI:  kubectl -n argocd port-forward svc/argocd-server 8090:80"
