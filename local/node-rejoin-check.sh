#!/usr/bin/env bash
# 노드가 **재부팅 뒤 스스로 클러스터로 돌아오는지**를 강제하고 검증한다.
#
# 왜 필요한가
#   2026-10-08 에 192.168.0.104 가 두 번 떨어졌다. 그때 물은 것이 "왜 복귀하지
#   않나" 였는데, 실측은 **복귀는 되고 있었다**고 답했다 — 마지막 heartbeat 가
#   10-06 06:34Z 였다가 10-08 14:34Z 로 올라와 있었으니 그 사이 스스로 돌아와
#   이틀을 Ready 로 보고한 것이다. 즉 질문을 바꿔야 했다: "복귀하는가" 가 아니라
#   **"복귀를 막을 수 있는 것이 노드에 남아 있는가"** 다.
#   그 목록이 이 스크립트다. 전부 **재부팅해 봐야 드러나는** 것들이라 평소에는
#   조용하다 — 이 레포가 거듭 만난 부류다(Gotcha 58·166: 평소에 돌지 않는 것은
#   재구축·재부팅 때 비로소 청구된다).
#
# bootstrap-baremetal-k3s.sh 와 무엇이 다른가
#   그쪽은 **설치 전·자기 기계**를 본다(--check 가 sysctl 절보다 먼저 끝난다).
#   살아 있는 클러스터에는 다시 돌릴 수 없다 — k3s 를 설치해 버린다. 이쪽은
#   **이미 멤버인 노드 전부**를 ssh 로 돌며 재부팅 생존만 본다.
# ★ 그래서 겹치는 값이 하나 있다(inotify sysctl). **두 곳에 적지 않는다** —
#   이 스크립트는 그 값을 bootstrap-baremetal-k3s.sh 에서 **읽어서** 쓴다
#   (build-images.sh 의 ALL_IMAGES 를 gitlab-registry-bootstrap.sh 가 읽는 것과
#   같은 자리, Gotcha 117). 읽지 못하면 멈춘다.
#
# ★★ 판정은 **셋**이다 — 통과 / 실패 / **측정 불가**. 닿지 못한 노드를 통과로
#   접지 않는다(Gotcha 191). 종료 코드: 0 통과 · 1 실패 · 2 측정 불가.
#   꺼져 있는 노드가 있으면 2 가 나오는 것이 정상이고, 그것이 "확인하지
#   못했다" 는 뜻이다.
#
# ★ 이 스크립트가 **재부팅을 대신할 수는 없다.** 할 수 있는 것은 "재부팅하면
#   깨질 것이 지금 보이는가" 뿐이고, 그 한계를 끝에 스스로 출력한다.
#
# 쓰는 법
#   bash local/node-rejoin-check.sh            # 고칠 수 있는 것은 고치고 검증
#   bash local/node-rejoin-check.sh --check    # 검사만 (게이트용)
#
# ★ control-plane 에서 돌릴 것 — 다른 노드로는 root ssh 로 간다(Gotcha 175).
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/local/bootstrap-baremetal-k3s.sh"

MODE=apply
[ "${1:-}" = "--check" ] && MODE=check

log()  { echo "[rejoin] $*"; }
fail() { echo "[rejoin] FAIL: $*" >&2; exit 1; }

# ── sysctl 값의 원천은 부트스트랩이다 ──────────────────────────
# ★ 가드를 "비어 있지 않다" 로 두지 말 것 — 알려진 키가 실제로 들어 있는지로
#   판정한다(Gotcha 117·148). 파싱이 어긋나면 제어문자 하나로도 통과한다.
[ -r "$BOOTSTRAP" ] || fail "$BOOTSTRAP 를 읽지 못했다 — sysctl 값의 원천이다"
SYSCTL_LINES="$(grep -E '^fs\.inotify\.[a-z_]+ = [0-9]+$' "$BOOTSTRAP" | sort -u || true)"
SYSCTL_N="$(printf '%s\n' "$SYSCTL_LINES" | grep -c . || true)"
[ "${SYSCTL_N:-0}" = 2 ] \
  || fail "부트스트랩에서 fs.inotify 선언을 2줄 읽어야 하는데 ${SYSCTL_N}줄이다 — 형식이 바뀌었다"
