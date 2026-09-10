#!/usr/bin/env bash
# 오퍼레이터 계층에 resource requests 를 준다 — BestEffort 를 없앤다
#
# ★★ 왜 필요한가 — requests 가 없으면 QoS 가 BestEffort 가 되고, 메모리
#   압박 시 가장 먼저 축출된다. 무엇이 멈추는지가 분명하다:
#     local-path-provisioner        -> 새 PVC 가 묶이지 않는다
#     cert-manager                  -> 인증서 갱신이 멈춘다
#     argocd-application-controller -> GitOps 가 멈춘다
#   이 노드는 §11-4 기준 `필요 56.6 vs 가용 47.6` 이라 가정이 아니다.
#
# ★ 값은 실측에서 나왔다(kubectl top, 2026-09-08). 추측한 requests 는
#   스케줄러를 속일 뿐이다 — 너무 낮으면 축출되고 너무 높으면 다른 것이
#   스케줄되지 못한다. 관측값에 여유를 얹었다.
#
# ★★ 이 스크립트는 재실행 가능해야 한다. 대상이 전부 상류 매니페스트로
#   설치되기 때문이다(cert-manager·ArgoCD 는 kubectl apply -f <upstream>,
#   trivy-operator·policy-reporter 는 helm). 그것들을 다시 설치하면 이 패치가
#   되돌아간다 — 설치 뒤에 이 스크립트를 다시 돌릴 것.
#
# ★★★ local-path-provisioner 는 예외다 — k3s 의 애드온이라
#   /var/lib/rancher/k3s/server/manifests/local-storage.yaml 에서 재적용된다.
#   여기서 패치해도 k3s 재시작이면 되돌아간다. 지속시키려면 그 파일을
#   고쳐야 하고, 그것은 노드 상태라 이 레포 밖이다(§8-93 에 남겼다).
#
# 사용
#   local/set-operator-requests.sh          # 적용
#   local/set-operator-requests.sh --check  # 적용하지 않고 BestEffort 만 센다
set -Eeuo pipefail
trap 'echo "[req][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

CHECK=no
[ "${1:-}" = "--check" ] && CHECK=yes

log() { echo "[req] $*"; }

# ns  kind         name                              container                         cpuReq memReq memLim
TARGETS="
# ★★★ 2026-09-10: 1Gi 에서 **OOMKilled 가 96회** 일어났다(17시간간).
#   증상이 원인과 아주 멀다 — 파드는 `Running` 으로 보이고(0/1 이지만),
#   드러나는 것은 **동기화가 끝나지 않는 것**이다: 작업이 옛 리비전에
#   고정된 채 Running 으로 남고, 이미 끝난 훅을 기다린다고 말하며,
#   새 커밋을 집어 들지 않는다. 컨트롤러가 매번 동기화 도중에
#   죽었기 때문이다. 판정은 `restartCount` 와 `lastState.terminated.reason`
#   (=OOMKilled, exitCode 137)로 한다.
#   ★ 컬러스터가 커지면 이 값을 다시 봐야 한다 — 컨트롤러는 클러스터
#     전체를 캐시하므로 CRD·리소스 수에 비례해 자란다(이때 실측:
#     CRD 112 · 관리 리소스 541 · 파드 130여).
argocd          statefulset argocd-application-controller     argocd-application-controller     100m 768Mi 2Gi
argocd          deployment  argocd-repo-server                argocd-repo-server                50m  192Mi 512Mi
argocd          deployment  argocd-server                     argocd-server                     50m  128Mi 256Mi
argocd          deployment  argocd-applicationset-controller  argocd-applicationset-controller  20m  64Mi  128Mi
argocd          deployment  argocd-dex-server                 dex                               20m  64Mi  128Mi
argocd          deployment  argocd-notifications-controller   argocd-notifications-controller   20m  64Mi  128Mi
argocd          deployment  argocd-redis                      redis                             20m  64Mi  128Mi
cert-manager    deployment  cert-manager                      cert-manager-controller           20m  64Mi  192Mi
cert-manager    deployment  cert-manager-cainjector           cert-manager-cainjector           20m  128Mi 256Mi
cert-manager    deployment  cert-manager-webhook              cert-manager-webhook              20m  64Mi  128Mi
kube-system     deployment  cilium-operator                   cilium-operator                   30m  128Mi 256Mi
kube-system     daemonset   cilium-envoy                      cilium-envoy                      30m  64Mi  192Mi
kube-system     deployment  local-path-provisioner            local-path-provisioner            20m  64Mi  128Mi
policy-reporter deployment  policy-reporter                   policy-reporter                   20m  96Mi  192Mi
trivy-system    deployment  trivy-operator                    trivy-operator                    50m  512Mi 1Gi
"

count_besteffort() {
  kubectl get pod -A -o json 2>/dev/null > /tmp/req-pods.json
  python3 - <<'PY'
import json
d = json.load(open("/tmp/req-pods.json"))
be = [(p["metadata"]["namespace"], p["metadata"]["name"])
      for p in d["items"]
      if p["status"].get("phase") in ("Running", "Pending")
      and p["status"].get("qosClass") == "BestEffort"]
print("  BestEffort 파드: %d" % len(be))
for ns, n in sorted(be):
    print("     %s/%s" % (ns, n))
PY
}

if [ "$CHECK" = yes ]; then
  log "확인만 한다"
  count_besteffort
  exit 0
fi

log "적용 전"
count_besteffort
echo

echo "$TARGETS" | while read -r ns kind name container cpureq memreq memlim; do
  [ -z "${ns:-}" ] && continue
  if ! kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    echo "  건너뜀(없음): $ns/$kind/$name"
    continue
  fi
  # ★ --containers 로 대상을 좁힌다. 사이드카가 있는 워크로드에서 전부를
  #   같은 값으로 덮으면 엉뚱한 컨테이너가 굶는다.
  kubectl -n "$ns" set resources "$kind/$name" \
    --containers="$container" \
    --requests="cpu=${cpureq},memory=${memreq}" \
    --limits="memory=${memlim}" >/dev/null
  printf "  %-16s %-38s req=%s/%s limit=%s\n" "$ns" "$name" "$cpureq" "$memreq" "$memlim"
done

echo
log "롤아웃 대기"
echo "$TARGETS" | while read -r ns kind name _rest; do
  [ -z "${ns:-}" ] && continue
  kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1 || continue
  if kubectl -n "$ns" rollout status "$kind/$name" --timeout=180s >/dev/null 2>&1; then
    echo "  ok  $ns/$name"
  else
    echo "  ** 지연 $ns/$name"
  fi
done

echo
log "적용 후"
count_besteffort
echo
log "★ 상류 매니페스트를 다시 설치하면(install-operators.sh · install-argocd.sh)"
log "  이 패치가 되돌아간다. 그때 이 스크립트를 다시 돌릴 것."
log "★ local-path-provisioner 는 k3s 애드온이라 k3s 재시작에도 되돌아간다(§8-93)."
