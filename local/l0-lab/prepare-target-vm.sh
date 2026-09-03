#!/usr/bin/env bash
# L0-Target VM 디스크 준비 — Ubuntu 클라우드 이미지 → Hyper-V VHDX
#
# 왜 live-server ISO 를 쓰지 않는가
#   2.6 GB 를 받아 콘솔에서 수동 설치해야 한다. 클라우드 이미지는 600 MB 대이고
#   cloud-init 로 첫 부팅을 자동화할 수 있다. ADR-053 이 "cloud-init seed ISO 는
#   Windows 에서 oscdimg 를 요구한다"며 골든 VHDX 를 택했는데, **WSL 안에서는
#   genisoimage 로 만들 수 있다** — 그 제약은 Windows 도구 기준이었다.
#
# 산출물 (기본 /mnt/c/Users/darka/HyperV/L0Lab)
#   L0-Target.vhdx      부팅 디스크
#   L0-Target-seed.iso  cloud-init NoCloud 시드 (레이블 cidata)
#
# 실행: WSL 안에서. 관리자 권한 불필요 — VM 생성만 관리자가 필요하다.
set -Eeuo pipefail
trap 'echo "[target][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/mnt/c/Users/darka/HyperV/L0Lab}"
CACHE="${CACHE:-/mnt/c/Users/darka/iso}"
REL="${REL:-noble}"          # Ubuntu 24.04 — ADR-051 이 상정한 게스트
IMG="ubuntu-24.04-server-cloudimg-amd64.img"
URL="https://cloud-images.ubuntu.com/releases/${REL}/release/${IMG}"
DISK_GB="${DISK_GB:-24}"
PASS="${PASS:-l0lab}"        # 랩 전용 콘솔 로그인. 운영 자격이 아니다.

log() { echo "[target] $*"; }
mkdir -p "$OUT" "$CACHE"

# ── 1. 클라우드 이미지 ───────────────────────────────────────
if [ ! -f "$CACHE/$IMG" ]; then
  log "클라우드 이미지 내려받기 ($REL)"
  curl -fsSL --retry 3 -o "$CACHE/$IMG" "$URL"
fi
log "이미지 $(stat -c%s "$CACHE/$IMG" | awk '{printf "%.0f MB",$1/1048576}')"

# ── 2. VHDX 변환 ────────────────────────────────────────────
# Gen2(UEFI) 부팅에는 ESP 가 필요하다. Ubuntu 클라우드 이미지는 UEFI 부팅이
# 가능하므로 그대로 변환하면 된다.
if [ ! -f "$OUT/L0-Target.vhdx" ]; then
  log "qcow2 -> vhdx 변환"
  qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic \
    "$CACHE/$IMG" "$OUT/L0-Target.vhdx"
  log "디스크 ${DISK_GB}G 로 확장"
  qemu-img resize "$OUT/L0-Target.vhdx" "${DISK_GB}G"
fi
log "VHDX $(stat -c%s "$OUT/L0-Target.vhdx" | awk '{printf "%.0f MB",$1/1048576}')"

# ── 3. cloud-init 시드 ──────────────────────────────────────
# NoCloud 데이터소스는 **레이블이 cidata 인** 볼륨을 찾는다. 레이블이 틀리면
# cloud-init 가 조용히 건너뛰고 로그인할 수 없는 VM 이 남는다.
SEEDDIR="$OUT/.seed"
mkdir -p "$SEEDDIR"
cat > "$SEEDDIR/meta-data" <<EOF
instance-id: l0-target-1
local-hostname: l0-target
EOF
{
  echo "#cloud-config"
  echo "users:"
  echo "  - name: ubuntu"
  echo "    groups: [sudo]"
  echo "    shell: /bin/bash"
  echo '    sudo: ["ALL=(ALL) NOPASSWD:ALL"]'
  echo "    lock_passwd: false"
  echo "    plain_text_passwd: ${PASS}"
  echo "ssh_pwauth: true"
  echo "chpasswd:"
  echo "  expire: false"
  echo "package_update: true"
  echo "packages: [curl, ca-certificates]"
  echo "write_files:"
  echo "  # H5 검증 스크립트를 심어 둔다. 콘솔에서 바로 돌릴 수 있다."
  echo "  - path: /usr/local/bin/verify-h5.sh"
  echo "    permissions: '0755'"
  echo "    encoding: b64"
  echo "    content: |"
  base64 -w 76 "$HERE/verify-h5.sh" | sed 's/^/      /'
  echo "runcmd:"
  echo '  - [ sh, -c, "echo H5 검증은 sudo verify-h5.sh > /etc/motd" ]'
} > "$SEEDDIR/user-data"

log "시드 ISO 생성 (레이블 cidata)"
genisoimage -output "$OUT/L0-Target-seed.iso" -volid cidata \
  -joliet -rock "$SEEDDIR/user-data" "$SEEDDIR/meta-data" >/dev/null 2>&1
log "시드 $(stat -c%s "$OUT/L0-Target-seed.iso" | awk '{printf "%.1f MB",$1/1048576}')"

echo
log "완료. 다음은 관리자 PowerShell 에서 setup-l0-lab.ps1 실행"
log "  콘솔 로그인: ubuntu / ${PASS}"
