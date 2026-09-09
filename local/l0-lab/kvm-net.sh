#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# L0 랩 KVM 네트워크 — 브리지 2개 + 표적 netns
#
# Hyper-V vSwitch 를 대체한다. 왜 옮기는지는 LOCAL-DEPLOYMENT §23 을 볼 것.
# 요지: 랩 메모리를 Windows(여유 없음)가 아니라 WSL(zram 있음)에서 꺼내고,
#       Hyper-V 정적 할당(선할당)을 KVM demand paging 으로 바꾼다.
#
# ★ 토폴로지 — Hyper-V 판과 같은 의미를 유지한다
#     l0-lan : 업링크 없음 = Hyper-V 의 Internal 스위치와 같다.
#              여기 붙은 것은 OPNsense 를 통하지 않으면 밖으로 못 나간다.
#     l0-wan : WSL eth0 로 masquerade. OPNsense 의 WAN 이 붙는다.
#     netns l0target : 표적. Hyper-V 판의 L0-Target VM 을 대체한다.
#
# ★★ 표적을 **파드로 만들지 않는 이유** — 파드의 egress 는 Cilium 을 타고
#   WSL eth0 로 나가 **OPNsense 를 우회한다.** 격리를 검증하려고 만든 랩에서
#   격리가 사라진다. 손으로 만든 netns 는 veth 하나 말고 경로가 물리적으로
#   없어서 VM 과 같은 격리를 0 비용으로 얻는다.
#
# ★ IP 10.77.0.191 을 바꾸지 말 것 — suricata/l0lab-inline-test.rules 의
#   `drop icmp 10.77.0.191 any -> any any` 가 이 주소를 지목한다.
#
# ★★ l0-lan 에 **호스트 IP 를 주지 않는다**(전환 전까지). 지금 WSL 은
#   Hyper-V 쪽 OPNsense(10.77.0.1)를 기본 경로(Windows)로 가고 있어서,
#   같은 대역의 로컬 경로가 생기면 그 접근이 끊긴다. netns 는 자기
#   네임스페이스 안에서 라우팅하므로 호스트 IP 없이도 동작한다.
#   Hyper-V 랩을 내린 뒤 `cutover` 로 10.77.0.190/24 를 붙인다.
#
# ★ WSL 은 재부팅하면 이 설정을 전부 잃는다 — 콜드 부팅 뒤 다시 돌릴 것
#   (LOCAL-DEPLOYMENT §3-1).
#
# 사용:  ./kvm-net.sh up | down | status | cutover
# ─────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

LAN_BR=l0-lan
WAN_BR=l0-wan
WAN_HOST=10.78.0.1/24
WAN_NET=10.78.0.0/24
WAN_DHCP_FROM=10.78.0.100
WAN_DHCP_TO=10.78.0.199
LAN_HOST=10.77.0.190/24      # cutover 에서만 붙인다
LAN_GW=10.77.0.1             # OPNsense
NS=l0target
TGT_IP=10.77.0.191/24
UPLINK="${UPLINK:-eth0}"
NFT_TABLE=l0lab

log() { echo "  $*"; }
need_root() { [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"; }

br_add() {
  local br=$1
  if ip link show "$br" >/dev/null 2>&1; then log "$br 이미 있음"; else
    ip link add name "$br" type bridge
    log "$br 생성"
  fi
  ip link set "$br" up
}

up() {
  # ★★ br_netfilter 를 **일부러 올리지 않는다.** 실측(2026-09-10)으로 이 노드에는
  #   로드되어 있지 않고, 그 상태에서는 브리지 프레임이 iptables 를 아예 거치지
  #   않는다 — 그게 우리가 원하는 것이다. 올리는 순간 Cilium 의 iptables
  #   masquerade(`Masquerading: IPTables`)와 kube-proxy 규칙이 랩 트래픽에
  #   끼어든다. "안 켜는 것" 이 처방이지 "켜고 sysctl 로 끄는 것" 이 아니다.
  br_add "$LAN_BR"
  br_add "$WAN_BR"

  # WAN 쪽만 주소·NAT 를 갖는다.
  have=$(ip -4 -o addr show dev "$WAN_BR"); case "$have" in *"${WAN_HOST%/*}"*) :;; *) ip addr add "$WAN_HOST" dev "$WAN_BR";; esac
  log "$WAN_BR $WAN_HOST"

  sysctl -qw net.ipv4.ip_forward=1

  # 우리 테이블만 쓴다 — k3s/Cilium 규칙과 섞이지 않게.
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && nft delete table ip "$NFT_TABLE"
  nft -f - <<NFT
table ip $NFT_TABLE {
  chain post {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $WAN_NET oifname "$UPLINK" masquerade
  }
}
NFT
  log "masquerade $WAN_NET -> $UPLINK"

  # ★★ 이 노드의 iptables FORWARD 정책은 **DROP** 이다(Cilium/kube-proxy).
  #   nft 로 우리 테이블에 accept 를 넣어도 소용없다 — 같은 훅의 다른 체인이
  #   drop 하면 그것이 최종이다. 그러니 그 체인에 직접 넣어야 한다.
  #   주석을 달아 두어야 나중에 골라 지울 수 있다.
  fwd_rule() {
    iptables -C FORWARD "$@" -m comment --comment "$NFT_TABLE" 2>/dev/null       || iptables -I FORWARD "$@" -m comment --comment "$NFT_TABLE"
  }
  fwd_rule -i "$WAN_BR" -o "$UPLINK" -j ACCEPT
  fwd_rule -i "$UPLINK" -o "$WAN_BR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log "FORWARD 허용 ($WAN_BR <-> $UPLINK)"

  # OPNsense 의 WAN 은 DHCP 다. DNS 는 끈다(port=0) — CoreDNS 와 다투지 않게.
  if ! pgrep -f "dnsmasq.*$WAN_BR" >/dev/null 2>&1; then
    dnsmasq --port=0 --interface="$WAN_BR" --bind-interfaces \
            --dhcp-range="$WAN_DHCP_FROM,$WAN_DHCP_TO,12h" \
            --dhcp-option=3,"${WAN_HOST%/*}" \
            --dhcp-option=6,1.1.1.1,8.8.8.8 \
            --pid-file=/run/l0-wan-dnsmasq.pid
    log "dnsmasq DHCP $WAN_DHCP_FROM-$WAN_DHCP_TO (DNS 꺼짐)"
  else
    log "dnsmasq 이미 실행 중"
  fi

  ns_up
  log "완료 — l0-lan 은 업링크 없음(격리), l0-wan 은 NAT"
}

