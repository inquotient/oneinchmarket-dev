#!/usr/bin/env python3
# 계량 테스트 데이터를 넣는다 — 인보이스에 의미 있는 금액이 찍히게 한다
#
# ★ 왜 필요한가 — 요금제를 세워도(§8-87) 사용량이 없으면 인보이스가
#   구독료만 담는다. 실제로 §8-87 검증 때 사용량 라인이 qty=3 이라
#   3 x $0.001 = $0.003 이고 통화 최소 단위 미만이라 total 이 0 으로 보였다.
#   "가격이 붙었다" 를 눈으로 확인하려면 사용량이 있어야 한다.
#
# ★★ 계약(contracts/schemas/api-usage-event.json)을 그대로 따른다.
#   id 는 요청당 유일해야 한다 — Kafka 는 at-least-once 라 중복이 반드시
#   오고, 소비자는 이 값으로 중복을 제거한다(Gotcha 16). UUID4 를 쓴다.
#
# ★ Kafka 과금 토픽이 아니라 OpenMeter 의 ingest API 로 보낸다.
#   토픽에 실험 데이터를 넣지 않기 위해서다(Gotcha 23).
#
# ★★ 5xx 를 섞는다. 청구 대상이 아니어야 하고(§8-87 의 feature 필터),
#   섞지 않으면 그 필터가 동작하는지 확인할 수 없다.
#
# 사용
#   local/seed-usage.py                      # 테넌트당 5000건
#   local/seed-usage.py --events 20000       # 더 많이
#   local/seed-usage.py --error-rate 0       # 5xx 없이
import argparse
import datetime
import json
import os
import random
import sys
import urllib.error
import urllib.request
import uuid

try:
    import yaml
except ImportError:
    sys.exit("PyYAML 이 필요하다: pip install pyyaml")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "local", "pricing-catalog.yaml")

# ★ route 는 정규화된 템플릿이어야 한다 — 원본 경로를 넣으면 카디널리티가
#   폭발하고 경로에 식별자가 섞여 들어온다(계약의 route 설명).
ROUTES = ["/v1/orders", "/v1/orders/{id}", "/v1/quotes", "/v1/positions"]
METHODS = ["GET", "GET", "GET", "POST", "PUT"]
OK_STATUS = [200, 200, 200, 200, 201, 404, 403]


def post_batch(base, events):
    req = urllib.request.Request(
        base + "/api/v1/events",
        data=json.dumps(events).encode(),
        headers={"Content-Type": "application/cloudevents-batch+json"},
        method="POST")
    try:
        r = urllib.request.urlopen(req, timeout=90)
        return r.status, ""
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:200]
    except Exception as e:
        return 0, str(e)[:200]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="18888",
                    help="openmeter-api 로의 port-forward 포트")
    ap.add_argument("--events", type=int, default=5000,
                    help="테넌트당 이벤트 수")
    ap.add_argument("--error-rate", type=float, default=0.1,
                    help="5xx 비율 (청구되지 않아야 한다)")
    ap.add_argument("--batch", type=int, default=500)
    ap.add_argument("--minutes-back", type=int, default=30,
                    help="이 분(minute) 만큼 과거부터 흩뿌린다")
    args = ap.parse_args()

    base = "http://127.0.0.1:%s" % args.port
    with open(CATALOG, encoding="utf-8") as f:
        cat = yaml.safe_load(f)

    # ★ 시각을 과거로 흩뿌리되 구독 시작 이후여야 한다 —
    #   구독 이전의 사용량은 청구되지 않는다(§8-87 에서 확인).
    now = datetime.datetime.now(datetime.timezone.utc)
    span = datetime.timedelta(minutes=args.minutes_back)

    rnd = random.Random(20260908)

    total_sent = 0
    for t in cat["tenants"]:
        subject = t["subject"]
        n_err = int(args.events * args.error_rate)
        n_ok = args.events - n_err
        print("  %-14s plan=%-18s 이벤트 %d건 (청구대상 %d · 5xx %d)"
              % (subject, t["plan"], args.events, n_ok, n_err))

        batch, sent = [], 0
        for i in range(args.events):
            is_err = i >= n_ok
            status = rnd.choice([500, 502, 503]) if is_err else rnd.choice(OK_STATUS)
            ts = now - span * rnd.random()
            batch.append({
                "specversion": "1.0",
                "id": str(uuid.uuid4()),
                "source": "//seed.oneinchmarket.local/usage",
                "type": "io.oneinchmarket.api.request.v1",
                "subject": subject,
                "time": ts.isoformat().replace("+00:00", "Z"),
                "datacontenttype": "application/json",
                "data": {
                    "route": rnd.choice(ROUTES),
                    "method": rnd.choice(METHODS),
                    "status": status,
                    "duration_ms": round(rnd.uniform(1.0, 250.0), 2),
                    "request_bytes": rnd.randint(80, 2048),
                    "response_bytes": rnd.randint(120, 65536),
                    "api_product": "trading-api",
                },
            })
            if len(batch) >= args.batch:
                st, err = post_batch(base, batch)
                if st not in (200, 204):
                    sys.exit("     * 전송 실패: %s %s" % (st, err))
                sent += len(batch)
                batch = []
        if batch:
            st, err = post_batch(base, batch)
            if st not in (200, 204):
                sys.exit("     * 전송 실패: %s %s" % (st, err))
            sent += len(batch)
        print("     보냄: %d건" % sent)
        total_sent += sent

    print("")
    print("  총 %d건. sink-worker 가 ClickHouse 로 옮길 시간이 필요하다." % total_sent)
    print("  ★ 청구 수량은 5xx 를 뺀 값이어야 한다 — 그것이 §8-87 의 feature")
    print("    필터가 동작한다는 증거다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
