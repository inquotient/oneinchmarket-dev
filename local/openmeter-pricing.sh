#!/usr/bin/env bash
# OpenMeter 가격 계층을 세운다 — 계량(§8-58~§8-63) 위에 "얼마인가" 를 올린다
#
# ★ 왜 필요한가 — §9-2 가 "인보이스 발행 전 마지막 조각" 이라고 적은 것이다.
#   계량은 "얼마나 썼나" 까지이고, 요금제·가격·구독이 없으면 billing
#   CronJob 3종(advance-invoices · collect-invoices · subscription-sync)이
#   **돌기는 하는데 대상이 없다.**
#
# ★ 순서가 정해져 있다 — feature -> plan -> publish -> customer -> subscription.
#   앞의 것이 없으면 뒤의 것이 만들어지지 않는다.
#
# ★★ 가격은 **예시다.** 아래 PRICE_* 를 실제 값으로 바꿔 쓸 것.
#   가격은 소급 적용이 가능하지만 **청구 이력은 불가능하다**(Gotcha 15) —
#   인보이스를 한 장이라도 낸 뒤에는 그 기간을 다시 계산할 수 없다.
#   그래서 지금이 이 값을 정할 마지막 안전한 시점이다.
#
# 멱등하다 — 이미 있으면 건너뛴다.
#
# 사용
#   local/openmeter-pricing.sh
set -Eeuo pipefail
trap 'echo "[pricing][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
PORT="${PORT:-18888}"

# ── 예시 가격 ────────────────────────────────────────────────
CURRENCY="${CURRENCY:-USD}"                          # billing profile 통화와 맞출 것
PRICE_PLATFORM_FEE="${PRICE_PLATFORM_FEE:-20}"       # 월 구독료
PRICE_PER_REQUEST="${PRICE_PER_REQUEST:-0.001}"      # 요청 1건당(=1000건당 $1)
# ────────────────────────────────────────────────────────────

log() { echo "[pricing] $*"; }

log "openmeter-api 로 port-forward (:$PORT)"
kubectl -n "$NS" port-forward svc/openmeter-api "${PORT}:80" >/tmp/om-pricing-pf.log 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 6

# ★ 값을 반드시 export 할 것 — 셸 변수만으로는 python 으로 넘어가지 않는다.
export OM_PORT="$PORT" CURRENCY PRICE_PLATFORM_FEE PRICE_PER_REQUEST

python3 - <<'PY'
import json, os, sys, urllib.request as u, urllib.error

B    = "http://127.0.0.1:%s" % os.environ["OM_PORT"]
CUR  = os.environ["CURRENCY"]
FEE  = os.environ["PRICE_PLATFORM_FEE"]
UNIT = os.environ["PRICE_PER_REQUEST"]

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
# ★★ 5xx 를 청구하지 않는다. 플랫폼이 처리하지 못한 요청을 청구하면
#   고객에게 우리 장애를 파는 셈이다. §8-60 이 groupBy 를 고치며
#   "그 상태로 인보이스를 내면 5xx 를 제외할 수 없다" 고 적어 둔 지점이다.
# ★ 표현은 advancedMeterGroupByFilters 로 한다. status 는 문자열이지만 HTTP
#   상태는 전부 세 자리라 사전순 비교가 수치 비교와 같다 — $lt "500" 이면
#   1xx~4xx 만 남는다.
# ★★★ $not / $like 를 쓰지 말 것 — 실측: {"status":{"$not":{"$like":"5%"}}} 를
#   보내면 201 을 돌려주고 필터를 통째로 삼킨다({"status":{}} 로 저장, 즉
#   필터 없음 = 5xx 도 전부 청구). 성공 출력이 성공을 뜻하지 않는 부류다.
#   보존되는 것만 쓸 것: $eq $ne $in $nin $lt $gt.
FEATURE_KEY = "api_requests_billable"
have = set(f["key"] for f in listing("/api/v1/features"))
if FEATURE_KEY in have:
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

# 저장된 필터를 되읽어 확인한다 — 삼켜졌는지 여기서만 알 수 있다.
st, chk = call("GET", "/api/v1/features/" + FEATURE_KEY)
flt = ((chk or {}).get("advancedMeterGroupByFilters") or {}).get("status")
if not flt:
    sys.exit("  ** 필터가 저장되지 않았다 — 5xx 가 청구된다. 중단한다.")
print("     저장된 필터: status=%s" % json.dumps(flt))

