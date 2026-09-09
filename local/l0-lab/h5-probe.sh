#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# h5-probe — verify-h5.sh 를 돌리기 위한 **일회성** KVM 게스트
#
# ★★ 이 VM 은 상시로 두지 않는다. 검증 하나를 위해 뜨고, 답을 남기고, 즉시
#   파기된다. Hyper-V 판의 L0-Target 은 이 검증 때문에 4 GB 를 **상시** 물고
#   있었는데(README 가 "2GB 로는 빠듯하다" 며 올려 뒀다), H5 는 본래
#   일회성이라 그럴 이유가 없다. 상시 점유 0 이 이 스크립트의 존재 이유다.
#
# ★ 네트워크는 QEMU user-mode(SLIRP)다. 브리지도 tap 도 DHCP 조회도 쓰지 않아
#   kvm-net.sh 와 독립적이다. 게스트에 필요한 것은 k3s·Cilium 을 내려받을
#   바깥 경로뿐이고, H5 가 보는 것(BTF·socketLB·NetworkPolicy)은 전부 게스트
#   내부라 바깥 네트워크 종류와 무관하다. NIC 은 virtio-net 이므로 게스트가
#   보는 드라이버는 virtio_net 이다 — 그것이 이 실행이 답하는 대상이다.
#
# ★ 무엇을 답하고 무엇을 답하지 않는가 — verify-h5.sh 머리말을 볼 것.
#   요약: virtio_net 기준이라 ADR-051 A안(Hyper-V 다중 노드)을 보증하지
#   않는다. 답하는 것은 "베어메탈 리눅스 + KVM 에서 k3s+Cilium 의 eBPF
#   데이터패스가 서는가"(LOCAL-DEPLOYMENT §22)다.
#
# ★ 파기 범위 — 이 스크립트가 만든 것만 지운다:
#     overlay.qcow2 · seed.iso · seed/ · qemu.pid · 임시 SSH 키
#   베이스 클라우드 이미지는 읽기 전용 백킹이라 손대지 않고,
#   결과(h5-result.txt)와 콘솔 로그는 일부러 남긴다.
#
# 사용:  sudo ./h5-probe.sh run      # 띄우고 -> 검증 -> 파기 (기본)
#        sudo ./h5-probe.sh clean    # 남은 것 강제 정리
# ─────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${BASE:-/mnt/c/Users/darka/iso/ubuntu-24.04-server-cloudimg-amd64.img}"
URL="${URL:-https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img}"
WORK="${WORK:-/var/tmp/h5-probe}"
MEM_MB="${MEM_MB:-2560}"     # k3s + Cilium 이 들어갈 만큼. 상시가 아니라 잠깐이다.
CPUS="${CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"
DISK_GB="${DISK_GB:-20}"
BOOT_WAIT="${BOOT_WAIT:-300}"
RESULT="${RESULT:-$WORK/h5-result.txt}"

log()  { echo "  $*"; }
die()  { echo "  ※ $*" >&2; exit 1; }