WANT_INST="$(printf '%s\n' "$SYSCTL_LINES" | awk '/max_user_instances/{print $3}')"
case "$WANT_INST" in
  ''|*[!0-9]*) fail "max_user_instances 를 숫자로 읽지 못했다" ;;
esac
log "sysctl 원천: $BOOTSTRAP (instances=${WANT_INST})"
SYSCTL_B64="$(printf '%s\n' "$SYSCTL_LINES" | base64 -w0)"

SELF_IP="$(hostname -I | awk '{print $1}')"
NODE_LINES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
  2>/dev/null | grep -v '^[[:space:]]*$' || true)"
[ -n "$NODE_LINES" ] || fail "노드 목록을 읽지 못했다 — control-plane 에서 돌릴 것"

# ★ 자기 노드를 마지막에 — 이 스크립트는 k3s 를 재시작하지 않지만 규약을 지켜
#   둔다. 어기면 다음 사람이 재시작을 넣는 날 조용히 반쪽만 적용된다
#   (Gotcha 178 은 실제로 그렇게 104 를 건너뛰었다).
ORDERED=""
while read -r nm ip; do
  [ -n "$nm" ] || continue
  [ "$ip" = "$SELF_IP" ] || ORDERED="$ORDERED ${nm}=${ip}"
done <<< "$NODE_LINES"
while read -r nm ip; do
  [ -n "$nm" ] || continue
  [ "$ip" = "$SELF_IP" ] && ORDERED="$ORDERED ${nm}=${ip}"
done <<< "$NODE_LINES"

