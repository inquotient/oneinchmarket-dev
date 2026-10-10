#!/usr/bin/env bash
# 7-6: Falco 탐지 규칙을 실제 자극으로 검증한다 — 노드마다
#
# ★★★ 2026-10-09 에 매니페스트(06-falco-test.yaml)를 이 스크립트로 바꿨다.
#   그 매니페스트의 시험 셋 중 **둘은 어떤 규칙도 건드릴 수 없었다** - 즉
#   Falco 가 멀쩡해도 영원히 조용하다. 규칙과 대조하면 이렇다:
#     Test 1  sh -c echo             -> Terminal shell in container
#             발화하지 않는다. 그 규칙은 proc.tty != 0 을 요구하고, 그 조건은
#             프로브 오탐 260건을 막으려고 §8-64 에서 **일부러** 넣은 것이다.
#     Test 2  cat /etc/passwd        -> Modify sensitive files in container
#             발화하지 않는다. 그 규칙은 open_write 이고 이것은 read 다.
#     Test 3  SA 토큰 읽기            -> Read sensitive Kubernetes files
#             발화한다. ★ 그런데 **그 하나가 토큰 50자를 stdout 에 찍었다** -
#             그 로그는 filelog 가 걷어 Loki·OpenSearch 에 영구 저장된다.
#             "길이로 마스킹" 은 Gotcha 186 이 금지한 바로 그것이다.
#
# ★★★ 싱크를 틀리면 "탐지 0" 이라는 거짓 결론이 나온다 - 실제로 두 번 틀렸다.
#   falco.yaml 에 **stdout_output 이 없다**(http_output 만 있다). 그래서
#   kubectl logs ds/falco 에는 기동 로그밖에 없다. 실제 경보는
#     Falco -> falcosidekick(HTTP 2801) -> Kafka 토픽 falco-alerts
#   로 흐르고, 쓸 수 있는 싱크는 **falcosidekick 의 /metrics** 다:
#     falcosecurity_falcosidekick_falco_events_total{rule=,hostname=,k8s_pod_name=}
#   규칙별·파드별·**노드별** 카운터라 전후 차이로 판정할 수 있다.
#   (Kafka 를 소비하는 길도 있으나 kafka-console-consumer 가 끝나지 않아
#    exec 가 매달렸다 - 실측 rc=124.)
#
# ★★ 파드별이라는 점이 결정적이다. 이 클러스터는 Falco 경보가 **분당 78건**
#   들어온다. 규칙별 합계로 보면 "내 자극이 발화했나" 에 답할 수 없다.
#
# ================== 2026-10-10 에 고친 것 둘 =========================
#
# ★★★ (A) 노드 커버리지가 **싱크에 이미 쌓인 경보**에 의존했다 - 그것은
#   거짓 경보를 낸다. 옛 판정은 "/metrics 의 hostname 라벨에 이 노드가
#   등장하는가" 였는데, 그 카운터는 **누적값**이라 falcosidekick 이 재기동하면
#   0 에서 다시 시작한다. 그러면 멀쩡한 클러스터에서 **전 노드가 [실패]** 로
#   보고된다(실측으로 falcosidekick 은 하루 사이에 노드를 옮겼다).
#   게다가 그 질문은 "이 노드가 **언젠가** 경보를 보냈나" 이지 "**지금**
#   보낼 수 있나" 가 아니다.
#   -> 지금은 **노드마다 프로브를 띄워 직접 자극한다.** 판정은 규칙 하나가
#      아니라 **(규칙, hostname) 쌍의 증분**으로 한다.
#   ★★ 그 쌍이 공짜로 하나를 더 잡는다 - **FALCO_HOSTNAME 회귀**다.
#      그 env 가 빠지면 경보의 hostname 이 노드명이 아니라 **파드명**이 되고,
#      그러면 옛 판정은 조용히 무의미해졌다(Gotcha 197). 쌍으로 보면 그 순간
#      "그 규칙은 올랐는데 hostname 이 이 노드가 아니다" 로 드러난다.
#   ★ 뜨지 못한 노드는 **측정 불가**다. 꺼진 노드를 [실패] 로 적지 않는다
#     (104 가 반복해서 꺼진 이력이 있다 - 원인은 강제종료였고 Gotcha 193 은 닫혔다).
#
# ★★★ (B) TOCTOU 완화 유무를 재지 못했다 - 그런데 그것이 꺼지면 **센서가
#   죽는다.** Gotcha 199 의 실측이다: 컨테이너에 tracefs 가 없으면
#     libbpf: failed to determine tracepoint 'syscalls/sys_enter_openat' ...
#     libpman: failure while attaching TOCTOU mitigation program for 'openat'
#   가 5건 나고, 그 경로 경합이 실제로
#     Error: could not parse param 2 (name) for event ... type 307 (openat)
#   로 **exitCode 1** 을 만든다. 즉 (1) 파일 규칙이 경로 교체로 회피되고
#   (2) 탐지기 자체가 종료된다. 처방은 /sys/kernel/tracing 읽기 전용 hostPath 다.
#   -> 0-c 절이 그것을 **셋으로** 본다: 선언(volumeMount) · **실측(컨테이너
#      안에서 tracefs 가 읽히는가)** · 로그(TOCTOU 실패 건수).
#   ★★ 판정의 주력은 **실측**이다. 로그는 회전하면 사라지므로 보조다 -
#      그리고 Gotcha 199 가 적은 타이밍 함정이 있다: TOCTOU 줄은
#      "One ring buffer every 'N' CPUs" **뒤에** 나온다. 그 줄이 로그에
#      없으면 기동 구간이 밀려난 것이므로 **0건을 "통과" 로 읽으면 안 된다.**
#      그래서 그 줄의 유무를 먼저 보고, 없으면 그 항목만 측정 불가로 적는다.
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
#     클러스터 밖으로 실제 연결을 만들어야 한다. 대가가 크다고 보아 하지 않는다.
#   Crypto mining detection
#     실측으로 **발화하지 않았다** - 듣고 있지 않은 ClusterIP:3333 으로의
#     실패한 connect 는 이벤트를 만들지 않는다. 듣는 상대가 필요하다.
#
# ★★ 프로브가 **root 로 돈다.** 비-root(uid 1000)로 재 보니 넷 중
#   Modify sensitive files in container **하나가 발화하지 않았다** - 쓰기 open 이
#   권한 검사에서 막혀 이벤트가 생기지 않는다. **비-root 로 재는 것은 아무것도
#   재지 않는 것**이다. 대가: local 의 Kyverno 는 Audit 이라 막지 않지만
#   disallow-root-user 위반 이벤트가 노드마다 하나 남는다.
#
# ★★ 판정은 **셋**이다 - 통과 / 실패 / 측정 불가(종료 코드 0/1/2).
#   도구가 없거나 /metrics 를 받지 못한 것을 "탐지되지 않았다" 로 적지 않는다
#   (Gotcha 191·194 가 고친 바로 그 자리다).
#
# ★ 이 스크립트는 **파일로 실행할 것** - ssh 에 'bash -s' 로 넘기면
#   안쪽의 script -qec "kubectl exec -it ..." 가 heredoc 을 stdin 으로 먹는다.
#     scp 06-falco-test.sh node:/tmp/
#     ssh node 'bash /tmp/06-falco-test.sh local < /dev/null'
#
# 쓰는 법
#   bash 06-falco-test.sh [namespace]
#   PROBE_NODE_NAME=<node> bash 06-falco-test.sh local   # 한 노드만(진단용)
#   KEEP=1 bash 06-falco-test.sh local                   # 프로브를 남긴다
set -uo pipefail