ns_up() {
  # ★★ `ip netns list | grep -q` 를 쓰지 말 것 — set -o pipefail 과 만나면
  #   grep 이 첫 매치에서 끝나며 ip 가 SIGPIPE 로 죽어 **있는데 없다고 나온다.**
  #   이 노드는 netns 가 128개(파드마다 하나)라 반드시 재현된다. 파일로 본다.
  [ -e "/var/run/netns/$NS" ] || { ip netns add "$NS"; log "netns $NS 생성"; }
  if ! ip -n "$NS" link show veth-t >/dev/null 2>&1; then
    ip link add veth-t type veth peer name veth-br
    ip link set veth-t netns "$NS"
    ip link set veth-br master "$LAN_BR"
    ip link set veth-br up
    log "veth 연결 ($NS <-> $LAN_BR)"
  fi
  ip -n "$NS" link set lo up
  ip -n "$NS" link set veth-t up
  have=$(ip -n "$NS" -4 -o addr show dev veth-t); case "$have" in *"${TGT_IP%/*}"*) :;; *) ip -n "$NS" addr add "$TGT_IP" dev veth-t;; esac
  # ★ 기본 경로는 OPNsense 뿐이다. 다른 경로가 없다는 것이 격리의 근거다.
  ip -n "$NS" route replace default via "$LAN_GW" dev veth-t
  log "netns $NS: $TGT_IP · default via $LAN_GW"
}

cutover() {
  log "★ Hyper-V 랩이 내려간 뒤에만 실행할 것 (그 전에는 WSL->10.77.0.1 이 끊긴다)"
  have=$(ip -4 -o addr show dev "$LAN_BR"); case "$have" in *"${LAN_HOST%/*}"*) :;; *) ip addr add "$LAN_HOST" dev "$LAN_BR";; esac
  log "$LAN_BR $LAN_HOST — 이제 WSL 에서 OPNsense 관리 접근이 브리지로 간다"
}

down() {
  pkill -F /run/l0-wan-dnsmasq.pid 2>/dev/null || true
  # 주석으로 표시해 둔 우리 규칙만 골라 지운다.
  # ★ 목록을 파싱해 번호로 지우지 않는다 — `iptables -S | grep | head` 는
  #   pipefail 과 만나 조용히 빗나갈 수 있고(위 netns 와 같은 부류), 번호는
  #   다른 규칙이 끼어들면 어긋난다. 넣을 때 쓴 명세를 그대로 지운다.
  iptables -D FORWARD -i "$WAN_BR" -o "$UPLINK" -j ACCEPT -m comment --comment "$NFT_TABLE" 2>/dev/null || true
  iptables -D FORWARD -i "$UPLINK" -o "$WAN_BR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "$NFT_TABLE" 2>/dev/null || true
  log "FORWARD 규칙 제거"
  [ -e "/var/run/netns/$NS" ] && { ip netns del "$NS"; log "netns $NS 삭제"; }
  ip link show veth-br >/dev/null 2>&1 && ip link del veth-br
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && nft delete table ip "$NFT_TABLE"
  for br in "$LAN_BR" "$WAN_BR"; do
    ip link show "$br" >/dev/null 2>&1 && { ip link del "$br"; log "$br 삭제"; }
  done
  log "정리 완료"
}

status() {
  echo "── 브리지 ──"
  for br in "$LAN_BR" "$WAN_BR"; do
    if ip link show "$br" >/dev/null 2>&1; then
      printf "  %-8s %s  포트: %s\n" "$br" \
        "$(ip -4 -br addr show dev "$br" | awk '{print $2, $3}')" \
        "$(ls /sys/class/net/"$br"/brif 2>/dev/null | tr '\n' ' ')"
    else printf "  %-8s 없음\n" "$br"; fi
  done
  echo "── netns ──"
  if [ -e "/var/run/netns/$NS" ]; then
    ip -n "$NS" -4 -br addr show | sed 's/^/  /'
    echo "  기본 경로: $(ip -n "$NS" route show default || echo 없음)"
  else echo "  $NS 없음"; fi
  echo "── NAT ──"
  nft list table ip "$NFT_TABLE" 2>/dev/null | sed 's/^/  /' || echo "  테이블 없음"
}

need_root "$@"
case "${1:-status}" in
  up) up ;; down) down ;; cutover) cutover ;; status) status ;;
  *) echo "사용: $0 up|down|status|cutover"; exit 2 ;;
esac
