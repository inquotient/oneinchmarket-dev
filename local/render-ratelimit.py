#!/usr/bin/env python3
# 요금제 카탈로그에서 Envoy ratelimit ConfigMap 을 만든다
#
# ★ 왜 필요한가 — §8-89 가 남긴 구멍이다. 요금제(OpenMeter)와 쓰로틀 한도가
#   각자 살면 요금제를 바꿀 때 두 곳을 고쳐야 하고, 어긋나도 아무도 알려주지
#   않는다. "Pro 를 샀는데 Free 한도로 막힌다" 는 조용히 생긴다.
#   원천은 local/pricing-catalog.yaml 하나다.
#
# ★ 출력은 git 에 커밋한다. ArgoCD 가 그것을 적용하므로 카탈로그만 고치고
#   렌더를 잊으면 쿼터가 그대로인데, 렌더 결과가 git 에 있으면 diff 로 드러난다.
#
# 사용
#   local/render-ratelimit.py            # 렌더해서 파일에 쓴다
#   local/render-ratelimit.py --check    # 쓰지 않고 최신인지만 본다(CI 용)
import argparse
import io
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML 이 필요하다: pip install pyyaml")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "local", "pricing-catalog.yaml")
OUT = os.path.join(ROOT, "kubernetes", "base", "gateway-ratelimit",
                   "ratelimit-config.yaml")

HEADER = """# ★★ 이 파일은 생성된다 — 직접 고치지 말 것.
#   원천: local/pricing-catalog.yaml
#   생성: local/render-ratelimit.py
#
#   손으로 고치면 다음 렌더에서 지워지고, 그 사이 요금제와 쿼터가 어긋난다.
#   쿼터를 바꾸려면 카탈로그를 고치고 다시 렌더할 것.
#
# ★ 구조에 함정이 있다 — 중첩 descriptor 에도 key 가 필수다. key 없이
#   value 만 주면 RLS 가
#     Error loading new configuration: ...: descriptor has empty key
#   를 내고 바로 다음 줄에 "Successfully loaded" 를 출력하며 설정을 통째로
#   버린다. 그러면 모든 요청이 무제한인데 파드는 1/1 Running 이다(§8-89).
#   판정은 기동 로그의 config_load_error 카운터로 한다.
"""


def build(cat):
    plans = {p["key"]: p for p in cat["plans"]}
    per_tenant = []
    for t in cat.get("tenants", []):
        plan = plans.get(t["plan"])
        if plan is None:
            sys.exit("  * 테넌트 %s 가 없는 요금제 %s 를 가리킨다"
                     % (t["key"], t["plan"]))
        per_tenant.append({
            "key": "tenant",
            "value": t["subject"],
            "rate_limit": {"unit": "minute",
                           "requests_per_unit": int(plan["quotaPerMinute"])},
        })
    # ★ 마지막은 value 없는 catch-all 이다 — 카탈로그에 없는 테넌트가
    #   무제한이 되지 않게 한다.
    per_tenant.append({
        "key": "tenant",
        "rate_limit": {"unit": "minute",
                       "requests_per_unit": int(cat["unknownTenantQuotaPerMinute"])},
    })

    return {
        "domain": "oim-api",
        "descriptors": [{
            # scope 는 EnvoyFilter 의 generic_key 액션과 짝이다. 이것이
            # 바깥에 있어야 tenant 헤더가 없는 요청도 descriptor 를 갖는다
            # (없으면 RLS 를 아예 호출하지 않아 무제한이 된다, §8-89).
            "key": "scope",
            "value": "api",
            "descriptors": per_tenant,
            "rate_limit": {"unit": "minute",
                           "requests_per_unit": int(cat["noTenantQuotaPerMinute"])},
        }],
    }


def render(cat):
    inner = yaml.safe_dump(build(cat), sort_keys=False, allow_unicode=True,
                           default_flow_style=False)
    cm = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": "ratelimit-config",
            "labels": {
                "app.kubernetes.io/name": "ratelimit",
                "app.kubernetes.io/component": "service-mesh",
                "app.kubernetes.io/part-of": "oneinchmarket",
                "app.kubernetes.io/managed-by": "kustomize",
            },
        },
        "data": {"oim-api.yaml": inner},
    }
    body = yaml.safe_dump(cm, sort_keys=False, allow_unicode=True,
                          default_flow_style=False)
    return HEADER + "---\n" + body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="쓰지 않고 최신인지만 확인한다")
    args = ap.parse_args()

    with io.open(CATALOG, encoding="utf-8") as f:
        cat = yaml.safe_load(f)
    out = render(cat)

    cur = None
    if os.path.exists(OUT):
        with io.open(OUT, encoding="utf-8", newline="") as f:
            cur = f.read()

    if args.check:
        if cur == out:
            print("  최신이다: %s" % os.path.relpath(OUT, ROOT))
            return 0
        print("  * 뒤처졌다 — local/render-ratelimit.py 를 다시 돌릴 것: %s"
              % os.path.relpath(OUT, ROOT))
        return 1

    if cur == out:
        print("  변경 없음: %s" % os.path.relpath(OUT, ROOT))
        return 0
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("  생성: %s" % os.path.relpath(OUT, ROOT))
    plans = {p["key"]: p for p in cat["plans"]}
    for t in cat.get("tenants", []):
        print("     %-14s %-20s %s req/min"
              % (t["subject"], t["plan"], plans[t["plan"]]["quotaPerMinute"]))
    print("     %-14s %-20s %s req/min"
          % ("(그 외)", "-", cat["unknownTenantQuotaPerMinute"]))
    print("     %-14s %-20s %s req/min"
          % ("(tenant 없음)", "-", cat["noTenantQuotaPerMinute"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
