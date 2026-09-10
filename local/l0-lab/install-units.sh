#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# L0 랩 systemd 유닛 설치 — WSL 재부팅에서 랩을 되살린다
#
# ★★ 왜 필요한가 — 랩의 런타임 상태가 **전부 휘발성**이다:
#     브리지(l0-lan·l0-wan) · netns l0target · nft l0lab · iptables FORWARD ·
#     dnsmasq · qemu(OPNsense) — 하나도 재부팅을 넘기지 못한다.
#   그런데 **Zeek 파드는 살아남는다.** 그러면 파드는 `1/1 Running` 인데 볼
#   트래픽이 없는 상태가 되고, 아무 오류도 나지 않는다 — 이 레포가 반복해서
#   경계하는 형태다(Gotcha 33·84·95). 그래서 자동화한다.
#
# ★ 기준: **조용히 실패하는 것은 자동화하고, 시끄럽게 실패하는 것은 문서로 둔다.**
#   `/etc/hosts` 의 레지스트리 항목도 부팅마다 사라지지만 그쪽은
#   `Could not resolve host` 로 즉시 드러나므로 §3-1 ⑤ 로 남긴다.
#
# ★ WSL 은 유휴 시 배포판을 종료하므로(Gotcha 6) 재부팅이 잦다. 이 유닛이
#   없으면 그때마다 사람이 두 명령을 기억해야 한다.
#
# 사용:  sudo ./install-units.sh          # 설치 + enable + 지금 시작
#        sudo ./install-units.sh --remove # 되돌리기
# ─────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_UNIT=/etc/systemd/system/l0-lab-net.service
VM_UNIT=/etc/systemd/system/l0-opnsense.service

log() { echo "  $*"; }
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now l0-opnsense.service 2>/dev/null || true
  systemctl disable --now l0-lab-net.service 2>/dev/null || true
  for u in "$VM_UNIT" "$NET_UNIT"; do [ -e "$u" ] && unlink "$u" && log "$(basename "$u") 제거"; done
  systemctl daemon-reload
  log "되돌리기 완료"
  exit 0
fi

cat > "$NET_UNIT" <<UNIT
[Unit]
Description=L0 lab network (bridges + target netns) — LOCAL-DEPLOYMENT §24-4
Documentation=file://$HERE/kvm-net.sh
After=network-online.target
Wants=network-online.target
# ★★ 스크립트가 /mnt/c(9p drvfs)에 있다. 실측: 그것은 systemd 마운트 유닛
#   (mnt-c.mount)이지만 **local-fs.target 에는 포함되지 않는다** — 그래서
#   After=local-fs.target 만으로는 부팅 시 마운트를 보장하지 못한다.
#   RequiresMountsFor 가 경로에서 필요한 마운트 유닛을 스스로 찾아 건다.
RequiresMountsFor=$HERE
ConditionPathExists=$HERE/kvm-net.sh

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash $HERE/kvm-net.sh up
# ★ cutover 는 l0-lan 에 호스트 IP 를 붙인다. Hyper-V 랩이 내려간 뒤에만
#   안전한데, 이제 그쪽은 영구히 내려갔으므로 기동에 포함한다(§24-6).
ExecStartPost=/usr/bin/env bash $HERE/kvm-net.sh cutover
ExecStop=/usr/bin/env bash $HERE/kvm-net.sh down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT
log "$(basename "$NET_UNIT") 작성"

cat > "$VM_UNIT" <<UNIT
[Unit]
Description=L0 lab OPNsense (KVM) — LOCAL-DEPLOYMENT §24-6
Documentation=file://$HERE/run-opnsense.sh
# ★ 브리지가 먼저 서야 tap 을 붙일 수 있다.
Requires=l0-lab-net.service
After=l0-lab-net.service
# 스크립트(/mnt/c)와 디스크(/var/lib/l0) 양쪽이 마운트돼 있어야 한다.
RequiresMountsFor=$HERE /var/lib/l0
ConditionPathExists=$HERE/run-opnsense.sh
ConditionPathExists=/var/lib/l0/opnsense.qcow2

[Service]
Type=forking
PIDFile=/run/l0-opnsense/qemu.pid
ExecStart=/usr/bin/env bash $HERE/run-opnsense.sh start
ExecStop=/usr/bin/env bash $HERE/run-opnsense.sh stop
Restart=on-failure
RestartSec=15
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
log "$(basename "$VM_UNIT") 작성"

systemctl daemon-reload
systemctl enable l0-lab-net.service l0-opnsense.service >/dev/null 2>&1
log "enable 완료 — 다음 부팅부터 자동 기동"

# 이미 손으로 띄워 둔 상태일 수 있다. 그러면 유닛이 그것을 인수하게 한다.
if [ -f /run/l0-opnsense/qemu.pid ] && kill -0 "$(cat /run/l0-opnsense/qemu.pid)" 2>/dev/null; then
  log "★ OPNsense 가 이미 돌고 있다 — 유닛이 인수하도록 재시작한다"
  systemctl stop l0-opnsense.service 2>/dev/null || true
  bash "$HERE/run-opnsense.sh" stop >/dev/null 2>&1 || true
fi
systemctl restart l0-lab-net.service
systemctl start l0-opnsense.service
log "지금 상태:"
systemctl is-active l0-lab-net.service l0-opnsense.service | sed 's/^/    /'
