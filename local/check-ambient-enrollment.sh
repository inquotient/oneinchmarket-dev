#!/usr/bin/env bash
# ambient 메시에 **실제로 편입된 파드**를 세어 빠진 것을 찾는다.
#
# 왜 필요한가
#   2026-10-09 실측: `otel-agent` 파드 하나가 104 에서 메시 밖에 있었고, 그
#   때문에 kafka 의 ALLOW 정책이 그 연결을 **10시간 동안 1,825번** 거부했다.
#   아무도 아프다고 말하지 않았다 — 파드는 1/1 Running, 앱 로그는 오류 0,
#   ArgoCD 는 Synced·Healthy 였다. 단서는 ztunnel 로그 한 줄뿐이고
#   (policy rejection: allow policies exist, but none allowed) 그 로그는
#   회전해서 몇십 분이면 사라진다.
#
# ★★★ 기존 판정법 둘이 **모두 이것을 놓친다**
#   · istioctl ztunnel-config workload — xDS 로 받은 목록이라 그 파드를
#     HBONE 으로 **정상 보고한다**(Gotcha 50 이 "판정에 쓰지 말 것" 이라 적은
#     그 간극이다. 실측에서 TCP 목록에 otel-agent 가 없었다).
#   · kubectl logs ds/ztunnel 에서 "pod received, starting proxy" 를 세는 것 —
#     tail 창 안의 건수일 뿐이라 오래 돈 ztunnel 에서는 무의미하다(Gotcha 125).
#     이 노드는 로그 보존이 40분쯤이어서 사고 다음 날에는 아무것도 남지 않는다.
#
#   ★ 그리고 **신호처럼 보이는데 신호가 아닌 것이 둘 더 있다**(실측으로 둘 다
#     "편입됨" 이라고 거짓 보고했다):
#       · 파드의 ambient.istio.io/redirection=enabled 어노테이션 — istio-cni 가
#         **전에** 붙인 것이 그대로 남는다. 빠진 파드에도 붙어 있었다.
#       · ztunnel 의 certificates 목록 — 그 신원의 인증서가 Available 로
#         남는다. 빠진 파드의 sa/otel-agent 가 거기 있었다.
#
# ★★ 그래서 권위 있는 출처는 ztunnel 의 **workloadState** 다 — 그것이 지금
#   프록시를 세워 둔 파드의 목록이고, 로그 회전과 무관하다. 받는 길은
#   /config_dump(admin 15000)이며 ztunnel 이미지에 curl 이 없으므로
#   port-forward 로 호스트에서 받는다(Gotcha 56 의 자리).
#
# 무엇과 대조하는가 — ambient 대상 파드의 정의(실측으로 정한 규칙 셋)
#   1. 네임스페이스에 istio.io/dataplane-mode=ambient 가 있다(실측: local 하나)
#   2. hostNetwork 가 아니다 — 그런 파드는 신원이 아예 없다(Gotcha 110 2번)
#   3. 파드 라벨 istio.io/dataplane-mode=none 으로 빠지지 않았다
#      (실측: ingress-istio 와 waypoint 가 그렇다. 둘은 Istio 프록시 자신이라
#       ambient 대상이 아니고, 이 규칙 없이 세면 멀쩡한 것이 실패로 나온다)
#
# ★★ 판정은 **셋**이다 — 통과 / 실패 / **측정 불가**. ztunnel 에서 응답을 받지
#   못한 노드를 통과로 접지 않는다(Gotcha 191·194). 종료 코드: 0 · 1 · 2.
#
# 처방(이 스크립트는 고치지 않는다 — 읽기만 한다)
#   빠진 파드에 **새 샌드박스**를 주면 istio-cni 가 CNI ADD 에서 편입한다:
#     kubectl -n <ns> delete pod <이름>
#   여러 노드에 걸쳐 많이 빠졌으면 Gotcha 50 의 광범위 처방을 쓸 것:
#     kubectl rollout restart -n istio-system ds/istio-cni-node
#   ★ 컨테이너 재시작만으로는 풀리지 않는다 — 샌드박스가 그대로면 CNI 이벤트가
#     일어나지 않는다. 실측에서 빠진 파드는 restartCount=6 인데 파드
#     startTime 은 나흘 전이었다(컨테이너만 재시작한 것이다).
#
# 쓰는 법
#   bash local/check-ambient-enrollment.sh            # 보고
#   bash local/check-ambient-enrollment.sh --check    # 같다(게이트용 별칭)
#
# ★ control-plane 에서 돌릴 것.
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

PORT_BASE="${PORT_BASE:-15310}"
ZT_ADMIN_PORT=15000

