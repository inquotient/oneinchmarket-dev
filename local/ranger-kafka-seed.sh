#!/usr/bin/env bash
# Kafka Ranger 정책 시드를 살아 있는 브로커의 캐시에서 다시 쓴다 (2026-11-03)
#
# ★ 왜: 처음 세우는 클러스터에서 Kafka(wave 2)는 Ranger Admin(wave 5)보다 먼저 뜬다.
#   정책을 못 받은 플러그인은 전부 거부하므로 시드(지금 적용된 정책의 스냅숏)가
#   없으면 브로커가 자기 컨트롤러에도 등록하지 못한다 — 상세는
#   kubernetes/overlays/local/kustomization.yaml 의 configMapGenerator 머리말.
# ★ 원천은 여전히 local/ranger-services/ 다(ranger-bootstrap.sh 가 Admin 에 넣는다).
#   이 시드는 그 결과를 **받아 적은 사본**이고 Admin 에 못 닿을 때만 쓰인다.
#   그래서 정책을 바꾼 뒤에는: ranger-bootstrap.sh -> (30초) -> 이 스크립트.
#
# 사용
#   local/ranger-kafka-seed.sh           # 시드 파일을 다시 쓴다
#   local/ranger-kafka-seed.sh --check   # 뒤처졌으면 1 (정책 이름·리소스·항목만 비교한다 —
#                                        #   id·버전·시각은 매번 달라 비교하지 않는다)
set -euo pipefail
NS="${NS:-local}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="$REPO_ROOT/kubernetes/overlays/local/kafka-ranger-seed.json"
CACHE=/tmp/ranger/kafka/policycache/kafka_oim-kafka.json
MODE="${1:-write}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kubectl -n "$NS" exec kafka-0 -c kafka -- cat "$CACHE" > "$tmp/live.json" \
  || { echo "[seed] 브로커의 캐시를 읽지 못했다($CACHE) — 플러그인이 정책을 받았는지 볼 것" >&2; exit 2; }

python3 - "$tmp/live.json" "$SEED" "$MODE" <<'PY'
import json, sys
live_p, seed_p, mode = sys.argv[1:4]
live = json.load(open(live_p, encoding="utf-8"))
if live.get("serviceName") != "oim-kafka" or not live.get("policies"):
    sys.exit("[seed] 캐시 내용이 기대와 다르다(serviceName/policies)")

def norm(d):
    out = []
    for p in d.get("policies", []):
        items = sorted(
            (tuple(sorted(i.get("users") or [])), tuple(sorted(i.get("groups") or [])),
             tuple(sorted(a["type"] for a in i.get("accesses", []) if a.get("isAllowed"))))
            for i in p.get("policyItems", []))
        res = tuple(sorted((k, tuple(sorted(v.get("values", [])))) for k, v in p.get("resources", {}).items()))
        out.append((p["name"], p.get("isEnabled", True), res, tuple(items)))
    return sorted(out)

if mode == "--check":
    try:
        seed = json.load(open(seed_p, encoding="utf-8"))
    except FileNotFoundError:
        sys.exit("[seed] 시드 파일이 없다 — 이 스크립트를 인자 없이 돌릴 것")
    if norm(seed) != norm(live):
        a, b = set(norm(seed)), set(norm(live))
        print("[seed] **뒤처졌다** — 시드에만: %d · 살아 있는 쪽에만: %d" % (len(a - b), len(b - a)))
        for x in sorted(b - a): print("   +", x[0])
        for x in sorted(a - b): print("   -", x[0])
        sys.exit(1)
    print("[seed] 시드가 살아 있는 정책과 같다 (정책 %d개, 살아 있는 판 %s)" % (len(live["policies"]), live.get("policyVersion")))
    sys.exit(0)

# ★ 공개 그룹이 섞인 캐시를 시드로 굳히지 않는다 — ranger-bootstrap.sh 의 stripGroups 가
#   돌기 전이라는 뜻이다(모든 인증 사용자 전권).
if any("public" in (i.get("groups") or []) for p in live["policies"] for i in p.get("policyItems", [])):
    sys.exit("[seed] 캐시에 그룹 public 이 있다 — ranger-bootstrap.sh 를 먼저 돌릴 것")
open(seed_p, "w", encoding="utf-8", newline="\n").write(json.dumps(live, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
print("[seed] 썼다: %s (정책 %d개, 판 %s)" % (seed_p, len(live["policies"]), live.get("policyVersion")))
PY