node_script() { cat <<'NODE'
set -Eeuo pipefail
MODE="${MODE:-check}"
WANT_IP="${WANT_IP:-}"
WANT_INST="${WANT_INST:-1024}"
SYSCTL_B64="${SYSCTL_B64:-}"
RC=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [실패] $*"; RC=1; }
note() { echo "  [경고] $*"; }

# ── 역할: 유닛 파일이 있는 쪽이 이 노드의 역할이다 ──────────────
# ★ systemctl is-enabled 로 가르지 말 것 — disabled 면 실패해서 server 노드를
#   agent 로 오판하고, 그러면 뒤의 검사가 전부 엉뚱해진다.
if   [ -f /etc/systemd/system/k3s.service ];       then UNIT=k3s
elif [ -f /etc/systemd/system/k3s-agent.service ]; then UNIT=k3s-agent
else
  echo "  [실패] k3s 유닛 파일이 없다 - 이 노드는 클러스터 멤버가 아니다"
  exit 1
fi
echo "  역할: $UNIT"

# ── 1. 유닛이 enabled 인가 ─────────────────────────────────────
# 이것이 깨지면 증상이 가장 단순하다: 부팅은 되는데 노드가 오지 않는다.
EN="$(systemctl is-enabled "$UNIT" 2>/dev/null || echo unknown)"
if [ "$EN" != enabled ]; then
  if [ "$MODE" = apply ]; then
    systemctl enable "$UNIT" >/dev/null 2>&1 || true
    EN="$(systemctl is-enabled "$UNIT" 2>/dev/null || echo unknown)"
    if [ "$EN" = enabled ]; then ok "$UNIT enabled 로 고쳤다"
    else bad "$UNIT 를 enable 하지 못했다 ($EN)"; fi
  else
    bad "$UNIT 가 $EN - 재부팅하면 올라오지 않는다"
  fi
else
  ok "$UNIT enabled"
fi
ACT="$(systemctl is-active "$UNIT" 2>/dev/null || echo inactive)"
if [ "$ACT" = active ]; then ok "$UNIT active"
else note "$UNIT 가 $ACT - 지금은 멤버가 아니다"; fi

# ── 2. 주소가 고정인가 ─────────────────────────────────────────
# ★★ 이것이 이 검사의 핵심이다. DHCP 주소는 재부팅에 바뀔 수 있고, 바뀌면
#   인증서와 kine masterleases 가 어긋나 **재시작으로도 풀리지 않는다**
#   (Gotcha 49·55). 고칠 수 있는 종류가 아니라 보고한다 - netplan 을 건드리는
#   것은 지금 붙어 있는 ssh 를 끊을 수 있다.
IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
if [ -z "$IFACE" ]; then
  bad "기본 경로 인터페이스가 없다"
else
  CUR_IP="$(ip -o -4 addr show dev "$IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
  if ip -o -4 addr show dev "$IFACE" | grep -qw dynamic; then
    bad "$IFACE 의 주소가 DHCP(dynamic)다 - 재부팅에 바뀌면 복귀하지 못한다(Gotcha 49·55). netplan 에 static 으로 박을 것"
  else
    ok "$IFACE $CUR_IP static"
  fi
  if [ -n "$WANT_IP" ] && [ "$CUR_IP" != "$WANT_IP" ]; then
    bad "실제 주소 $CUR_IP 가 클러스터가 아는 $WANT_IP 와 다르다"
  fi
  # ★★ k3s 설치기는 인자를 **한 줄에 하나씩 따옴표로** 쓴다:
  #       '--node-ip' \
  #       '192.168.0.103' \
  #   그래서 한 줄을 전제한 정규식은 **있는 것을 없다고 답한다** — 첫 판이
  #   그렇게 103 을 경고로 보고했고, 실측으로 뒤집혔다. 거짓 발견이 상수가
  #   되면 사람이 배경으로 읽으므로(Gotcha 73·90) ExecStart 를 한 줄로 펴서
  #   토큰으로 찾는다.
  # ★★★ 백슬래시·따옴표를 **지우려 하지 않는다.** 첫 판은 tr 로 지우려 했고
  #   그 과정에서 줄 연속 토큰이 값 자리에 들어와 IP 대신 쓰레기를 돌려줬다
  #   (합성 대조군이 잡았다). 한 줄로 펴 놓으면 구분자가 무엇이든 숫자가
  #   아니므로, 그냥 "--node-ip 뒤에 처음 나오는 IPv4" 를 집는다.
  ARGS="$(sed -n '/^ExecStart=/,$p' "/etc/systemd/system/${UNIT}.service" 2>/dev/null \
          | tr '\n' ' ' || true)"
  U_IP="$(printf '%s\n' "$ARGS" \
          | grep -oE '[-][-]node-ip[^0-9]{0,8}[0-9]+(\.[0-9]+){3}' \
          | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1 || true)"
  if [ -n "$U_IP" ]; then
    if [ "$U_IP" = "$CUR_IP" ]; then ok "유닛 node-ip $U_IP 일치"
    else bad "유닛의 node-ip $U_IP 가 실제 $CUR_IP 와 다르다 - 기동해도 엉뚱한 주소로 등록한다"; fi
  else
    note "유닛에 node-ip 가 없다 - 어댑터가 둘 이상이면 아무 것이나 고른다(Gotcha 49)"
  fi
fi

# ── 3. 유닛이 참조하는 파일이 실제로 있는가 ────────────────────
# ★ 없으면 k3s 는 기동을 **거부한다** - 재부팅 뒤 노드가 오지 않는 흔한 이유다.
MISS=0
REFS="$(grep -ohE '/etc/rancher/k3s/[A-Za-z0-9._/-]+' "/etc/systemd/system/${UNIT}.service" 2>/dev/null | sort -u || true)"
for f in $REFS; do
  if [ ! -e "$f" ]; then bad "유닛이 참조하는 $f 가 없다"; MISS=$((MISS + 1)); fi
done
if [ "$MISS" = 0 ]; then ok "유닛이 참조하는 /etc/rancher/k3s/* 전부 존재"; fi

# ── 4. agent 의 조인 자격 ──────────────────────────────────────
# ★ 값은 출력하지 않는다. 이 레포 규약이다 - 길이만 본다.
if [ "$UNIT" = k3s-agent ]; then
  EF=/etc/systemd/system/k3s-agent.service.env
  if [ ! -f "$EF" ]; then
    bad "$EF 가 없다 - 서버 주소·토큰 없이는 조인하지 못한다"
  else
    for k in K3S_URL K3S_TOKEN; do
      V="$(grep -m1 "^${k}=" "$EF" 2>/dev/null | cut -d= -f2- || true)"
      if [ -n "$V" ]; then ok "$k 있음 (${#V}자, 값은 출력하지 않는다)"
      else bad "$EF 에 $k 가 없다"; fi
    done
  fi
  # ★★ k3s 의 노드 비밀번호. 이것이 사라지면 에이전트가 새 값을 만들고 서버가
  #   거부한다 - Node password rejected 다. 부팅은 되고 **조인만** 안 되므로
  #   "네트워크 문제" 로 읽기 쉽다.
  if [ -s /etc/rancher/node/password ]; then
    ok "/etc/rancher/node/password 있음 ($(wc -c < /etc/rancher/node/password)바이트)"
  else
    bad "/etc/rancher/node/password 가 없다 - 서버가 Node password rejected 로 거부한다"
  fi
fi

# ── 5. sysctl 이 **선언**되어 있는가 ───────────────────────────
# ★★ 런타임 값만 맞는 것으로는 부족하다 - 재부팅하면 사라진다. 그러면 Falco 가
#   inotify handler 를 얻지 못해 CrashLoop 하고 **wave 7 에서 동기화가 선다**
#   (Gotcha 183). 값과 선언을 **따로** 본다.
SYSF=/etc/sysctl.d/99-oim-k8s.conf
CUR_INST="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
if [ ! -f "$SYSF" ]; then
  if [ "$MODE" = apply ]; then
    if [ -z "$SYSCTL_B64" ]; then
      bad "$SYSF 가 없는데 넘겨받은 sysctl 선언도 없다"
    else
      {
        echo "# OneinchMarket k3s node - limits for 100+ pods.  ASCII only."
        echo "# Source of these values: local/bootstrap-baremetal-k3s.sh"
        echo "# At the default (instances 128) Falco cannot get an inotify handler"
        echo "# and its DaemonSet never becomes healthy, stalling the sync at wave 7."
        printf '%s' "$SYSCTL_B64" | base64 -d
      } > "$SYSF"
      chmod 0644 "$SYSF"
      NA="$(LC_ALL=C grep -c '[^[:print:][:space:]]' "$SYSF" || true)"
      if [ "${NA:-0}" != 0 ]; then bad "$SYSF 에 비-ASCII 가 ${NA}줄 (Gotcha 177)"; fi
      sysctl -q --system || true
      CUR_INST="$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)"
      if [ "${CUR_INST:-0}" -ge "$WANT_INST" ]; then ok "$SYSF 를 만들었다 (instances=$CUR_INST)"
      else bad "$SYSF 를 썼는데 값이 $CUR_INST 다 - 반영되지 않았다"; fi
    fi
  else
    bad "$SYSF 가 없다 - 지금 값이 $CUR_INST 여도 재부팅하면 기본값으로 돌아간다"
  fi
else
  if [ "${CUR_INST:-0}" -ge "$WANT_INST" ]; then ok "inotify 선언·값 둘 다 OK ($CUR_INST)"
  else bad "$SYSF 는 있는데 값이 $CUR_INST 다 - sysctl --system 이 돌지 않았다"; fi
fi

# ── 6. 시계 ────────────────────────────────────────────────────
# ★ 크게 어긋나면 TLS 가 실패해 조인하지 못한다. 증상이 "토큰이 틀렸다" 로 보인다.
TS="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
if [ "$TS" = yes ]; then ok "시계 NTP 동기"
else note "시계가 NTP 동기되지 않았다 ($TS) - 크게 어긋나면 TLS 가 실패한다"; fi

# ── 7. 레포 밖 노드 상태들 ─────────────────────────────────────
# 복귀 자체를 막지는 않지만, 복귀한 뒤 조용히 반쪽이 되는 것들이다.
if [ -f /etc/rancher/k3s/registries.yaml ]; then ok "registries.yaml 있음"
else note "registries.yaml 이 없다 - 클러스터 안 레지스트리 pull 이 HTTPS 로 가서 실패한다(Gotcha 126). local/configure-node-registry.sh"; fi
TEN="$(systemctl is-enabled oim-thermal-policy 2>/dev/null || echo 없음)"
if [ "$TEN" = enabled ]; then ok "oim-thermal-policy enabled"
else note "oim-thermal-policy 가 $TEN - 재부팅 뒤 팬이 1300-2400 을 다시 왕복한다(Gotcha 192)"; fi

exit "$RC"
NODE
}

