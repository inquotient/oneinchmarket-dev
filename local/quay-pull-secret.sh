#!/usr/bin/env bash
# quay.io pull 자격을 클러스터에 넣는다. **이 레포 밖 원천**이다.
#
# 왜 필요한가
# -----------
# MinIO 가 2026-09-11 에 Docker Hub 에서 **저장소째 삭제**됐다. 실측:
#   https://hub.docker.com/v2/repositories/minio/minio/   -> {"message":"object not found"}
#   node 에서 pull                                        -> pull access denied, repository does not exist
#   mirror.gcr.io / public.ecr.aws                        -> 둘 다 없음
# 남은 공식 경로는 quay.io 뿐인데 그쪽은 2026-09-24 부터 익명 pull 을 막는다.
# 실측으로 **401(인증 필요)이고 404 가 아니다** — 자격이 있으면 받아진다:
#   curl -I https://quay.io/v2/minio/minio/manifests/<tag>  -> 401
#   www-authenticate: Bearer realm="https://quay.io/v2/auth",...,scope="repository:minio/minio:pull"
#
# ★ 그리고 마지막 커뮤니티 릴리스에는 **CVE-2026-40344**(CVSS 8.8, Snowball
#   auto-extract 인증 우회)가 남아 있고 상류 레포는 archived 다 — 고쳐지지
#   않는다. 이것을 알고 유지하기로 결정했다(2026-10-05). 대체(Garage·
#   SeaweedFS)로 옮기는 선택지는 그대로 열려 있고, 서비스 이름과 자격을
#   유지하면 매니페스트 24개 중 3곳만 손대면 된다 — 그 조사는 끝나 있다.
#
# 쓰는 법
# -------
#   QUAY_USER='<robot 이름, 예: myorg+pull>' QUAY_TOKEN='<robot 토큰>' \
#     bash local/quay-pull-secret.sh
#
# ★ 개인 계정 비밀번호가 아니라 **robot 토큰**을 쓸 것 — 범위가 pull 로 좁고
#   회수가 쉽다. quay.io > Account Settings > Robot Accounts 에서 만든다.
# ★★ 값을 인자로 받지 않는다 — `ps` 와 셸 히스토리에 남기 때문이다.
#   `--check` 는 Secret 이 실제로 통하는지 **토큰을 받아서** 확인한다.
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NS="${NS:-local}"
SECRET="${SECRET:-quay-pull-secret}"

log() { echo "[quay] $*"; }

if [ "${1:-}" = "--check" ]; then
  # ★ "Secret 이 있다" 가 아니라 "그 자격으로 토큰이 나온다" 로 판정한다.
  #   있는데 틀린 자격은 증상이 ImagePullBackOff 하나뿐이라 원인이 멀다.
  kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1 \
    || { echo "[quay] $SECRET 이 없다" >&2; exit 1; }
  d=$(mktemp -d); trap 'shred -u "$d"/* 2>/dev/null; rmdir "$d"' EXIT
  kubectl -n "$NS" get secret "$SECRET" \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$d/cfg.json"
  auth=$(python3 - "$d/cfg.json" <<'PY'
import base64, json, sys
cfg = json.load(open(sys.argv[1]))
a = cfg.get("auths", {}).get("quay.io", {})
if "auth" in a:
    sys.stdout.write(base64.b64decode(a["auth"]).decode())
else:
    sys.stdout.write(f'{a.get("username","")}:{a.get("password","")}')
PY
)
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$auth" \
    "https://quay.io/v2/auth?service=quay.io&scope=repository:minio/minio:pull")
  if [ "$code" = "200" ]; then log "자격 유효 (토큰 발급 200)"; exit 0; fi
  echo "[quay] 자격이 통하지 않는다 (토큰 발급 $code)" >&2; exit 1
fi

[ -n "${QUAY_USER:-}"  ] || { echo "[quay] QUAY_USER 가 필요하다"  >&2; exit 1; }
[ -n "${QUAY_TOKEN:-}" ] || { echo "[quay] QUAY_TOKEN 이 필요하다" >&2; exit 1; }

# ★ 먼저 자격이 실제로 통하는지 확인한다 — 틀린 자격으로 Secret 을 만들면
#   증상이 ImagePullBackOff 하나뿐이고 "레지스트리가 이상하다" 로 읽힌다.
code=$(curl -s -o /dev/null -w '%{http_code}' -u "${QUAY_USER}:${QUAY_TOKEN}" \
  "https://quay.io/v2/auth?service=quay.io&scope=repository:minio/minio:pull")
[ "$code" = "200" ] || { echo "[quay] 자격이 통하지 않는다 (토큰 발급 $code) — Secret 을 만들지 않았다" >&2; exit 1; }
log "자격 확인됨 — Secret 을 만든다"

kubectl -n "$NS" create secret docker-registry "$SECRET" \
  --docker-server=quay.io \
  --docker-username="$QUAY_USER" \
  --docker-password="$QUAY_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" label secret "$SECRET" \
  app.kubernetes.io/part-of=oneinchmarket \
  app.kubernetes.io/managed-by=local-script --overwrite >/dev/null
log "$NS/$SECRET 준비 완료 — 참조하는 워크로드: minio · minio-bootstrap · rotate-minio · openbao-snapshot"
log "확인: bash local/quay-pull-secret.sh --check"
