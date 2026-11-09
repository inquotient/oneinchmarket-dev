#!/usr/bin/env bash
# Knative 설치 — local 클러스터용(오퍼레이터 계층 · ArgoCD 밖). 2026-11-10 사용자 결정.
#   bash local/install-knative.sh            # Serving + net-gateway-api (+ Eventing 은 단계 2)
#   bash local/install-knative.sh --check    # 설치 상태만 본다(0 정상 · 1 문제 · 2 측정 불가)
#
# ★ 구성: Serving + net-gateway-api(기존 Istio Gateway `local/ingress` 에 HTTPRoute 로 붙는다).
#   클러스터 쪽 전제(knative-local Gateway · NetworkPolicy)는 git 에 있다 — kubernetes/overlays/local/knative/.
#   **ArgoCD 가 그것을 먼저 적용해야 한다** — 없으면 cluster-local 라우트가 붙을 게이트웨이가 없다.
# ★ 판: 1.24.0(2026-10-27) — 최소 k8s 1.35(이 클러스터 1.36). net-gateway-api 1.24 는 Istio 1.28 ·
#   Gateway API v1.4.1 로 시험됐고 여기는 1.31 · v1.6.0 이다 — 그래서 끝에서 실제 요청으로 확인한다.
# ★ 릴리스 YAML 은 `curl -f` + 알려진 이름이 들어 있는지로 가드한다(Gotcha 148 — 404 본문이 exit 0 으로 온다).
# ★ helm 을 쓰지 않는다 — Knative 는 릴리스 YAML 이 정식 설치 경로다.
set -Eeuo pipefail
trap 'echo "[knative][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KNATIVE_VERSION="${KNATIVE_VERSION:-knative-v1.24.0}"
# 호스트 = <이름>-<네임스페이스>.oneinchmarket.local — 와일드카드 인증서가 한 단계만 덮는다.
KNATIVE_DOMAIN="${KNATIVE_DOMAIN:-oneinchmarket.local}"
DL="${DL:-/tmp/knative-${KNATIVE_VERSION}}"
log() { echo "[knative] $*"; }

fetch() {  # fetch <repo-path> <파일> <반드시 들어 있어야 할 문자열>
  mkdir -p "$DL"
  curl -fsSL --max-time 180 "https://github.com/$1/releases/download/${KNATIVE_VERSION}/$2" -o "$DL/$2"
  grep -q -- "$3" "$DL/$2" || { echo "[knative] $2 가 이상하다($(wc -c <"$DL/$2") 바이트) — '$3' 없음" >&2; exit 1; }
}