PASS=0
FAILED=0
UNKNOWN=0
SUMMARY=""
for ent in $ORDERED; do
  nm="${ent%%=*}"
  ip="${ent##*=}"
  echo "=== $nm ($ip) ==="
  rc=0
  if [ "$ip" = "$SELF_IP" ]; then
    node_script | env MODE="$MODE" WANT_IP="$ip" WANT_INST="$WANT_INST" \
                      SYSCTL_B64="$SYSCTL_B64" bash || rc=$?
  else
    # ★ 닿지 못하는 것과 검사에 실패하는 것을 **가른다**. ssh 자체가 안 되면
    #   측정 불가(2)이고, 그것을 통과로 접지 않는다(Gotcha 191).
    if ! ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
           "root@${ip}" true >/dev/null 2>&1; then
      echo "  [측정 불가] ssh 로 닿지 못한다 - 꺼져 있거나 부팅이 네트워크까지 오지 못했다"
      UNKNOWN=$((UNKNOWN + 1))
      SUMMARY="${SUMMARY}\n  ${nm}\t${ip}\t측정 불가"
      continue
    fi
    node_script | ssh -o BatchMode=yes -o ConnectTimeout=8 "root@${ip}" \
      "MODE=${MODE} WANT_IP=${ip} WANT_INST=${WANT_INST} SYSCTL_B64=${SYSCTL_B64} bash -s" || rc=$?
  fi
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1))
    SUMMARY="${SUMMARY}\n  ${nm}\t${ip}\t통과"
  else
    FAILED=$((FAILED + 1))
    SUMMARY="${SUMMARY}\n  ${nm}\t${ip}\t실패(rc=$rc)"
  fi
done

echo
echo "============================================"
echo "  재부팅 복귀 판정"
echo "============================================"
printf '%b\n' "$SUMMARY" | sed '/^[[:space:]]*$/d'
echo "--------------------------------------------"
printf "  통과 %d · 실패 %d · 측정 불가 %d\n" "$PASS" "$FAILED" "$UNKNOWN"
echo "============================================"
# ★ 스스로 한계를 말한다 — 이 스크립트는 재부팅을 대신하지 못한다.
echo "  ★ 이것이 재는 것: 재부팅하면 깨질 것이 지금 보이는가."
echo "    재지 못하는 것: 실제 부팅 경로(펌웨어·디스크·NIC). 노드가 네트워크에"
echo "    오지 못하는 원인은 여기서 보이지 않는다 - 모니터를 붙여야 한다."
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
if [ "$UNKNOWN" -gt 0 ]; then
  echo "  ★ 측정 불가가 있다 - 통과로 접지 않는다(Gotcha 191). 종료 코드 2."
  exit 2
fi
exit 0