destroy() {
  local rc=$?
  echo "── 파기 ──"
  if [ -f "$WORK/qemu.pid" ]; then
    local pid; pid=$(cat "$WORK/qemu.pid" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
      kill -9 "$pid" 2>/dev/null || true
      log "게스트 종료(pid $pid)"
    fi
  fi
  # 이 스크립트가 만든 것만 골라 없앤다(베이스 이미지·결과·콘솔 로그는 남는다).
  for f in overlay.qcow2 seed.iso qemu.pid id_ed25519 id_ed25519.pub; do
    [ -e "$WORK/$f" ] && unlink "$WORK/$f"
  done
  if [ -d "$WORK/seed" ]; then
    find "$WORK/seed" -mindepth 1 -delete
    rmdir "$WORK/seed"
  fi
  log "오버레이·시드·키 삭제 (결과와 콘솔 로그는 남긴다)"
  [ -f "$RESULT" ] && log "결과: $RESULT"
  [ -f "$WORK/console.log" ] && log "콘솔: $WORK/console.log"
  return $rc
}

prep() {
  mkdir -p "$WORK/seed"
  [ -f "$BASE" ] || { log "베이스 이미지 내려받는다"; curl -fSL -o "$BASE" "$URL"; }
  qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$WORK/overlay.qcow2" "${DISK_GB}G" >/dev/null
  log "오버레이 생성 (베이스는 읽기만 한다)"

  ssh-keygen -t ed25519 -N '' -f "$WORK/id_ed25519" -q -C h5-probe
  local pub; pub=$(cat "$WORK/id_ed25519.pub")

  {
    echo "#cloud-config"
    echo "ssh_pwauth: false"
    echo "users:"
    echo "  - name: probe"
    echo "    sudo: ['ALL=(ALL) NOPASSWD:ALL']"
    echo "    shell: /bin/bash"
    echo "    ssh_authorized_keys: ['$pub']"
    echo "write_files:"
    echo "  - path: /usr/local/bin/verify-h5.sh"
    echo "    permissions: '0755'"
    echo "    encoding: b64"
    echo "    content: |"
    base64 -w 76 "$HERE/verify-h5.sh" | sed 's/^/      /'
  } > "$WORK/seed/user-data"
  # ★ instance-id 는 user-data 의 해시다 — 고정하면 시드를 고쳐도 cloud-init 이
  #   per-instance 모듈을 다시 돌지 않아 조용히 무시된다(prepare-target-vm.sh 와 같은 이유).
  printf 'instance-id: h5-probe-%s\nlocal-hostname: h5-probe\n' \
    "$(sha256sum "$WORK/seed/user-data" | cut -c1-12)" > "$WORK/seed/meta-data"
  genisoimage -output "$WORK/seed.iso" -volid cidata -joliet -rock \
    "$WORK/seed/user-data" "$WORK/seed/meta-data" >/dev/null 2>&1
  log "cloud-init 시드 생성 (verify-h5.sh 심음)"
}

boot() {
  qemu-system-x86_64 \
    -name h5-probe -machine q35,accel=kvm -cpu host \
    -m "$MEM_MB" -smp "$CPUS" \
    -drive if=virtio,format=qcow2,file="$WORK/overlay.qcow2" \
    -drive if=virtio,format=raw,file="$WORK/seed.iso",readonly=on \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -display none -serial "file:$WORK/console.log" \
    -pidfile "$WORK/qemu.pid" -daemonize
  log "부팅 (mem ${MEM_MB}MiB · vcpu ${CPUS} · ssh 127.0.0.1:${SSH_PORT})"
}

wait_ssh() {
  local s=(-i "$WORK/id_ed25519" -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
           -o ConnectTimeout=5 -p "$SSH_PORT" probe@127.0.0.1)
  for i in $(seq 1 "$((BOOT_WAIT/5))"); do
    if ssh "${s[@]}" true 2>/dev/null; then log "SSH 준비됨 ($((i*5))초)"; return 0; fi
    sleep 5
  done
  die "SSH 가 ${BOOT_WAIT}초 안에 열리지 않았다 — $WORK/console.log 를 볼 것"
}

verify() {
  local s=(-i "$WORK/id_ed25519" -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
           -p "$SSH_PORT" probe@127.0.0.1)
  log "verify-h5.sh 실행 (EXPECT_DRV=virtio_net) — 몇 분 걸린다"
  ssh "${s[@]}" 'sudo EXPECT_DRV=virtio_net bash /usr/local/bin/verify-h5.sh' 2>&1 | tee "$RESULT"
}

case "${1:-run}" in
  run)
    [ "$(id -u)" -eq 0 ] || die "root 로 실행할 것 (KVM 접근)"
    [ -c /dev/kvm ] || die "/dev/kvm 이 없다 — 중첩 가상화를 확인할 것"
    trap destroy EXIT
    prep; boot; wait_ssh; verify
    ;;
  clean)
    destroy || true
    ;;
  *) echo "사용: $0 run|clean"; exit 2 ;;
esac
