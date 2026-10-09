#!/usr/bin/env bash
# 7-6: Falco 탐지 규칙을 실제 자극으로 검증한다
#
# ★★★ 2026-10-09 에 매니페스트(06-falco-test.yaml)를 이 스크립트로 바꿨다.
#   그 매니페스트의 시험 셋 중 **둘은 어떤 규칙도 건드릴 수 없었다** - 즉
#   Falco 가 멀쩡해도 영원히 조용하다. 규칙과 대조하면 이렇다:
#     Test 1  sh -c echo             -> Terminal shell in container
#             발화하지 않는다. 그 규칙은 proc.tty != 0 을 요구하고, 그 조건은
#             프로브 오탐 260건을 막으려고 §8-64 에서 **일부러** 넣은 것이다.
#     Test 2  cat /etc/passwd        -> Modify sensitive files in container
#             발화하지 않는다. 그 규칙은 open_write 이고 이것은 read 다.
#             (기본 룰셋의 sensitive_files 에도 /etc/passwd 는 없다.)
#     Test 3  SA 토큰 읽기            -> Read sensitive Kubernetes files
#             발화한다. ★ 그런데 **그 하나가 토큰 50자를 stdout 에 찍었다** -
#             그 로그는 filelog 가 걷어 Loki·OpenSearch 에 영구 저장된다.
#             "길이로 마스킹" 은 Gotcha 186 이 금지한 바로 그것이다.
#   ★ 그 밖에: namespace: dev 하드코딩(한 번도 적용되지 않았다) ·
#     busybox:latest(Gotcha 46) · SA 미지정(default SA 로 돌아 7-9 가 보고하는
#     결함을 스위트가 스스로 만든다) · 결과를 아무도 읽지 않는다(run_yaml).
#
# ★★★ 싱크를 틀리면 "탐지 0" 이라는 거짓 결론이 나온다 - 실제로 두 번 틀렸다.
#   falco.yaml 에 **stdout_output 이 없다**(http_output 만 있다). 그래서
#   kubectl logs ds/falco 에는 기동 로그밖에 없고, 그것을 보고 "Falco 가
#   아무것도 탐지하지 않는다" 고 읽게 된다. 실제 경보는
#     Falco -> falcosidekick(HTTP 2801) -> Kafka 토픽 falco-alerts
#   로 흐른다. ★ Kafka 를 소비하는 길도 있지만 kafka-console-consumer 가
#   끝나지 않아 exec 가 매달렸다(실측 rc=124). 쓸 수 있는 싱크는
#   **falcosidekick 의 /metrics** 다:
#     falcosecurity_falcosidekick_falco_events_total{rule=...,k8s_pod_name=...}
#   규칙별·**파드별** 카운터라 전후 차이로 판정할 수 있다.
#
# ★★ 파드별이라는 점이 결정적이다. 이 클러스터는 Falco 경보가 **분당 78건**
#   들어온다(900초 1,438건). 규칙별 합계로 보면 Read sensitive Kubernetes files
#   가 15초에 +14 씩 오르므로 "내 자극이 발화했나" 에 답할 수 없다.
#   파드 이름으로 귀속하면 소음과 섞이지 않는다(실측으로 넷 전부 귀속됐다).
#
# 검증된 자극 넷 (실측으로 골랐다 - 짐작하지 않았다)
#   Terminal shell in container        pty 안에서 kubectl exec -it (tty 필요)
#   Read sensitive Kubernetes files    SA 토큰을 읽고 /dev/null 로 버린다
#   Container escape attempt           /bin/nsenter 를 exec 한다(실패해도 된다 -
#                                      규칙은 spawned_process 다)
#   Modify sensitive files in container /etc/passwd 에 append 를 시도한다
#
# ★ 재지 못하는 규칙 둘 - 왜인지 적어 둔다
#   Unexpected outbound connection from container
#     클러스터 밖으로 실제 연결을 만들어야 한다. 검증 스위트가 외부 트래픽을
#     내보내는 것은 대가가 크다고 보아 하지 않는다.
#   Crypto mining detection
#     실측으로 **발화하지 않았다** - 듣고 있지 않은 ClusterIP:3333 으로의
#     실패한 connect 는 이벤트를 만들지 않는다. 듣는 상대가 필요하다.
#
# ★★ 프로브가 **root 로 돈다.** 비-root(uid 1000)로 재 보니 넷 중
#   Modify sensitive files in container **하나가 발화하지 않았다** - 쓰기 open 이
#   권한 검사에서 막혀 이벤트가 생기지 않는다. 그 규칙은 애초에 /etc 를 쓸 수
#   있는 프로세스만 건드릴 수 있으니, **비-root 로 재는 것은 아무것도 재지
#   않는 것**이다. 대가를 알고 고른 것이다: local 의 Kyverno 는 Audit 이라
#   막지 않지만 disallow-root-user 위반 이벤트가 하나 남는다. 수명은
#   이 스크립트가 도는 몇십 초다.
#
# ★★ 판정은 **셋**이다 - 통과 / 실패 / 측정 불가(종료 코드 0/1/2).
#   도구가 없거나 /metrics 를 받지 못한 것을 "탐지되지 않았다" 로 적지 않는다
#   (Gotcha 191·194 가 고친 바로 그 자리다).
#
# 쓰는 법
#   bash 06-falco-test.sh [namespace]
#   KEEP=1 bash 06-falco-test.sh local   # 프로브를 남긴다(진단용)
set -uo pipefail

