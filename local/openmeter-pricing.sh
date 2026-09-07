#!/usr/bin/env bash
# OpenMeter 가격 계층을 세운다 — 계량(§8-58~§8-63) 위에 "얼마인가" 를 올린다
#
# ★ 왜 필요한가 — §9-2 가 "인보이스 발행 전 마지막 조각" 이라고 적은 것이다.
#   계량은 "얼마나 썼나" 까지이고, 요금제·가격·구독이 없으면 billing
#   CronJob 3종(advance-invoices · collect-invoices · subscription-sync)이
#   돌기는 하는데 대상이 없다.
#
# ★ 순서가 고정이다 — feature -> plan -> publish -> customer -> subscription.
#   앞의 것이 없으면 뒤의 것이 만들어지지 않는다.
#
# ★★ 가격·쿼터의 원천은 local/pricing-catalog.yaml 하나다(§8-90).
#   같은 파일에서 Envoy ratelimit 의 한도도 나온다(local/render-ratelimit.py) —
#   요금제를 바꿀 때 두 곳을 따로 고치다 어긋나는 것을 막으려는 것이다.
#   카탈로그를 고쳤으면 렌더도 함께 돌릴 것.
#
# ★ 값은 테스트 데이터다. 가격은 소급 적용이 가능하지만 청구 이력은
#   불가능하다(Gotcha 15) — 실제 고객 전에 카탈로그를 실제 값으로 바꾼다.
#
# 멱등하다 — 이미 있으면 건너뛴다.
#
# 사용
#   local/openmeter-pricing.sh
set -Eeuo pipefail
trap 'echo "[pricing][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
PORT="${PORT:-18888}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CATALOG="${CATALOG:-$HERE/pricing-catalog.yaml}"

log() { echo "[pricing] $*"; }

[ -f "$CATALOG" ] || { echo "[pricing] 카탈로그가 없다: $CATALOG" >&2; exit 1; }

log "openmeter-api 로 port-forward (:$PORT)"
kubectl -n "$NS" port-forward svc/openmeter-api "${PORT}:80" >/tmp/om-pricing-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 6

export OM_PORT="$PORT" OM_CATALOG="$CATALOG"

python3 - <<'PY'
import json, os, sys, urllib.request as u, urllib.error

try:
    import yaml
except ImportError:
    sys.exit("PyYAML 이 필요하다: pip install pyyaml")

B = "http://127.0.0.1:%s" % os.environ["OM_PORT"]
with open(os.environ["OM_CATALOG"], encoding="utf-8") as f:
    CAT = yaml.safe_load(f)
CUR = CAT["currency"]

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = u.Request(B + path, data=data,
                    headers={"Content-Type": "application/json"}, method=method)
    try:
        r = u.urlopen(req, timeout=40)
        raw = r.read().decode("utf-8", "replace")
        return r.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:400]
    except Exception as e:
        return 0, str(e)[:200]

def listing(path):
    st, d = call("GET", path)
    if st != 200:
        sys.exit("  * %s 조회 실패: %s %s" % (path, st, d))
    return d if isinstance(d, list) else (d.get("items") or [])

# ── 1) Feature ───────────────────────────────────────────────
# ★★ 5xx 를 청구하지 않는다. contracts/schemas/api-usage-event.json 이
#   "5xx(우리 잘못)를 청구하는 것은 방어할 수 없고, 4xx 를 청구할지는
#   요금제가 정할 문제" 라고 적어 두었다 — 고르는 자리는 미터가 아니라
#   feature 다.
# ★ status 는 문자열이지만 HTTP 상태는 전부 세 자리라 사전순 비교가 수치
#   비교와 같다 — $lt "500" 이면 1xx~4xx 만 남는다.
# ★★★ $not / $like 를 쓰지 말 것 — 201 을 돌려주고 필터를 통째로 삼킨다
#   ({"status":{}} 로 저장 = 필터 없음 = 5xx 도 전부 청구).
#   보존되는 것만 쓸 것: $eq $ne $in $nin $lt $gt.
FEATURE_KEY = "api_requests_billable"
if FEATURE_KEY in set(f["key"] for f in listing("/api/v1/features")):
    print("  feature 있음: %s" % FEATURE_KEY)
else:
    st, d = call("POST", "/api/v1/features", {
        "key": FEATURE_KEY,
        "name": "Billable API requests (5xx 제외)",
        "meterSlug": "api_requests_total",
        "advancedMeterGroupByFilters": {"status": {"$lt": "500"}},
    })
    if st not in (200, 201):
        sys.exit("  * feature 생성 실패: %s %s" % (st, d))
    print("  feature 생성: %s" % FEATURE_KEY)

st, chk = call("GET", "/api/v1/features/" + FEATURE_KEY)
flt = ((chk or {}).get("advancedMeterGroupByFilters") or {}).get("status")
if not flt:
    sys.exit("  ** 필터가 저장되지 않았다 — 5xx 가 청구된다. 중단한다.")
print("     저장된 필터: status=%s" % json.dumps(flt))