NAMESPACE="${1:-dev}"
PROBE_BASE=oim-falco-probe
PROBE_IMAGE="${FALCO_PROBE_IMAGE:-docker.io/library/busybox:1.37.0}"
FSK_PORT="${FSK_PORT:-12806}"
SETTLE_SECONDS="${SETTLE_SECONDS:-20}"
TRACEFS_ID_PATH=/sys/kernel/tracing/events/syscalls/sys_enter_openat/id

TMP="$(mktemp -d)"
PF_PID=""
PROBES=""
cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null
  if [ "${KEEP:-0}" != "1" ]; then
    for p in $PROBES; do
      kubectl -n "$NAMESPACE" delete pod "$p" --ignore-not-found --wait=false \
        --force --grace-period=0 >/dev/null 2>&1
    done
    kubectl -n "$NAMESPACE" delete sa "$PROBE_BASE" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }
lc()  { tr 'A-Z' 'a-z'; }

say "=== 7-6: Falco 규칙 검증 (노드별) ==="
say "네임스페이스: $NAMESPACE · 프로브 이미지: $PROBE_IMAGE"
hr

FAILS=0
UNMEASURED=0

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
[ "$HAVE_PTY" -eq 1 ] || say "[참고] script(util-linux)가 없다 — tty 가 필요한 규칙은 기대 목록에서 뺀다."

