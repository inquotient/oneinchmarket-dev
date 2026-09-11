#!/usr/bin/env bash
# Gravitee 의 API 정의를 git 에서 클러스터로 밀어 넣는다.
#
# ★★★ 왜 필요한가 — **API 정의는 MongoDB 에만 살기 때문이다.**
#   ArgoCD 가 관리하는 것은 Gravitee 의 *워크로드*이지 그 안의 *내용물*이
#   아니다. 손으로 만든 API 는 git 에 흔적이 없어, 클러스터를 다시 세우면
#   `/managed` HTTPRoute 는 남고 Gravitee 는 비어 있어 **404** 가 된다.
#   실측(2026-09-12): git 안 정의 0건 · MongoDB 안 1건.
#   §25(이 레포 밖의 노드 상태)와 같은 부류의 구멍이라 같은 방식으로 막는다.
#
# ★ 원천은 `local/gravitee-apis/*.json` 하나다(Gotcha 117).
#   `local/pricing-catalog.yaml` + `openmeter-pricing.sh` 와 같은 모양이다.
#
# 멱등하다 — 같은 이름의 API 가 이미 있으면 만들지 않고, 플랜이 이미
# PUBLISHED 면 다시 게시하지 않으며, 이미 STARTED 면 다시 시작하지 않는다.
#
# ★★ 복귀 조건 — API 가 여러 개가 되면 **Gravitee Kubernetes Operator(GKO)**
#   로 옮길 것. CRD 로 GitOps 가 되지만 CRD 가 늘면
#   argocd-application-controller 의 캐시가 함께 자란다(Gotcha 119) — 지금
#   노드가 89% 라 그 비용을 낼 때가 아니다.
set -Eeuo pipefail
trap 'echo "[gravitee][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${NS:-local}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/gravitee-apis"
PORT="${PORT:-18083}"
log() { echo "[gravitee] $*"; }

tmp=$(mktemp -d); trap 'shred -u "$tmp"/* 2>/dev/null; rm -rf "$tmp"; kill %1 2>/dev/null || true' EXIT
kubectl -n "$NS" get secret gravitee-secret -o jsonpath='{.data.admin-password}' | base64 -d > "$tmp/pw"
[ -s "$tmp/pw" ] || { echo "[gravitee] admin-password 가 비었다 — create-secrets.sh 를 볼 것" >&2; exit 1; }

kubectl -n "$NS" port-forward deploy/gravitee-management-api "$PORT:8083" >/dev/null 2>&1 &
for i in $(seq 1 20); do
  sleep 1
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/management" && break
  [ "$i" = "20" ] && { echo "[gravitee] management-api 에 붙지 못했다" >&2; exit 1; }
done

B="http://127.0.0.1:$PORT/management/v2/environments/DEFAULT"
AUTH=(-u "admin:$(cat "$tmp/pw")")

# ★ 자격이 실제로 통하는지 **먼저** 확인한다. 401 이면 인증 공급자가 빠진
#   것이고(Gotcha 155), 그 상태로 진행하면 전부 실패한다.
code=$(curl -s "${AUTH[@]}" -o /dev/null -w '%{http_code}' "$B/apis?perPage=1")
[ "$code" = "200" ] || { echo "[gravitee] 관리 API 가 $code 다 — security 절/자격을 볼 것(Gotcha 155)" >&2; exit 1; }

shopt -s nullglob
files=("$SRC"/*.json)
[ "${#files[@]}" -gt 0 ] || { echo "[gravitee] $SRC 에 정의가 없다" >&2; exit 1; }

for f in "${files[@]}"; do
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  log "── $name"

  id=$(curl -s "${AUTH[@]}" "$B/apis?perPage=100" | python3 -c "
import json,sys
for a in json.load(sys.stdin).get('data',[]):
    if a.get('name')==sys.argv[1]: print(a['id']); break
" "$name")

  if [ -z "$id" ]; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("_plan",None); json.dump(d,open(sys.argv[2],"w"))' "$f" "$tmp/api.json"
    id=$(curl -s "${AUTH[@]}" -X POST -H 'Content-Type: application/json' --data @"$tmp/api.json" "$B/apis" \
         | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    [ -n "$id" ] || { echo "[gravitee] $name 생성 실패" >&2; exit 1; }
    log "  생성됨 id=$id"
  else
    log "  이미 있다 id=$id"
  fi

  # ★★ 플랜은 `statuses=` 를 줘야 보인다 — 기본 목록은 PUBLISHED 만 돌려주므로
  #   방금 만든 STAGING 플랜이 **없는 것처럼** 보인다(Gotcha 156).
  pid=$(curl -s "${AUTH[@]}" "$B/apis/$id/plans?statuses=STAGING,PUBLISHED" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['data'][0]['id'] if d.get('data') else '')")
  if [ -z "$pid" ]; then
    python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["_plan"], open(sys.argv[2],"w"))' "$f" "$tmp/plan.json"
    pid=$(curl -s "${AUTH[@]}" -X POST -H 'Content-Type: application/json' --data @"$tmp/plan.json" "$B/apis/$id/plans" \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    [ -n "$pid" ] || { echo "[gravitee] $name 의 플랜 생성 실패" >&2; exit 1; }
    log "  플랜 생성됨"
  fi

  st=$(curl -s "${AUTH[@]}" "$B/apis/$id/plans?statuses=STAGING,PUBLISHED" | python3 -c "
import json,sys
d=json.load(sys.stdin); print(d['data'][0].get('status','') if d.get('data') else '')")
  # ★ 본문의 status 는 무시되므로 _publish 를 따로 부른다(Gotcha 156).
  if [ "$st" != "PUBLISHED" ]; then
    curl -s "${AUTH[@]}" -o /dev/null -X POST "$B/apis/$id/plans/$pid/_publish"
    log "  플랜 게시됨"
  fi

  state=$(curl -s "${AUTH[@]}" "$B/apis/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')
  if [ "$state" != "STARTED" ]; then
    curl -s "${AUTH[@]}" -o /dev/null -X POST "$B/apis/$id/_start"
    log "  시작됨"
  fi

  # ★★ 판정을 "명령이 끝났다" 로 하지 말 것(Gotcha 12) — 되읽어 확인한다.
  final=$(curl -s "${AUTH[@]}" "$B/apis/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("state",""))')
  [ "$final" = "STARTED" ] || { echo "[gravitee] $name 이 STARTED 가 아니다($final)" >&2; exit 1; }
  log "  확인: STARTED"
done
log "완료 — API ${#files[@]}건"