TMP="$(mktemp -d)"
PF_PIDS=()
cleanup() {
  local p
  for p in "${PF_PIDS[@]:-}"; do
    [ -n "${p:-}" ] && kill "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }

# --- 0. 장치 대조군: 도구와 클러스터가 있는지 먼저 묻는다 -------------------
# 도구가 없는 것을 "빠진 파드 0" 으로 적으면 거짓 안심이 된다(Gotcha 191).
for t in kubectl curl python3; do
  if ! command -v "$t" >/dev/null 2>&1; then
    say "[측정 불가] $t 이 없다."
    exit 2
  fi
done

if ! kubectl get ns >/dev/null 2>&1; then
  say "[측정 불가] 클러스터에 닿지 못한다 (KUBECONFIG=$KUBECONFIG)."
  exit 2
fi

AMBIENT_NS="$(kubectl get ns -o go-template='{{range .items}}{{if eq (index .metadata.labels "istio.io/dataplane-mode") "ambient"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)"
if [ -z "$AMBIENT_NS" ]; then
  say "[측정 불가] ambient 네임스페이스가 하나도 없다."
  say "            (ns 라벨 istio.io/dataplane-mode=ambient 가 붙은 것이 없다)"
  exit 2
fi

ZT_LINES="$(kubectl -n istio-system get pods -o go-template='{{range .items}}{{.metadata.name}} {{.spec.nodeName}} {{.status.phase}}{{"\n"}}{{end}}' 2>/dev/null | grep '^ztunnel' || true)"
if [ -z "$ZT_LINES" ]; then
  say "[측정 불가] istio-system 에 ztunnel 파드가 없다."
  exit 2
fi

say "ambient 네임스페이스: $(echo "$AMBIENT_NS" | tr '\n' ' ')"
say "ztunnel 파드: $(echo "$ZT_LINES" | wc -l) 개"
hr

# --- 1. ambient 대상 파드 목록 (기대값) ------------------------------------
: > "$TMP/pods.ndjson"
while read -r ns; do
  [ -n "$ns" ] || continue
  if ! kubectl -n "$ns" get pods -o json >> "$TMP/pods.ndjson" 2>/dev/null; then
    say "[측정 불가] 네임스페이스 $ns 의 파드를 읽지 못했다."
    exit 2
  fi
done <<< "$AMBIENT_NS"

# --- 2. 노드별 ztunnel 의 workloadState (실측값) ---------------------------
# ★ port-forward 는 API 서버를 거치므로, 노드가 ClusterIP 를 쓸 수 없는 이
#   클러스터에서도 동작한다(Gotcha 187 의 함정을 피하는 유일한 경로다).
OFFSET=0
: > "$TMP/unmeasured.txt"
while read -r zt node phase; do
  [ -n "${zt:-}" ] || continue
  if [ "${phase:-}" != "Running" ]; then
    say "[측정 불가] $zt ($node) 가 Running 이 아니다: ${phase:-?}"
    printf '%s\t%s\n' "$node" "$zt:$phase" >> "$TMP/unmeasured.txt"
    continue
  fi
  port=$(( PORT_BASE + OFFSET )); OFFSET=$(( OFFSET + 1 ))
  kubectl -n istio-system port-forward "$zt" "${port}:${ZT_ADMIN_PORT}" \
    > "$TMP/pf.$zt.log" 2>&1 &
  PF_PIDS+=("$!")
  # 포트가 실제로 열렸는지 확인한다 — 잠들고 넘어가면 빈 파일을 "응답 없음" 으로
  # 적게 되고, 그것은 측정 실패를 결함으로 읽는 것이다(Gotcha 189).
  ok=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if curl -sf --max-time 5 "http://127.0.0.1:${port}/config_dump" \
         -o "$TMP/zt.$node.json" 2>/dev/null; then ok=1; break; fi
  done
  if [ "$ok" -ne 1 ] || [ ! -s "$TMP/zt.$node.json" ]; then
    say "[측정 불가] $zt ($node) 의 config_dump 를 받지 못했다."
    printf '%s\t%s\n' "$node" "$zt:no-config-dump" >> "$TMP/unmeasured.txt"
    rm -f "$TMP/zt.$node.json"
    continue
  fi
  say "받음: $node  ($(wc -c < "$TMP/zt.$node.json") bytes)"
done <<< "$ZT_LINES"
hr

# --- 3. 차집합 ------------------------------------------------------------
cat > "$TMP/diff.py" <<'PY'
import json, os, sys, glob

tmp = sys.argv[1]

expected = {}
excluded = {"hostNetwork": 0, "optout": 0, "notRunning": 0}

with open(os.path.join(tmp, "pods.ndjson")) as fh:
    text = fh.read()

dec = json.JSONDecoder()
idx, items = 0, []
while idx < len(text):
    while idx < len(text) and text[idx] in " \t\r\n":
        idx += 1
    if idx >= len(text):
        break
    obj, idx = dec.raw_decode(text, idx)
    items.extend(obj.get("items", []))

for p in items:
    md, sp, st = p["metadata"], p["spec"], p["status"]
    if st.get("phase") != "Running":
        excluded["notRunning"] += 1
        continue
    if sp.get("hostNetwork", False):
        excluded["hostNetwork"] += 1
        continue
    if (md.get("labels") or {}).get("istio.io/dataplane-mode") == "none":
        excluded["optout"] += 1
        continue
    node = sp.get("nodeName")
    if not node:
        continue
    expected.setdefault(node, set()).add(md["name"])

actual = {}
for f in glob.glob(os.path.join(tmp, "zt.*.json")):
    node = os.path.basename(f)[len("zt."):-len(".json")]
    try:
        d = json.load(open(f))
    except Exception as e:
        print("  [측정 불가] %s 의 config_dump 를 파싱하지 못했다: %s" % (node, e))
        continue
    ws = d.get("workloadState") or {}
    actual[node] = set(v["info"]["name"] for v in ws.values() if v.get("info"))

unmeasured = set()
uf = os.path.join(tmp, "unmeasured.txt")
if os.path.exists(uf):
    for line in open(uf):
        if line.strip():
            unmeasured.add(line.split("\t")[0])

print("제외한 파드: hostNetwork %d, dataplane-mode=none %d, 비-Running %d"
      % (excluded["hostNetwork"], excluded["optout"], excluded["notRunning"]))
print()

fails = 0
unmeas = 0
for node in sorted(set(list(expected) + list(actual) + list(unmeasured))):
    exp = expected.get(node, set())
    if node not in actual:
        print("[측정 불가] %s - ztunnel 의 목록을 받지 못했다 (대상 파드 %d개)"
              % (node, len(exp)))
        unmeas += 1
        continue
    act = actual[node]
    missing = sorted(exp - act)
    print("%s" % node)
    print("   ambient 대상 %d, 프록시 섬 %d, 빠짐 %d"
          % (len(exp), len(exp & act), len(missing)))
    if missing:
        fails += len(missing)
        for m in missing:
            print("   [실패] 메시 밖: %s" % m)
    extra = sorted(act - exp)
    if extra:
        print("   [참고] ztunnel 에만 있는 항목 %d개: %s"
              % (len(extra), ", ".join(extra[:5])))

print()
print("VERDICT fails=%d unmeasured=%d" % (fails, unmeas))
PY

python3 "$TMP/diff.py" "$TMP" | tee "$TMP/report.txt"
hr

VERDICT="$(grep '^VERDICT ' "$TMP/report.txt" | tail -1 || true)"
FAILS="$(printf '%s' "$VERDICT" | sed -n 's/.*fails=\([0-9]*\).*/\1/p')"
UNMEAS="$(printf '%s' "$VERDICT" | sed -n 's/.*unmeasured=\([0-9]*\).*/\1/p')"
# 값을 읽지 못했으면 통과로 접지 않는다 - 측정 불가다.
if [ -z "${FAILS:-}" ] || [ -z "${UNMEAS:-}" ]; then
  say "[측정 불가] 판정 줄을 읽지 못했다."
  exit 2
fi

say "이 검사가 **재지 못하는 것**"
say "  - 정책이 옳은지. 편입된 파드도 AuthorizationPolicy 에 신원이 없으면"
say "    거부된다. 실측에서는 정책이 옳았고 신원이 안 붙은 것이었다 - 둘은"
say "    처방이 다르다."
say "  - 노드를 넘는 경로. 15008 이 막히면 증상은 거부가 아니라 타임아웃이다"
say "    (Gotcha 13)."
say "  - 방금 뜬 파드. istio-cni 가 아직 등록하지 않았을 수 있다 - 빠진 것이"
say "    보이면 그 파드의 나이를 함께 볼 것."
hr

if [ "$FAILS" -gt 0 ]; then
  say "판정: 실패 - 메시 밖 파드 ${FAILS}개 (측정 불가 노드 ${UNMEAS}개)"
  exit 1
fi
if [ "$UNMEAS" -gt 0 ]; then
  say "판정: 측정 불가 - 노드 ${UNMEAS}개에서 ztunnel 의 목록을 받지 못했다"
  exit 2
fi
say "판정: 통과 - ambient 대상 파드 전부에 프록시가 서 있다"
exit 0