kubectl -n "$NAMESPACE" get ds falco >/dev/null 2>&1 || {
  say "[측정 불가] '$NAMESPACE' 에 falco DaemonSet 이 없다."; exit 2; }
say "falco DaemonSet ready: $(kubectl -n "$NAMESPACE" get ds falco -o jsonpath='{.status.numberReady}' 2>/dev/null)"

# falco 파드 -> 노드. ★ 노드명은 원본 그대로 보관한다 - nodeName 은 대소문자를
#   가리고, 지표의 hostname 에는 대문자 잔재가 섞인다(실측). 비교만 소문자로 한다.
kubectl -n "$NAMESPACE" get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null \
  | grep '^falco-' > "$TMP/falcopods.tsv"
if [ ! -s "$TMP/falcopods.tsv" ]; then
  say "[측정 불가] falco 파드를 찾지 못했다."; exit 2
fi
say "falco 파드 $(wc -l < "$TMP/falcopods.tsv") 개:"
sed 's/\t/  @  /; s/^/  /' "$TMP/falcopods.tsv"

FSK="$(kubectl -n "$NAMESPACE" get pods --no-headers \
  -o custom-columns=N:.metadata.name 2>/dev/null | grep '^falcosidekick' | head -1)"
if [ -z "$FSK" ]; then
  say "[측정 불가] falcosidekick 파드가 없다 — 경보 싱크를 읽을 수 없다."
  say "            ★ Falco 는 stdout 으로 내보내지 않는다(falco.yaml 에"
  say "              stdout_output 이 없고 http_output 만 있다)."
  exit 2
fi
say "falcosidekick: $FSK (노드: $(kubectl -n "$NAMESPACE" get pod "$FSK" -o jsonpath='{.spec.nodeName}' 2>/dev/null))"
say "  ★ 그 파드가 어느 노드에 있는지는 판정에 쓰지 않는다 — 전에는 반대편"
say "    노드의 경보가 조용히 버려졌다(Gotcha 197). 지금은 노드마다 직접 잰다."

kubectl -n "$NAMESPACE" port-forward "$FSK" "${FSK_PORT}:2801" > "$TMP/pf.log" 2>&1 &
PF_PID=$!
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  curl -sf --max-time 5 "http://127.0.0.1:${FSK_PORT}/metrics" -o "$TMP/m0.txt" 2>/dev/null && { ok=1; break; }
done
if [ "$ok" -ne 1 ] || [ ! -s "$TMP/m0.txt" ]; then
  say "[측정 불가] falcosidekick /metrics 를 받지 못했다."; exit 2
fi
if ! grep -q '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt"; then
  say "[측정 불가] /metrics 에 falco_events_total 시계열이 없다."
  say "            (falcosidekick 의 prometheus 출력이 꺼져 있을 수 있다)"
  exit 2
fi
say "/metrics 수신 $(wc -c < "$TMP/m0.txt") 바이트 · 규칙 시계열 $(grep -c '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt") 개"
hr

# --- 0-c. TOCTOU 완화 (Gotcha 199) ---------------------------------------
say "TOCTOU 완화 — 꺼져 있으면 파일 규칙이 경로 교체로 회피되고 센서가 죽는다"

DECL="$(kubectl -n "$NAMESPACE" get ds falco \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{"="}{.readOnly}{"\n"}{end}' 2>/dev/null \
  | grep '^/sys/kernel/tracing=' | head -1)"
if [ -z "$DECL" ]; then
  say "  [실패] DaemonSet 에 /sys/kernel/tracing 마운트 선언이 없다"
  say "         -> TOCTOU 완화가 붙지 않는다. 처방은 읽기 전용 hostPath 다(Gotcha 199)."
  FAILS=$((FAILS + 1))