NAMESPACE="${1:-dev}"
PROBE=oim-falco-probe
PROBE_IMAGE="${FALCO_PROBE_IMAGE:-docker.io/library/busybox:1.37.0}"
FSK_PORT="${FSK_PORT:-12806}"
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"

TMP="$(mktemp -d)"
PF_PID=""
cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null
  if [ "${KEEP:-0}" != "1" ]; then
    kubectl -n "$NAMESPACE" delete pod "$PROBE" --ignore-not-found --wait=false --force --grace-period=0 >/dev/null 2>&1
    kubectl -n "$NAMESPACE" delete sa "$PROBE" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }

say "=== 7-6: Falco 규칙 검증 ==="
say "네임스페이스: $NAMESPACE · 프로브 이미지: $PROBE_IMAGE"
hr

# --- 0. 장치 대조군 --------------------------------------------------------
for t in kubectl curl python3; do
  command -v "$t" >/dev/null 2>&1 || { say "[측정 불가] $t 이 없다."; exit 2; }
done
kubectl cluster-info >/dev/null 2>&1 || { say "[측정 불가] 클러스터에 닿지 못한다."; exit 2; }
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
  say "[측정 불가] 네임스페이스 '$NAMESPACE' 가 없다."
  say "            ★ 예전 매니페스트가 'dev' 를 하드코딩해 늘 여기서 멈췄다."
  exit 2
}

HAVE_PTY=1
command -v script >/dev/null 2>&1 || HAVE_PTY=0
[ "$HAVE_PTY" -eq 1 ] || say "[참고] script(util-linux)가 없다 — tty 가 필요한 규칙은 측정 불가로 남는다."

if ! kubectl -n "$NAMESPACE" get ds falco >/dev/null 2>&1; then
  say "[측정 불가] '$NAMESPACE' 에 falco DaemonSet 이 없다."
  exit 2
fi
FALCO_READY="$(kubectl -n "$NAMESPACE" get ds falco -o jsonpath='{.status.numberReady}' 2>/dev/null)"
say "falco DaemonSet ready: ${FALCO_READY:-?}"

FSK="$(kubectl -n "$NAMESPACE" get pods --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep '^falcosidekick' | head -1)"
if [ -z "$FSK" ]; then
  say "[측정 불가] falcosidekick 파드가 없다 — 경보 싱크를 읽을 수 없다."
  say "            ★ Falco 는 stdout 으로 내보내지 않는다(falco.yaml 에"
  say "              stdout_output 이 없고 http_output 만 있다)."
  exit 2
fi
say "falcosidekick: $FSK"

kubectl -n "$NAMESPACE" port-forward "$FSK" "${FSK_PORT}:2801" > "$TMP/pf.log" 2>&1 &
PF_PID=$!
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if curl -sf --max-time 5 "http://127.0.0.1:${FSK_PORT}/metrics" -o "$TMP/m0.txt" 2>/dev/null; then ok=1; break; fi
done
if [ "$ok" -ne 1 ] || [ ! -s "$TMP/m0.txt" ]; then
  say "[측정 불가] falcosidekick /metrics 를 받지 못했다."
  exit 2
fi
if ! grep -q '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt"; then
  say "[측정 불가] /metrics 에 falco_events_total 시계열이 없다."
  say "            (falcosidekick 의 prometheus 출력이 꺼져 있을 수 있다)"
  exit 2
fi
say "/metrics 수신 $(wc -c < "$TMP/m0.txt") 바이트 · 규칙 시계열 $(grep -c '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt") 개"
hr