# ── 2) Plan ──────────────────────────────────────────────────
# 함정 넷(전부 실측):
#   (1) key 는 snake_case 만 받는다 — ^[a-z0-9]+(?:_[a-z0-9]+)*$.
#       oim-api-standard 는 400 이다.
#   (2) flat_fee rate card 에도 billingCadence 가 필수다(null 이면 일회성).
#   (3) phase 에 duration 이 필수다. 마지막(유일) phase 는 무기한이므로 null.
#   (4) usage_based rate card 의 key 는 featureKey 와 같아야 한다 —
#       다르면 rate_card_key_feature_key_mismatch 다.
PLAN_KEY = "oim_api_standard"
plan = None
for p in listing("/api/v1/plans"):
    if p.get("key") == PLAN_KEY:
        plan = p
        break

if plan:
    print("  plan 있음: %s (status=%s)" % (PLAN_KEY, plan.get("status")))
else:
    st, plan = call("POST", "/api/v1/plans", {
        "key": PLAN_KEY,
        "name": "OneinchMarket API Standard",
        "currency": CUR,
        "billingCadence": "P1M",
        "phases": [{
            "key": "standard", "name": "Standard", "duration": None,
            "rateCards": [
                {"type": "flat_fee", "key": "platform_fee", "name": "Platform fee",
                 "billingCadence": "P1M",
                 "price": {"type": "flat", "amount": FEE,
                           "paymentTerm": "in_advance"}},
                {"type": "usage_based", "key": FEATURE_KEY,
                 "name": "API requests (billable)",
                 "featureKey": FEATURE_KEY, "billingCadence": "P1M",
                 "price": {"type": "unit", "amount": UNIT}},
            ],
        }],
    })
    if st not in (200, 201):
        sys.exit("  * plan 생성 실패: %s %s" % (st, plan))
    print("  plan 생성: %s v%s" % (PLAN_KEY, plan.get("version")))

# ★ 게시하지 않은 plan 에는 구독할 수 없다.
if plan.get("status") == "draft":
    st, d = call("POST", "/api/v1/plans/%s/publish" % plan["id"])
    if st not in (200, 201):
        sys.exit("  * plan 게시 실패: %s %s" % (st, d))
    print("  plan 게시: effectiveFrom=%s" % (d or {}).get("effectiveFrom"))

# ── 3) Customer + Subscription ───────────────────────────────
# ★★ 고객 key 와 계량 subject 는 다른 이름 공간이다.
#   고객 key 는 snake_case 강제(acme_corp)이고, 계량 subject 는 게이트웨이가
#   토큰의 tenant 클레임에서 만든 값(acme-corp, 하이픈)이다.
#   둘을 잇는 것이 usageAttribution.subjectKeys 이고, 빠뜨리면 고객은
#   만들어지는데 사용량이 하나도 붙지 않는다 — 오류가 아니라 0원 인보이스로
#   나오므로 알아채기 어렵다. 실측: key 만 주면 201 이 그냥 나온다.
TENANTS = [("acme_corp", "Acme Corp", "acme-corp"),
           ("globex_corp", "Globex Corp", "globex-corp")]

customers = {}
for c in listing("/api/v1/customers"):
    customers[c.get("key")] = c

for ckey, cname, subject in TENANTS:
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
        if subject in subs:
            print("  customer 있음: %s (subject %s)" % (ckey, subject))
        else:
            merged = sorted(set(subs) | set([subject]))
            st, c = call("PUT", "/api/v1/customers/" + c["id"], {
                "key": ckey, "name": cname,
                "usageAttribution": {"subjectKeys": merged},
            })
            if st != 200:
                sys.exit("  * customer 갱신 실패(%s): %s %s" % (ckey, st, c))
            print("  customer 갱신: %s <- subject %s" % (ckey, subject))

    st, subs = call("GET", "/api/v1/customers/%s/subscriptions" % c["id"])
    active = []
    if st == 200:
        items = subs if isinstance(subs, list) else (subs.get("items") or [])
        active = [s for s in items if s.get("status") in ("active", "scheduled")]
    if active:
        print("     구독 있음: %s (%s)" % (active[0].get("id"), active[0].get("status")))
        continue
    st, s = call("POST", "/api/v1/subscriptions", {
        "customerId": c["id"],
        "plan": {"key": PLAN_KEY},
        "timing": "immediate",
    })
    if st not in (200, 201):
        sys.exit("  * subscription 생성 실패(%s): %s %s" % (ckey, st, s))
    print("     구독 생성: %s activeFrom=%s" % (s.get("id"), s.get("activeFrom")))

# ── 4) 확인 ──────────────────────────────────────────────────
print("")
print("  === 최종 상태 ===")
for path, label in [("/api/v1/features", "feature"),
                    ("/api/v1/plans", "plan"),
                    ("/api/v1/customers", "customer")]:
    items = listing(path)
    print("  %-9s %d건: %s" % (label, len(items),
                               [i.get("key") for i in items]))
PY

log "완료 — 인보이스는 billing CronJob 이 만든다(advance-invoices / collect-invoices)"