else
  say "  선언: /sys/kernel/tracing (readOnly=${DECL#*=})"
  [ "${DECL#*=}" = "true" ] || \
    say "         [참고] 읽기 전용이 아니다 — Falco 는 읽기만으로 붙는다(실측)."
fi

# ★ 이 루프는 **fd 3** 으로 읽는다 — stdin 으로 돌리면 안쪽 kubectl 이 그것을
#   먹을 수 있다. 아래 노드 루프에서 실제로 그렇게 **반쪽만 돌고 통과**했다.
while IFS="$(printf '\t')" read -r fp fnode <&3; do
  [ -n "$fp" ] || continue
  # 실측이 판정의 주력이다 - 선언이 있어도 노드에 tracefs 가 없으면 못 읽는다.
  V="$(kubectl -n "$NAMESPACE" exec "$fp" -c falco -- cat "$TRACEFS_ID_PATH" 2>/dev/null < /dev/null | tr -d '[:space:]')"
  case "${V:-}" in
    ''|*[!0-9]*)
      say "  [실패] $fp ($fnode) — tracefs 를 읽지 못한다 (값=[${V:-}])"
      say "         -> 컨테이너에 tracefs 가 없으면 TOCTOU 완화가 attach 되지 않는다."
      FAILS=$((FAILS + 1)) ;;
    *)
      say "  [통과] $fp ($fnode) — tracefs 읽힘 (sys_enter_openat id=$V)" ;;
  esac

  # 로그는 보조다. ★ 'One ring buffer' 가 없으면 기동 구간이 로그 창에서
  #   밀려난 것이므로 TOCTOU 0건을 통과로 읽지 않는다(Gotcha 199 의 타이밍 함정).
  LOG="$TMP/log.$fp"
  kubectl -n "$NAMESPACE" logs "$fp" -c falco --tail=600 > "$LOG" 2>/dev/null
  RB="$(grep -c "One ring buffer" "$LOG" 2>/dev/null)"
  TC="$(grep -ciE 'TOCTOU mitigation|failed to determine tracepoint' "$LOG" 2>/dev/null)"
  if [ "${RB:-0}" -eq 0 ]; then
    say "         [측정 불가] 기동 로그가 로그 창에 없다('One ring buffer' 0줄) —"
    say "                     TOCTOU 실패 건수를 로그로 판정할 수 없다(실측값은 위)."
    UNMEASURED=$((UNMEASURED + 1))
  elif [ "${TC:-0}" -gt 0 ]; then
    say "         [실패] TOCTOU attach 실패 ${TC}건 (기동 로그 안)"
    FAILS=$((FAILS + 1))
  else
    say "         TOCTOU attach 실패 0건 (기준점 'One ring buffer' ${RB}줄 확인)"
  fi

  # 참고: 센서 생존. exitCode 1 은 TOCTOU 경합이 남기는 바로 그 흔적이다.
  RS="$(kubectl -n "$NAMESPACE" get pod "$fp" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
  LX="$(kubectl -n "$NAMESPACE" get pod "$fp" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null)"
  if [ -n "${LX:-}" ]; then
    say "         [참고] restartCount=${RS:-?} · 직전 종료 exitCode=${LX}"
    say "                ★ 이 검사는 그 종료가 **TOCTOU 를 켜기 전의 것인지** 가르지 못한다."
    say "                  위 실측이 통과이면 지금은 켜져 있다는 뜻이고 이 값은 이력이다."
  else
    say "         [참고] restartCount=${RS:-?} · 직전 종료 기록 없음"
  fi
done 3< "$TMP/falcopods.tsv"
hr

# --- 1. 노드별 능동 측정 ---------------------------------------------------
# 프로브 파드 이름으로 걸러 (규칙, hostname) 쌍으로 접는다.
snap() { # $1 = 프로브 파드 이름
  curl -s --max-time 10 "http://127.0.0.1:${FSK_PORT}/metrics" \
    | grep '^falcosecurity_falcosidekick_falco_events_total' \
    | grep "k8s_pod_name=\"$1\"" \
    | sed -E 's/.*hostname="([^"]*)".*rule="([^"]*)".*\} ([0-9.e+]+)$/\2\t\1\t\3/' \
    | awk -F'\t' 'NF==3 {k=$1"\t"tolower($2); s[k]+=$3} END{for (x in s) printf "%s\t%d\n", x, s[x]}' \
    | sort
}