# --- 0-b. 노드 커버리지 --------------------------------------------------
# ★★★ 2026-10-09 에 이 검사를 더했다. 첫 실측에서 프로브가 104 에 떴고 넷 다
#   "탐지 0" 이 나왔는데, 원인은 자극도 규칙도 아니었다 - **그 노드의 Falco 가
#   싱크에 닿지 못하는 것**이었다(falcosidekick 은 103 에 있다). 실측:
#     falcosidekick 이 본 hostname 라벨: 69개 시계열 전부 local-ubuntu3
#     104 falco 로그: libcurl failed to perform call: Timeout was reached ·
#                     "http" output timeout, all output channels are blocked (105줄)
#     103 falco 로그: 같은 오류 0줄
#     cilium monitor: xx drop (Policy denied) identity 6->... -> <fsk>:2801 SYN
#   identity 6 은 remote-node 다. allow-falcosidekick-access 가 2801 을
#   **falco 파드 라벨**로만 여는데 Falco 는 hostNetwork 라 파드 신원이 없다
#   (Gotcha 110 2번). 그래서 **같은 노드만 통하고 나머지는 조용히 버려진다.**
# ★ 이 검사가 없으면 그 결함이 "자극이 잘못됐나" 로 읽힌다 - 측정 자리를
#   의심하기 전에 측정 대상을 고치려 들게 된다(Gotcha 187 과 같은 부류).
hostnames_seen() {
  grep '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt" \
    | grep -oE 'hostname="[^"]*"' | sed -E 's/hostname="(.*)"/\1/' \
    | tr 'A-Z' 'a-z' | sort -u
}
FALCO_NODES="$(kubectl -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
  | grep '^falco-' | awk '{print $2}' | tr 'A-Z' 'a-z' | sort -u)"
SEEN="$(hostnames_seen)"
say "경보를 보내온 노드:"
printf '%s\n' "$SEEN" | sed '/^$/d' | sed 's/^/  + /'
COVERAGE_MISSING=0
for n in $FALCO_NODES; do
  if ! printf '%s\n' "$SEEN" | grep -qx "$n"; then
    COVERAGE_MISSING=$((COVERAGE_MISSING + 1))
    say "  [실패] $n — 이 노드의 경보가 싱크에 **하나도** 없다"
    FP="$(kubectl -n "$NAMESPACE" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
      | grep '^falco-' | awk -v N="$n" 'tolower($2)==N {print $1}' | head -1)"
    if [ -n "$FP" ]; then
      ERRS="$(kubectl -n "$NAMESPACE" logs "$FP" -c falco --tail=400 2>/dev/null \
        | grep -icE 'libcurl|output timeout|all output channels are blocked' || true)"
      say "         $FP 의 전송 오류 줄수(최근 400줄): ${ERRS:-?}"
      if [ "${ERRS:-0}" -gt 0 ]; then
        say "         ★ 전달 경로가 막혀 있다. 그 노드의 런타임 탐지는 유실된다."
        say "           cilium monitor --type drop 으로 목적지 2801 의 drop 을 볼 것."
      else
        say "         ★ 전송 오류는 없다 — 그 노드가 정말 조용한 것일 수 있다."
      fi
    fi
  fi
done
if [ "$COVERAGE_MISSING" -eq 0 ]; then
  say "  모든 Falco 노드가 경보를 보내오고 있다"
fi
hr

# 프로브 파드 이름으로 귀속된 시계열만 뽑아 (규칙 -> 건수) 로 줄인다.
snap() {
  curl -s --max-time 10 "http://127.0.0.1:${FSK_PORT}/metrics" \
    | grep '^falcosecurity_falcosidekick_falco_events_total' \
    | grep "k8s_pod_name=\"${PROBE}\"" \
    | sed -E 's/.*rule="([^"]*)".*\} ([0-9.e+]+)$/\1\t\2/' \
    | awk -F'\t' '{s[$1]+=$2} END{for (k in s) printf "%s\t%d\n", k, s[k]}' \
    | sort
}

# --- 1. 프로브 ------------------------------------------------------------
# ★ PROBE_NODE_NAME 으로 노드를 고정할 수 있다. 기본은 고정하지 않는다 -
#   스케줄러가 고르게 두고, 어느 노드에 떴는지를 결과에 적는다. 노드별로
#   확인하려면 노드 이름을 주고 여러 번 돌릴 것(노드 커버리지 절이 전 노드를
#   함께 보지만, 그것은 "경보가 오고 있나" 이고 이것은 "자극이 탐지되나" 다).
NODE_LINE=""
if [ -n "${PROBE_NODE_NAME:-}" ]; then
  NODE_LINE="
  nodeName: ${PROBE_NODE_NAME}"
  say "프로브를 노드에 고정: ${PROBE_NODE_NAME}"
