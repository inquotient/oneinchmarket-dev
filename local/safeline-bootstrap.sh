#!/usr/bin/env bash
# SafeLine 의 보호 대상(사이트)을 git 에서 밀어 넣는다 — 멱등.
#
# ★★★ 왜 이 스크립트가 필요한가 — Gravitee 와 **똑같은 자리**다(Gotcha 159).
#   사이트 정의는 mgt 의 PostgreSQL(`safeline` DB, `mgt_website` 테이블)에만
#   살고 매니페스트에는 없다. 그대로 두면 클러스터를 다시 세울 때
#   HTTPRoute 는 git 에서 되살아나는데 SafeLine 은 **보호 대상이 0건**이라
#   그 경로가 죽는다. 그래서 원천을 `local/safeline-sites/*.json` 에 두고
#   이 스크립트가 API 로 적용한다.
#
# ★★ mgt 의 DB 를 직접 고치지 않는다. `mgt_website` 는 컬럼이 58개이고
#   JSONB 셋(`server_names`·`ports`·`upstreams`)의 모양이 문서화돼 있지 않다.
#   밖에서 행을 지어 넣는 것은 **계약을 지어내는 것**이고, 이 레포는 그것을
#   하지 않기로 적어 두었다(Gotcha 94: 틀린 계약은 없는 계약보다 나쁘다).
#   앱이 자기 행을 쓰게 하고 우리는 API 만 부른다.
#
# ────────────────────────────────────────────────────────────────
# 로그인 계약 — 2026-09-12 에 **SPA 번들에서 읽어냈다**
# ────────────────────────────────────────────────────────────────
# 비밀번호를 평문으로 보내면 `invalid request` 다. mgt 는 AES-CBC 로 암호화한
# 값을 받는다. UI 번들(`/assets/index-D8wTFuLH.js`)의 실제 코드:
#
#   b = CryptoJS.enc.Hex.stringify(WordArray.random(8))   // 16자 ASCII
#   B = AES.encrypt(pw, Utf8.parse(aesKey),
#                   {iv: Utf8.parse(b), mode: CBC, padding: Pkcs7})
#   userLogin({username, password: btoa(b + latin1(B.ciphertext)), csrf_token})
#
# 즉 세 단계다:
#   1) GET  /api/open/system/key   -> AES 키(문자열 그대로 키 바이트로 쓴다)
#   2) GET  /api/open/auth/csrf    -> {"data":{"csrf_token":...}}
#   3) POST /api/open/auth/login   {"username","password","csrf_token"}
#        password = base64( IV 16자 ASCII + 암호문 )
#        ★ IV 는 **16자 hex 문자열 그 자체의 ASCII 바이트**다.
#          hex 를 디코드한 8바이트가 아니다 — 번들이 Utf8.parse(b) 를 쓴다.
#
# ★ 이 사연을 적어 두는 이유: 증상이 원인을 가리키지 않는다. 평문으로 보내면
#   `invalid request` 만 나오고 어느 필드가 문제인지 말하지 않아서,
#   자격이 틀렸다고 읽게 된다(실제로 그렇게 헤맸다). csrf 를 본문에 넣으면
#   메시지가 `invalid csrf token` 에서 `invalid request` 로 **바뀌는 것**이
#   갈림길이었다 — csrf 는 통과했고 남은 것은 본문이라는 뜻이다.
#
# ★★ SPA 는 요청을 만드는 코드를 **전부 클라이언트에 담는다** — 그러니
#   "요청 스키마를 모르겠다" 는 성립하지 않는다. 청크가 나뉘어 있을 뿐이다:
#   index 번들에는 래퍼(`userLogin`)만 있고 본문을 조립하는 곳은 로그인
#   화면 청크에 있다. 래퍼 이름 -> export 이름 -> 그 이름을 부르는 청크
#   순서로 따라갈 것.
#
# 사용
#   local/safeline-bootstrap.sh            # 적용
#   local/safeline-bootstrap.sh --check    # 사이트 목록만 보고 끝낸다
set -Eeuo pipefail
trap 'echo "[safeline][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SITES="$HERE/local/safeline-sites"
NS="${NS:-local}"
PORT="${PORT:-11443}"
B="https://127.0.0.1:${PORT}"
CHECK=no
[ "${1:-}" = "--check" ] && CHECK=yes