# ── 2) Plan ──────────────────────────────────────────────────
# 함정 넷(전부 실측):
#   (1) key 는 snake_case 만 받는다 — ^[a-z0-9]+(?:_[a-z0-9]+)*$
#   (2) flat_fee rate card 에도 billingCadence 가 필수다
#   (3) phase 에 duration 이 필수다. 마지막 phase 는 null
#   (4) usage_based rate card 의 key 는 featureKey 와 같아야 한다
existing = {p["key"]: p for p in listing("/api/v1/plans")}
for spec in CAT["plans"]:
    key = spec["key"]
    plan = existing.get(key)
    if plan:
        print("  plan 있음: %-18s (%s)" % (key, plan.get("status")))
    else:
        st, plan = call("POST", "/api/v1/plans", {
            "key": key,
            "name": spec["name"],
            "currency": CUR,
            "billingCadence": "P1M",
            "phases": [{
                "key": "standard", "name": "Standard", "duration": None,
                "rateCards": [
                    {"type": "flat_fee", "key": "platform_fee",
                     "name": "Platform fee", "billingCadence": "P1M",
                     "price": {"type": "flat",
                               "amount": str(spec["platformFee"]),
                               "paymentTerm": "in_advance"}},
                    {"type": "usage_based", "key": FEATURE_KEY,
                     "name": "API requests (billable)",
                     "featureKey": FEATURE_KEY, "billingCadence": "P1M",
                     "price": {"type": "unit",
                               "amount": str(spec["perRequest"])}},
                ],
            }],
        })
        if st not in (200, 201):
            sys.exit("  * plan 생성 실패(%s): %s %s" % (key, st, plan))
        print("  plan 생성: %-18s fee=%s unit=%s" %
              (key, spec["platformFee"], spec["perRequest"]))
    # ★ 게시하지 않은 plan 에는 구독할 수 없다.
    if plan.get("status") == "draft":
        st, d = call("POST", "/api/v1/plans/%s/publish" % plan["id"])
        if st not in (200, 201):
            sys.exit("  * plan 게시 실패(%s): %s %s" % (key, st, d))
        print("     게시: effectiveFrom=%s" % (d or {}).get("effectiveFrom"))

# ── 3) Customer + Subscription ───────────────────────────────
# ★★ 고객 key 와 계량 subject 는 다른 이름 공간이다. 잇는 것은
#   usageAttribution.subjectKeys 이고, 빠뜨리면 고객은 만들어지는데 사용량이
#   붙지 않아 0원 인보이스가 된다(오류가 아니다).
customers = {c.get("key"): c for c in listing("/api/v1/customers")}
for t in CAT["tenants"]:
    ckey, cname, subject, plankey = t["key"], t["name"], t["subject"], t["plan"]
    c = customers.get(ckey)
    if c is None:
        st, c = call("POST", "/api/v1/customers", {
            "key": ckey, "name": cname,
            "usageAttribution": {"subjectKeys": [subject]},
        })
        if st not in (200, 201):
            sys.exit("  * customer 생성 실패(%s): %s %s" % (ckey, st, c))
        print("  customer 생성: %s <- subject %s" % (ckey, subject))
    else:
        subs = (c.get("usageAttribution") or {}).get("subjectKeys") or []
        if subject not in subs:
            st, c = call("PUT", "/api/v1/customers/" + c["id"], {
                "key": ckey, "name": cname,
                "usageAttribution": {"subjectKeys": sorted(set(subs) | {subject})},
            })
            if st != 200:
                sys.exit("  * customer 갱신 실패(%s): %s %s" % (ckey, st, c))
            print("  customer 갱신: %s <- subject %s" % (ckey, subject))
        else:
            print("  customer 있음: %s (subject %s)" % (ckey, subject))

    st, subs = call("GET", "/api/v1/customers/%s/subscriptions" % c["id"])
    active = []
    if st == 200:
        it = subs if isinstance(subs, list) else (subs.get("items") or [])
        active = [x for x in it if x.get("status") in ("active", "scheduled")]
    if active:
        cur_plan = ((active[0].get("plan") or {}).get("key")
                    or active[0].get("planId") or "?")
        # ★ 요금제를 바꾸려면 기존 구독을 끝내고 새로 만들어야 한다.
        #   자동으로 하지 않는다 — 구독 변경은 청구 경계를 움직인다.
        mark = "" if cur_plan == plankey else "   ** 카탈로그(%s)와 다르다" % plankey
        print("     구독 있음: %s plan=%s%s" % (active[0].get("id"), cur_plan, mark))
        continue
    st, s = call("POST", "/api/v1/subscriptions", {
        "customerId": c["id"],
        "plan": {"key": plankey},
        "timing": "immediate",
    })
    if st not in (200, 201):
        sys.exit("  * subscription 생성 실패(%s): %s %s" % (ckey, st, s))
    print("     구독 생성: %s plan=%s" % (s.get("id"), plankey))

print("")
print("  === 최종 상태 ===")
for path, label in [("/api/v1/features", "feature"),
                    ("/api/v1/plans", "plan"),
                    ("/api/v1/customers", "customer")]:
    it = listing(path)
    print("  %-9s %d건: %s" % (label, len(it), [i.get("key") for i in it]))
PY

log "완료 — 쿼터도 같은 카탈로그에서 나온다. 바꿨으면 render-ratelimit.py 를 돌릴 것"