fi

kubectl -n "$NAMESPACE" delete pod "$PROBE" --ignore-not-found --wait=true --force --grace-period=0 >/dev/null 2>&1
if ! kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $PROBE
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: falco-test
    app.kubernetes.io/component: security-verification
---
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: falco-test
    app.kubernetes.io/component: security-verification
    app.kubernetes.io/part-of: oneinchmarket
spec:
  serviceAccountName: $PROBE
  restartPolicy: Never${NODE_LINE}
  containers:
    - name: probe
      image: $PROBE_IMAGE
      command: ["sleep", "180"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
YAML
then
  say "[측정 불가] 프로브를 만들지 못했다."
  exit 2
fi

if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$PROBE" --timeout=90s >/dev/null 2>&1; then
  say "[측정 불가] 프로브가 90초 안에 Ready 가 되지 않았다."
  kubectl -n "$NAMESPACE" get "pod/$PROBE" -o wide 2>&1 | sed 's/^/  /'
  exit 2
fi
PROBE_NODE="$(kubectl -n "$NAMESPACE" get "pod/$PROBE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
say "프로브 Ready (노드: $PROBE_NODE)"

snap > "$TMP/before.tsv"
say "기준선(이 파드 이름의 시계열): $(awk 'END{print NR+0}' "$TMP/before.tsv") 개"
hr

# --- 2. 자극 -------------------------------------------------------------
# ★ 자극의 종료 코드를 판정에 쓰지 않는다 - nsenter 와 /etc/passwd 쓰기는
#   **실패하는 것이 정상**이다(규칙이 보는 것은 시도다).
EXPECTED=""

if [ "$HAVE_PTY" -eq 1 ]; then
  say "자극 1/4: pty 안에서 쉘 (Terminal shell in container)"
  script -qec "kubectl -n $NAMESPACE exec -it $PROBE -- sh -c 'sleep 1'" /dev/null >/dev/null 2>&1 || true
  EXPECTED="${EXPECTED}Terminal shell in container
"
else
  say "자극 1/4: 건너뜀 (script 없음) — Terminal shell in container 는 측정 불가"
fi

say "자극 2/4: SA 토큰 읽기 (Read sensitive Kubernetes files)"
# ★ 값을 보지 않는다. /dev/null 로 버리고 길이도 찍지 않는다(Gotcha 186).
kubectl -n "$NAMESPACE" exec "$PROBE" -- sh -c \
  'cat /var/run/secrets/kubernetes.io/serviceaccount/token > /dev/null 2>&1 || true' >/dev/null 2>&1 || true
EXPECTED="${EXPECTED}Read sensitive Kubernetes files
"

say "자극 3/4: nsenter exec (Container escape attempt)"
kubectl -n "$NAMESPACE" exec "$PROBE" -- /bin/nsenter --help >/dev/null 2>&1 || true
EXPECTED="${EXPECTED}Container escape attempt
"

say "자극 4/4: /etc/passwd 쓰기 시도 (Modify sensitive files in container)"
kubectl -n "$NAMESPACE" exec "$PROBE" -- sh -c \
  'echo probe >> /etc/passwd 2>/dev/null || true' >/dev/null 2>&1 || true
EXPECTED="${EXPECTED}Modify sensitive files in container
"

say "경보가 싱크에 도달하기를 ${SETTLE_SECONDS}초 기다린다"
sleep "$SETTLE_SECONDS"
snap > "$TMP/after.tsv"
hr

# --- 3. 판정 -------------------------------------------------------------
printf '%s' "$EXPECTED" | sed '/^$/d' > "$TMP/expected.txt"

cat > "$TMP/judge.py" <<'PY'
import os, sys

tmp = sys.argv[1]

def load(p):
    out = {}
    if not os.path.exists(p):
        return out
    for line in open(p, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        try:
            out[parts[0]] = int(parts[1])
        except ValueError:
            continue
    return out

before = load(os.path.join(tmp, "before.tsv"))
after = load(os.path.join(tmp, "after.tsv"))
expected = [l.strip() for l in open(os.path.join(tmp, "expected.txt"),
                                   encoding="utf-8") if l.strip()]

print("=== 규칙별 증분 (프로브 파드에 귀속된 것만) ===")
detected = 0
missing = []
for rule in expected:
    d = after.get(rule, 0) - before.get(rule, 0)
    if d > 0:
        print("   [통과] +%-4d %s" % (d, rule))
        detected += 1
    else:
        print("   [실패] +0    %s   <- 자극했으나 경보가 오지 않았다" % rule)
        missing.append(rule)

extra = sorted(set(after) - set(expected))
if extra:
    print()
    print("   [참고] 자극하지 않았는데 올라온 규칙 %d개:" % len(extra))
    for r in extra:
        print("          +%d %s" % (after.get(r, 0) - before.get(r, 0), r))

print()
print("VERDICT detected=%d missing=%d" % (detected, len(missing)))
PY

python3 "$TMP/judge.py" "$TMP" | tee "$TMP/report.txt"
hr

# --- 4. 참고: 소음 ------------------------------------------------------
# ★ 이것은 판정이 아니다. 그러나 적어 두어야 한다 - 오탐은 단순한 소음이
#   아니고 **진짜 경보를 묻는다**(custom-rules.yaml 머리말이 같은 경고를 적고
#   그때 고쳤는데, 실측으로 다시 같은 규모다).
say "참고: 경보 상위 규칙 (누적, 전 클러스터)"
curl -s --max-time 10 "http://127.0.0.1:${FSK_PORT}/metrics" \
  | grep '^falcosecurity_falcosidekick_falco_events_total' \
  | sed -E 's/.*rule="([^"]*)".*\} ([0-9.e+]+)$/\1\t\2/' \
  | awk -F'\t' '{s[$1]+=$2} END{for (k in s) printf "%12d  %s\n", s[k], k}' \
  | sort -rn | head -8 | sed 's/^/  /'
hr

say "이 검사가 **재지 못하는 것**"
say "  - Unexpected outbound connection from container. 클러스터 밖으로"
say "    실제 연결을 만들어야 해서 하지 않는다."
say "  - Crypto mining detection. 실측으로 발화하지 않았다 — 듣고 있지 않은"
say "    주소로의 실패한 connect 는 이벤트를 만들지 않는다."
say "  - 다른 노드의 Falco. 프로브는 한 노드에만 뜬다(이번에는 ${PROBE_NODE})."
say "  - 경보가 **저장되는지**. 여기서 보는 것은 falcosidekick 의 카운터이고,"
say "    그 뒤의 Kafka·OpenSearch 적재는 별개다(Gotcha 12 와 같은 자리)."
hr

V="$(grep '^VERDICT ' "$TMP/report.txt" | tail -1 || true)"
DET="$(printf '%s' "$V" | sed -n 's/.*detected=\([0-9]*\).*/\1/p')"
MIS="$(printf '%s' "$V" | sed -n 's/.*missing=\([0-9]*\).*/\1/p')"
if [ -z "${DET:-}" ] || [ -z "${MIS:-}" ]; then
  say "판정: 측정 불가 — 판정 줄을 읽지 못했다"
  exit 2
fi
if [ "$MIS" -gt 0 ] && [ "$DET" -eq 0 ] && [ "$COVERAGE_MISSING" -gt 0 ]; then
  # ★ 넷 다 0 이고 그 노드의 경보가 애초에 싱크에 없으면, 규칙이 아니라
  #   **전달 경로**가 원인이다. 그것을 "규칙이 탐지하지 못한다" 로 적지 말 것.
  say "판정: 실패 — 프로브가 뜬 노드($PROBE_NODE)의 Falco 가 싱크에 닿지 못한다"
  say "        규칙이 아니라 **전달 경로**가 원인이다 — 위의 노드 커버리지 절 참조."
  exit 1
fi
if [ "$MIS" -gt 0 ]; then
  say "판정: 실패 — 자극했는데 탐지되지 않은 규칙 ${MIS}개 (탐지 ${DET}개)"
  say "        프로브 노드: $PROBE_NODE"
  exit 1
fi
if [ "$COVERAGE_MISSING" -gt 0 ]; then
  say "판정: 실패 — 자극한 ${DET}개는 탐지됐으나, 경보를 보내오지 않는 Falco 노드가 ${COVERAGE_MISSING}개다"
  exit 1
fi
if [ "$DET" -eq 0 ]; then
  say "판정: 측정 불가 — 자극을 하나도 걸지 못했다"
  exit 2
fi
say "판정: 통과 — 자극한 규칙 ${DET}개가 모두 탐지됐고 모든 Falco 노드가 경보를 보내온다"
exit 0