log() { echo "[safeline] $*"; }
die() { echo "[safeline] $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl 이 필요하다"
command -v python3 >/dev/null 2>&1 || die "python3 이 필요하다"

D="$(mktemp -d)"
PF=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  find "$D" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$D"
}
trap cleanup EXIT

# ── 자격 ────────────────────────────────────────────────────
# ★ 관리자 비밀번호는 우리가 만드는 값이 아니다 — mgt 가 첫 기동에 발급하고
#   로그에 한 번만 찍는다. `mgt-cli reset-admin` 으로 회전시켜 Secret 에
#   넣어 두었다(ACCESS.md). GitLab 배포 토큰과 같은 부류다(Gotcha 118) —
#   `create-secrets.sh` 가 만들지 못하므로 재구축 때 다시 해야 한다.
kubectl -n "$NS" get secret safeline-secret -o jsonpath='{.data.admin-password}' \
  | base64 -d > "$D/pw"
[ -s "$D/pw" ] || die "safeline-secret 에 admin-password 가 없다 — 아래를 먼저 돌릴 것:
  kubectl -n $NS exec deploy/safeline -c mgt -- /app/mgt-cli reset-admin
  (★ --once 플래그는 한 번만 듣는다. 이미 썼다면 플래그 없이 돌릴 것)"

kubectl -n "$NS" port-forward svc/safeline-mgt "${PORT}:1443" >/dev/null 2>&1 &
PF=$!
sleep 6

# ── 1) AES 키 ──────────────────────────────────────────────
curl -sk "$B/api/open/system/key" > "$D/key.json"
python3 - "$D/key.json" "$D/aeskey" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8")).get("data")
if isinstance(d, dict):
    d = d.get("key") or d.get("aes_key") or ""
if not isinstance(d, str) or not d:
    sys.stderr.write("[safeline] /api/open/system/key 가 키를 주지 않았다\n")
    raise SystemExit(1)
open(sys.argv[2], "w", encoding="utf-8").write(d)
PY
KEYLEN=$(wc -c < "$D/aeskey" | tr -d ' ')
case "$KEYLEN" in
  16) CIPHER=aes-128-cbc ;;
  24) CIPHER=aes-192-cbc ;;
  32) CIPHER=aes-256-cbc ;;
  *)  die "AES 키 길이가 예상 밖이다(${KEYLEN}바이트) — 번들의 계약이 바뀌었는지 볼 것" ;;
esac
log "AES 키 ${KEYLEN}바이트 -> ${CIPHER}"

