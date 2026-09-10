#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# run-opnsense.sh — OPNsense 를 WSL 안 KVM 으로 띄운다 (Hyper-V 대체)
#
# 왜 옮기는지는 LOCAL-DEPLOYMENT §24. 요지: Hyper-V 는 **선할당**이라 게스트가
# 3.25 GiB 만 만져도 할당한 6 GiB 를 전부 잡는다(§24-3 실측). KVM 은 만진
# 만큼만 쓰고 그 아래를 zram 이 받친다.
#
# ★★ 인터페이스 이름이 바뀐다 — 이 전환의 유일한 수작업이다.
#     Hyper-V: hn0(LAN) · hn1(WAN)      <- netvsc
#     KVM:     vtnet0    · vtnet1       <- virtio
#   config.xml 이 <if>hn0</if> 로 박혀 있어 첫 부팅에서 콘솔 할당 메뉴로
#   떨어진다. `console` 로 붙어 1번(Assign interfaces)을 밟을 것.
#   ★ 아래 -device 순서가 곧 vtnet 번호다. LAN 을 먼저 둔다.
#
# ★ MAC 은 Hyper-V 것을 그대로 쓴다. 바꾸면 DHCP 임대와 MAC 참조 규칙이 어긋난다.
#
# ★ WAN 주소가 바뀐다 — Hyper-V 에서는 물리 공유기가 192.168.1.23 을 줬는데
#   이제 l0-wan 의 dnsmasq 가 10.78.0.x 를 준다. DHCP 라 자동으로 잡는다.
#
# ★★ 이 VM 을 내릴 때 DNS 를 확인할 것 — Windows 의 `vEthernet (L0-LAN)` 가
#   DHCP 로 이 게스트(10.77.0.1)를 DNS 서버로 받아 두고 있었고, 그래서 이 VM 을
#   끄자 WSL 프록시와 CoreDNS 가 함께 죽었다(§24-8). 지금은 노드 DNS 를 랩과
#   무관한 값으로 고정해 두었다.
#
# 사용:  sudo ./run-opnsense.sh start | stop | console | status
#        (kvm-net.sh up 이 먼저 돌아 있어야 한다)
# ─────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

DISK="${DISK:-/var/lib/l0/opnsense.qcow2}"
MEM_MB="${MEM_MB:-4096}"
CPUS="${CPUS:-2}"
LAN_BR="${LAN_BR:-l0-lan}"
WAN_BR="${WAN_BR:-l0-wan}"
LAN_TAP=opn-lan
WAN_TAP=opn-wan
LAN_MAC="${LAN_MAC:-00:15:5d:f7:09:02}"
WAN_MAC="${WAN_MAC:-00:15:5d:f7:09:03}"
SERIAL_PORT="${SERIAL_PORT:-4555}"
RUN=/run/l0-opnsense
PIDF="$RUN/qemu.pid"

log() { echo "  $*"; }
die() { echo "  ※ $*" >&2; exit 1; }

running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

tap_up() {
  local tap=$1 br=$2
  ip link show "$tap" >/dev/null 2>&1 || ip tuntap add dev "$tap" mode tap
  ip link set "$tap" master "$br"
  ip link set "$tap" up
}

start() {
  [ -c /dev/kvm ] || die "/dev/kvm 이 없다"
  [ -f "$DISK" ]  || die "디스크가 없다: $DISK"
  ip link show "$LAN_BR" >/dev/null 2>&1 || die "$LAN_BR 이 없다 — kvm-net.sh up 을 먼저 돌릴 것"
  ip link show "$WAN_BR" >/dev/null 2>&1 || die "$WAN_BR 이 없다 — kvm-net.sh up 을 먼저 돌릴 것"
  running && die "이미 돌고 있다(pid $(cat "$PIDF"))"

  mkdir -p "$RUN"
  tap_up "$LAN_TAP" "$LAN_BR"
  tap_up "$WAN_TAP" "$WAN_BR"
  log "tap: $LAN_TAP@$LAN_BR · $WAN_TAP@$WAN_BR"

  qemu-system-x86_64 \
    -name l0-opnsense -machine q35,accel=kvm -cpu host \
    -m "$MEM_MB" -smp "$CPUS" \
    -drive if=virtio,format=qcow2,file="$DISK" \
    -device virtio-net-pci,netdev=lan,mac="$LAN_MAC" \
    -netdev "tap,id=lan,ifname=$LAN_TAP,script=no,downscript=no,vhost=on" \
    -device virtio-net-pci,netdev=wan,mac="$WAN_MAC" \
    -netdev "tap,id=wan,ifname=$WAN_TAP,script=no,downscript=no,vhost=on" \
    -display none \
    -serial "telnet:127.0.0.1:${SERIAL_PORT},server,nowait" \
    -pidfile "$PIDF" -daemonize
  log "기동 (mem ${MEM_MB}MiB · vcpu ${CPUS} · 시리얼 127.0.0.1:${SERIAL_PORT})"
  log "콘솔: sudo $0 console   (빠져나오기: Ctrl-])"
}

stop() {
  if running; then
    local pid; pid=$(cat "$PIDF")
    kill "$pid"
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
    log "종료(pid $pid)"
  else
    log "꺼져 있음"
  fi
  [ -e "$PIDF" ] && unlink "$PIDF"
  for t in "$LAN_TAP" "$WAN_TAP"; do
    ip link show "$t" >/dev/null 2>&1 && { ip link del "$t"; log "$t 삭제"; }
  done
  log "★ DNS 확인 — 이 게스트가 노드 DNS 경로에 있으면 함께 죽는다(머리말)"
}

console() {
  command -v socat >/dev/null 2>&1 \
    && exec socat -,raw,echo=0,escape=0x1d "tcp:127.0.0.1:${SERIAL_PORT}" \
    || exec nc 127.0.0.1 "${SERIAL_PORT}"
}

status() {
  if running; then
    local pid; pid=$(cat "$PIDF")
    echo "  실행 중 pid=$pid  RSS=$(awk '/VmRSS/{printf "%.2f GiB", $2/1048576}' "/proc/$pid/status" 2>/dev/null)"
  else
    echo "  꺼져 있음"
  fi
  for t in "$LAN_TAP" "$WAN_TAP"; do
    printf "  %-8s %s\n" "$t" "$(ip -br link show "$t" 2>/dev/null || echo 없음)"
  done
}

[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"
case "${1:-status}" in
  start) start ;; stop) stop ;; console) console ;; status) status ;;
  *) echo "사용: $0 start|stop|console|status"; exit 2 ;;
esac