if [ -n "${PROBE_NODE_NAME:-}" ]; then
  printf '%s\n' "$PROBE_NODE_NAME" > "$TMP/targets.txt"
  say "한 노드만 측정: $PROBE_NODE_NAME (PROBE_NODE_NAME 이 주어졌다)"
  say "  ★ 그러면 다른 노드는 **측정 불가**이고 통과가 아니다."
else
  cut -f2 "$TMP/falcopods.tsv" | sed '/^$/d' | sort -u > "$TMP/targets.txt"
fi
say "자극할 노드 $(wc -l < "$TMP/targets.txt") 개"

kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $PROBE_BASE
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: falco-test
    app.kubernetes.io/component: security-verification
    app.kubernetes.io/part-of: oneinchmarket
YAML

: > "$TMP/nodes.tsv"
TARGET_COUNT="$(sed '/^$/d' "$TMP/targets.txt" | wc -l | tr -d ' ')"
IDX=0
# ★★★ 이 루프를 **stdin 으로 몰지 말 것** — `while read ... done < file` 로 짰더니
#   안쪽의 `kubectl exec -it`(과 script 의 pty)가 그 stdin 을 먹어 **첫 회차 뒤
#   루프가 끝났다.** 실측: "자극할 노드 2 개" 를 찍고 노드 1만 재고 `rc=0` 으로
#   **통과**했다 — 고치려던 바로 그 거짓 통과를 새로 만든 것이다.
#   ★ 그래서 둘을 함께 둔다: ① for 루프(노드명은 DNS 라벨이라 공백이 없다)
#   ② 자극마다 `< /dev/null` ③ 루프 뒤의 **건수 가드**(아래). 가드가 핵심이다 —
#   stdin 을 먹는 다른 명령이 들어와도 "반쪽 측정" 이 통과로 새지 않는다.
for NODE in $(sed '/^$/d' "$TMP/targets.txt"); do
  IDX=$((IDX + 1))
  NODE_LC="$(printf '%s' "$NODE" | lc)"
  PROBE="${PROBE_BASE}-${IDX}"
  PROBES="$PROBES $PROBE"
  hr
  say "노드 ${IDX}: $NODE  (프로브 $PROBE)"

  kubectl -n "$NAMESPACE" delete pod "$PROBE" --ignore-not-found --wait=true \
    --force --grace-period=0 >/dev/null 2>&1
  if ! kubectl apply -f - >/dev/null 2>&1 <<YAML
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
  serviceAccountName: $PROBE_BASE
  restartPolicy: Never
  nodeName: $NODE
  tolerations:
    - operator: Exists
  containers:
    - name: probe
      image: $PROBE_IMAGE
      command: ["sleep", "240"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
YAML
  then
    say "  [측정 불가] 프로브를 만들지 못했다."
    printf '%s\t%s\t%s\tunmeasured\n' "$IDX" "$NODE" "$NODE_LC" >> "$TMP/nodes.tsv"
    continue
  fi

  if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$PROBE" --timeout=90s >/dev/null 2>&1; then
    say "  [측정 불가] 프로브가 90초 안에 Ready 가 되지 않았다 — 그 노드가 받지 못한다."
    kubectl -n "$NAMESPACE" get "pod/$PROBE" -o wide 2>&1 | sed 's/^/    /'
    say "              ★ 꺼진·받지 못하는 노드를 [실패] 로 적지 않는다(Gotcha 193)."
    printf '%s\t%s\t%s\tunmeasured\n' "$IDX" "$NODE" "$NODE_LC" >> "$TMP/nodes.tsv"
    continue
  fi

  snap "$PROBE" > "$TMP/before.$IDX.tsv"
  say "  기준선 시계열 $(awk 'END{print NR+0}' "$TMP/before.$IDX.tsv") 개 — 자극 넷을 건다"

  # ★ 자극의 종료 코드를 판정에 쓰지 않는다 - nsenter 와 /etc/passwd 쓰기는
  #   **실패하는 것이 정상**이다(규칙이 보는 것은 시도다).
  # ★ 자극마다 `< /dev/null` 을 붙인다 — 붙이지 않으면 루프의 stdin 을 먹는다(위).
  if [ "$HAVE_PTY" -eq 1 ]; then
    script -qec "kubectl -n $NAMESPACE exec -it $PROBE -- sh -c 'sleep 1'" /dev/null \
      >/dev/null 2>&1 < /dev/null || true
  fi
  # ★ 값을 보지 않는다. /dev/null 로 버리고 길이도 찍지 않는다(Gotcha 186).
  kubectl -n "$NAMESPACE" exec "$PROBE" -- sh -c \
    'cat /var/run/secrets/kubernetes.io/serviceaccount/token > /dev/null 2>&1 || true' \
    >/dev/null 2>&1 < /dev/null || true
  kubectl -n "$NAMESPACE" exec "$PROBE" -- /bin/nsenter --help >/dev/null 2>&1 < /dev/null || true
  kubectl -n "$NAMESPACE" exec "$PROBE" -- sh -c \
    'echo probe >> /etc/passwd 2>/dev/null || true' >/dev/null 2>&1 < /dev/null || true

  say "  경보가 싱크에 도달하기를 ${SETTLE_SECONDS}초 기다린다"
  sleep "$SETTLE_SECONDS"
  snap "$PROBE" > "$TMP/after.$IDX.tsv"
  printf '%s\t%s\t%s\tmeasured\n' "$IDX" "$NODE" "$NODE_LC" >> "$TMP/nodes.tsv"
done
hr

# ★★★ 건수 가드 — "반쪽 측정" 이 통과로 새는 것을 막는 유일한 장치다.
#   가드를 "비어 있지 않다" 로 두지 말 것(Gotcha 117·148): **알려진 값과
#   대조**해야 한다. 여기서는 대상 노드 수와 기록된 노드 수가 같아야 한다.
RECORDED="$(wc -l < "$TMP/nodes.tsv" | tr -d ' ')"
if [ "${RECORDED:-0}" -ne "${TARGET_COUNT:-0}" ]; then
  say "[실패] 측정이 대상과 어긋났다 — 대상 ${TARGET_COUNT}개 · 기록 ${RECORDED}개"
  if [ "${RECORDED:-0}" -lt "${TARGET_COUNT:-0}" ]; then
    say "       적게 돌았다. ★ 실측된 원인: 안쪽 명령(kubectl exec -it · script 의 pty)이"
    say "       루프의 stdin 을 먹어 첫 회차 뒤 끝났다. 자극에 '< /dev/null' 이 붙어"
    say "       있는지, 루프가 stdin 으로 돌지 않는지 볼 것."
  else
    say "       많이 돌았다. 대상 목록 한 줄에 이름이 둘 이상 들어갔을 수 있다"
    say "       (PROBE_NODE_NAME 에 공백을 넣으면 그렇게 된다)."
  fi
  FAILS=$((FAILS + 1))
fi
hr

# --- 2. 판정 ---------------------------------------------------------------
{
  [ "$HAVE_PTY" -eq 1 ] && printf '%s\n' "Terminal shell in container"
  printf '%s\n' "Read sensitive Kubernetes files"
  printf '%s\n' "Container escape attempt"
  printf '%s\n' "Modify sensitive files in container"
} > "$TMP/expected.txt"

cat > "$TMP/judge.py" <<'PY'
import os, sys

tmp = sys.argv[1]


def load(path):
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        try:
            out[(parts[0], parts[1])] = int(parts[2])
        except ValueError:
            continue
    return out


expected = [l.strip() for l in open(os.path.join(tmp, "expected.txt"),
                                    encoding="utf-8") if l.strip()]
nodes = []
with open(os.path.join(tmp, "nodes.tsv"), encoding="utf-8") as fh:
    for line in fh:
        p = line.rstrip("\n").split("\t")
        if len(p) == 4:
            nodes.append(p)

fails = unmeasured = 0
for idx, real, lcname, status in nodes:
    print("=== 노드 %s (%s) ===" % (idx, real))
    if status != "measured":
        print("   [측정 불가] 자극을 걸지 못했다 — 위 사유 참조")
        unmeasured += 1
        print()
        continue
    before = load(os.path.join(tmp, "before.%s.tsv" % idx))
    after = load(os.path.join(tmp, "after.%s.tsv" % idx))
    det = mis = 0
    for rule in expected:
        key = (rule, lcname)
        delta = after.get(key, 0) - before.get(key, 0)
        if delta > 0:
            print("   [통과] +%-4d %s" % (delta, rule))
            det += 1
            continue
        mis += 1
        # 규칙은 올랐는데 hostname 이 다른 경우를 가려낸다 - FALCO_HOSTNAME 회귀다.
        other = sorted({h for (r, h) in after if r == rule and h != lcname})
        if other:
            print("   [실패] +0    %s" % rule)
            print("          ★ 그 규칙은 올랐는데 hostname 이 [%s] 다 — 이 노드가 아니다."
                  % ", ".join(other))
            print("            FALCO_HOSTNAME 이 spec.nodeName 을 받지 못하면 이렇게 된다"
                  " (Gotcha 197).")
        else:
            print("   [실패] +0    %s   <- 자극했으나 이 노드의 경보가 오지 않았다" % rule)
    if mis:
        fails += 1
    print("   -> 이 노드: 탐지 %d · 미탐지 %d" % (det, mis))
    print()

print("VERDICT nodefails=%d nodeunmeasured=%d" % (fails, unmeasured))
PY

python3 "$TMP/judge.py" "$TMP" | tee "$TMP/report.txt"
hr

# --- 3. 참고: 판정에 쓰지 않는 것들 ----------------------------------------
say "참고: 싱크가 누적으로 본 hostname (★ 판정에 쓰지 않는다 — 누적값이라"
say "      falcosidekick 이 재기동하면 0 에서 다시 시작한다. 그것이 옛 판정의 결함이다)"
grep '^falcosecurity_falcosidekick_falco_events_total' "$TMP/m0.txt" \
  | grep -oE 'hostname="[^"]*"' | sed -E 's/hostname="(.*)"/\1/' \
  | sort | uniq -c | sed 's/^/  /'
say "  ★ 대문자가 섞여 보이면 FALCO_HOSTNAME 을 넣기 전의 잔재다(실측으로 있었다)."

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
say "  - 경보가 **저장되는지**. 여기서 보는 것은 falcosidekick 의 카운터이고,"
say "    그 뒤의 Kafka·OpenSearch 적재는 별개다(Gotcha 12 와 같은 자리)."
say "  - TOCTOU 완화가 **언제부터** 켜졌는지. 옛 종료(exitCode)가 그 전의"
say "    것인지 가르지 못한다 — 지금 켜져 있는지만 말한다."
say "  - 규칙의 **정확성**. 자극이 발화시킨다는 것만 보이고, 오탐 여부는"
say "    위 '상위 규칙' 수치를 사람이 읽어야 한다."
hr

V="$(grep '^VERDICT ' "$TMP/report.txt" | tail -1)"
NFAIL="$(printf '%s' "$V" | sed -n 's/.*nodefails=\([0-9]*\).*/\1/p')"
NUNM="$(printf '%s' "$V" | sed -n 's/.*nodeunmeasured=\([0-9]*\).*/\1/p')"
if [ -z "${NFAIL:-}" ] || [ -z "${NUNM:-}" ]; then
  say "판정: 측정 불가 — 판정 줄을 읽지 못했다"
  exit 2
fi
FAILS=$((FAILS + NFAIL))
UNMEASURED=$((UNMEASURED + NUNM))

say "집계: 실패 ${FAILS} · 측정 불가 ${UNMEASURED}"
if [ "$FAILS" -gt 0 ]; then
  say "판정: 실패 — TOCTOU(선언·실측·로그) 또는 노드별 탐지에서 실패가 있다"
  exit 1
fi
if [ "$UNMEASURED" -gt 0 ]; then
  say "판정: 측정 불가 — 실패는 없으나 재지 못한 항목이 ${UNMEASURED}개다"
  say "        ★ 이것을 통과로 접지 않는다(Gotcha 191)."
  exit 2
fi
say "판정: 통과 — 모든 Falco 노드에서 자극한 규칙이 탐지되고 TOCTOU 완화가 붙어 있다"
exit 0