# ── 2) csrf ────────────────────────────────────────────────
curl -sk "$B/api/open/auth/csrf" > "$D/csrf.json"
CSRF=$(python3 -c "
import json, sys
print((json.load(open(sys.argv[1], encoding='utf-8')).get('data') or {}).get('csrf_token', ''))
" "$D/csrf.json")
[ -n "$CSRF" ] || die "csrf_token 을 받지 못했다"

# ── 3) 로그인 ───────────────────────────────────────────────
# IV 는 16자 hex **문자열의 ASCII 바이트**다(번들이 Utf8.parse 를 쓴다).
IVTXT=$(openssl rand -hex 8)
IVHEX=$(printf '%s' "$IVTXT" | od -An -tx1 | tr -d ' \n')
KEYHEX=$(od -An -tx1 < "$D/aeskey" | tr -d ' \n')
# ★ 개행을 붙이지 않는다 — 비밀번호에 개행이 섞이면 조용히 인증 실패한다.
printf '%s' "$(cat "$D/pw")" \
  | openssl enc -"${CIPHER}" -K "$KEYHEX" -iv "$IVHEX" > "$D/ct"
python3 - "$IVTXT" "$D/ct" "$CSRF" "$D/login.json" <<'PY'
import base64, json, sys
iv, ct, csrf, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
blob = iv.encode("ascii") + open(ct, "rb").read()
json.dump({"username": "admin",
           "password": base64.b64encode(blob).decode(),
           "csrf_token": csrf},
          open(out, "w", encoding="utf-8"))
PY
curl -sk -X POST -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" \
  --data-binary @"$D/login.json" "$B/api/open/auth/login" > "$D/lr.json"
python3 - "$D/lr.json" "$D/jwt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
data = d.get("data") or {}
jwt = data.get("jwt") if isinstance(data, dict) else None
if not jwt:
    sys.stderr.write("[safeline] 로그인 실패 — msg=%r\n" % d.get("msg"))
    sys.stderr.write("[safeline] 비밀번호가 아니라 **본문 모양**을 먼저 의심할 것.\n")
    sys.stderr.write("[safeline] 이 스크립트 머리말의 로그인 계약과 UI 번들을 대조하라.\n")
    raise SystemExit(1)
open(sys.argv[2], "w", encoding="utf-8").write(jwt)
PY
JWT=$(cat "$D/jwt")
log "로그인 성공 (jwt ${#JWT}자)"

# ── 사이트 목록 ─────────────────────────────────────────────
list_sites() {
  curl -sk -H "Authorization: $JWT" -H "X-CSRF-Token: $CSRF" \
    "$B/api/open/site" > "$D/sites.json"
  python3 - "$D/sites.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
data = d.get("data")
rows = data.get("data") if isinstance(data, dict) else data
rows = rows or []
print(len(rows))
for r in rows:
    print("%s\t%s" % (r.get("id"), ",".join(r.get("server_names") or [])))
PY
}

if ! list_sites > "$D/cur" 2>/dev/null; then
  die "사이트 목록을 읽지 못했다 — 응답: $(head -c 200 "$D/sites.json")"
fi
log "현재 사이트 $(head -1 "$D/cur")건"
if [ "$CHECK" = yes ]; then
  tail -n +2 "$D/cur" | sed 's/^/  /'
  exit 0
fi

# ── 적용 ───────────────────────────────────────────────────
[ -d "$SITES" ] || die "$SITES 가 없다"
shopt -s nullglob
found=0
for f in "$SITES"/*.json; do
  found=1
  name=$(basename "$f" .json)
  # ★ 이미 있으면 만들지 않는다 — server_names 로 판정한다.
  want=$(python3 -c "
import json, sys
print(','.join(json.load(open(sys.argv[1], encoding='utf-8')).get('server_names') or []))
" "$f")
  if tail -n +2 "$D/cur" | cut -f2 | grep -Fxq "$want"; then
    log "-- ${name}: 이미 있다 (${want})"
    continue
  fi
  log "-- ${name}: 만든다 (${want})"
  before=$(head -1 "$D/cur")
  curl -sk -X POST -H 'Content-Type: application/json' \
    -H "Authorization: $JWT" -H "X-CSRF-Token: $CSRF" \
    --data-binary @"$f" "$B/api/open/site" > "$D/cr.json"
  # ★★ 가드를 "오류가 없다" 로 두지 말 것 — 실제로 이 API 는 `{}` 를 돌려주고
  #   아무것도 만들지 않았다(Gotcha 65 부류: 받아들이고 버린다). **건수가
  #   늘었는지**로 판정한다(Gotcha 117 의 같은 교훈, 다른 자리).
  python3 - "$D/cr.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write("[safeline]   응답이 JSON 이 아니다: %s\n" % raw[:300])
    raise SystemExit(1)
if d.get("err"):
    sys.stderr.write("[safeline]   거부됨: err=%r msg=%r\n" % (d.get("err"), d.get("msg")))
    sys.stderr.write("[safeline]   ★ 본문 모양을 서버가 말해 준다 — 지어내지 말고 이 메시지를 따를 것.\n")
    raise SystemExit(1)
print("[safeline]   응답 전문: %s" % raw[:400])
PY
  list_sites > "$D/cur"
  after=$(head -1 "$D/cur")
  if [ "$after" -le "$before" ]; then
    echo "[safeline]   ★ 오류는 없는데 건수가 늘지 않았다(${before} -> ${after})." >&2
    echo "[safeline]     받아들이고 버린 것이다 — 본문에 서버가 요구하는 필드가" >&2
    echo "[safeline]     빠졌을 가능성이 크다. 위의 '응답 전문' 과 UI 번들의" >&2
    echo "[safeline]     사이트 생성 스키마를 대조할 것." >&2
    exit 1
  fi
  log "  만들어졌다 (${before} -> ${after}건)"
done
[ "$found" = 1 ] || die "$SITES 에 정의가 0건이다"

log "완료 — 사이트 $(list_sites | head -1)건"
# ★★ 여기까지가 SafeLine 쪽이다. **트래픽이 실제로 이 WAF 를 지나는지는
#   별개**다 — HTTPRoute 가 safeline 서비스를 가리켜야 한다
#   (kubernetes/base/service-mesh/ingress-gateway.yaml).
#   그리고 순서는 반드시 **Istio 가 먼저**여야 한다: 계량 지점이 움직이면
#   이미 청구한 이력이 함께 흔들린다(Gotcha 15).