check() {
  local rc=0 d
  kubectl get ns knative-serving >/dev/null 2>&1 || { echo "[측정 불가] knative-serving 네임스페이스가 없다"; return 2; }
  for d in activator autoscaler controller webhook net-gateway-api-controller net-gateway-api-webhook; do
    if [ "$(kubectl -n knative-serving get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
      echo "[ok]  knative-serving/$d"
    else
      echo "[FAIL] knative-serving/$d 가 Available 이 아니다"; rc=1
    fi
  done
  local cls; cls=$(kubectl -n knative-serving get cm config-network -o jsonpath='{.data.ingress-class}')
  [ "$cls" = "gateway-api.ingress.networking.knative.dev" ] && echo "[ok]  ingress-class=$cls" || { echo "[FAIL] ingress-class=$cls"; rc=1; }
  kubectl -n local get gateway knative-local >/dev/null 2>&1 && echo "[ok]  local/knative-local Gateway" \
    || { echo "[FAIL] local/knative-local Gateway 가 없다 — ArgoCD 동기화(kubernetes/overlays/local/knative)를 먼저"; rc=1; }
  return $rc
}

if [ "${1:-}" = "--check" ]; then check; exit $?; fi

kubectl -n local get gateway knative-local >/dev/null 2>&1 \
  || { echo "[knative] local/knative-local Gateway 가 없다 — git(kubernetes/overlays/local/knative)이 먼저 동기화돼야 한다" >&2; exit 1; }

# ── Serving ───────────────────────────────────────────────
log "Serving ${KNATIVE_VERSION}"
fetch knative/serving serving-crds.yaml 'name: services.serving.knative.dev'
fetch knative/serving serving-core.yaml 'name: activator'
fetch knative-extensions/net-gateway-api net-gateway-api.yaml 'name: net-gateway-api-controller'
kubectl apply --server-side --force-conflicts -f "$DL/serving-crds.yaml"
kubectl wait --for=condition=Established --timeout=120s crd/services.serving.knative.dev crd/revisions.serving.knative.dev
kubectl apply --server-side --force-conflicts -f "$DL/serving-core.yaml"
kubectl apply --server-side --force-conflicts -f "$DL/net-gateway-api.yaml"
for d in webhook controller activator autoscaler net-gateway-api-controller net-gateway-api-webhook; do
  kubectl -n knative-serving rollout status deploy/"$d" --timeout=300s
done

# ── 설정 ──────────────────────────────────────────────────
# ★ ConfigMap 은 Knative 의 검증 webhook 을 지난다 — webhook 이 뜬 뒤에(위 대기) 고친다.
#   kubectl patch(merge)로 우리 키만 넣는다. 릴리스를 다시 적용하면 `_example` 만 있는 원본으로
#   돌아가므로 **이 스크립트를 다시 돌릴 것**(Gotcha 80).
log "config-network: ingress-class · 호스트 템플릿 · http 는 https 로 돌린다"
# http-protocol=Redirected — 평문 80 의 리다이렉트를 Knative 가 한다. Enabled 로 두면 Knative 의 더 구체적인
#   호스트 라우트가 기존 http 리스너의 리다이렉트(HTTPRoute http-redirect)를 이겨 **평문으로 서비스한다**.
kubectl -n knative-serving patch cm config-network --type merge -p "$(cat <<'EOF'
{"data":{"ingress-class":"gateway-api.ingress.networking.knative.dev",
         "domain-template":"{{.Name}}-{{.Namespace}}.{{.Domain}}",
         "http-protocol":"Redirected"}}
EOF
)"
kubectl -n knative-serving patch cm config-domain --type merge -p "{\"data\":{\"${KNATIVE_DOMAIN}\":\"\"}}"
log "config-gateway: 외부 local/ingress · 내부 local/knative-local"
kubectl -n knative-serving patch cm config-gateway --type merge -p "$(cat <<'EOF'
{"data":{"external-gateways":"- class: istio\n  gateway: local/ingress\n  service: local/ingress-istio\n  supported-features:\n  - HTTPRouteRequestTimeout\n",
         "local-gateways":"- class: istio\n  gateway: local/knative-local\n  service: local/knative-local-istio\n  supported-features:\n  - HTTPRouteRequestTimeout\n"}}
EOF
)"
# secure-pod-defaults — 사용자 컨테이너에 이 레포의 securityContext 관례(runAsNonRoot · drop ALL · RuntimeDefault ·
#   allowPrivilegeEscalation false)를 기본으로 채운다. 명시한 값은 그대로 둔다.
kubectl -n knative-serving patch cm config-features --type merge -p '{"data":{"secure-pod-defaults":"Enabled"}}'

# 되읽어 확인한다(Gotcha 86 — 조용히 빗나간 설정은 아무 일도 하지 않은 것과 같다)
[ "$(kubectl -n knative-serving get cm config-network -o jsonpath='{.data.ingress-class}')" = "gateway-api.ingress.networking.knative.dev" ] \
  || { echo "[knative] config-network 의 ingress-class 가 반영되지 않았다" >&2; exit 1; }
kubectl -n knative-serving get cm config-gateway -o jsonpath='{.data.external-gateways}' | grep -q 'gateway: local/ingress' \
  || { echo "[knative] config-gateway 가 반영되지 않았다" >&2; exit 1; }

check
log "완료 — 실제 요청 확인은 kubernetes/overlays/local/knative 의 머리말 참조"
