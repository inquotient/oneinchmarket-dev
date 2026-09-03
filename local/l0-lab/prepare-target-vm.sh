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

# ── 0. 랩 전용 SSH 키 ───────────────────────────────────────
# 콘솔 비밀번호만으로는 호스트에서 자동 실행을 할 수 없다 — Windows OpenSSH
# 클라이언트는 비밀번호를 표준입력으로 받지 않는다. H5 검증을 사람이 콘솔에
# 타이핑하지 않고 돌리려면 키가 필요하다.
#
# ★ 개인키는 $OUT 에 생성된다. **레포 밖이다** — 커밋 경로에 두지 않는다.
#   운영 자격이 아니라 격리된 랩 VM 전용이며 VM 과 수명을 같이한다.
KEY="${KEY:-$OUT/L0-Target-key}"
if [ ! -f "$KEY" ]; then
  log "랩 전용 SSH 키 생성 ($KEY)"
  ssh-keygen -t ed25519 -N '' -C 'l0-lab-target' -f "$KEY" >/dev/null
fi

# ── 1. 클라우드 이미지 ───────────────────────────────────────
if [ ! -f "$CACHE/$IMG" ]; then
  log "클라우드 이미지 내려받기 ($REL)"
  curl -fsSL --retry 3 -o "$CACHE/$IMG" "$URL"
fi
log "이미지 $(stat -c%s "$CACHE/$IMG" | awk '{printf "%.0f MB",$1/1048576}')"

# ── 2. VHDX 변환 ────────────────────────────────────────────
# Gen2(UEFI) 부팅에는 ESP 가 필요하다. Ubuntu 클라우드 이미지는 UEFI 부팅이
# 가능하므로 그대로 변환하면 된다.
#
# ★ 순서가 중요하다 — **qcow2 단계에서 늘린 뒤 변환**한다. 반대로 하면 실패한다:
#     qemu-img: Image format driver does not support resize
#   qemu 의 vhdx 드라이버는 읽기·쓰기·변환은 되지만 resize 를 구현하지 않는다.
#   그런데 그때 vhdx 는 이미 만들어진 뒤라 **크기만 틀린 파일이 남는다** —
#   아래 존재 검사에 걸려 재실행이 조용히 건너뛴다. 그래서 실패 시 지운다.
#   게스트 파티션은 cloud-init 의 growpart 가 첫 부팅에 맞춰 늘린다.
if [ ! -f "$OUT/L0-Target.vhdx" ]; then
  WORK="$OUT/.work.qcow2"
  trap 'rm -f "$WORK" ; [ -s "$OUT/L0-Target.vhdx" ] || rm -f "$OUT/L0-Target.vhdx"' EXIT
  log "작업 사본을 ${DISK_GB}G 로 확장"
  cp "$CACHE/$IMG" "$WORK"
  qemu-img resize "$WORK" "${DISK_GB}G"
  log "qcow2 -> vhdx 변환"
  qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic \
    "$WORK" "$OUT/L0-Target.vhdx"
  rm -f "$WORK"
fi
log "VHDX $(stat -c%s "$OUT/L0-Target.vhdx" | awk '{printf "%.0f MB",$1/1048576}')"

# ── 3. cloud-init 시드 ──────────────────────────────────────
# NoCloud 데이터소스는 **레이블이 cidata 인** 볼륨을 찾는다. 레이블이 틀리면
# cloud-init 가 조용히 건너뛰고 로그인할 수 없는 VM 이 남는다.
SEEDDIR="$OUT/.seed"
mkdir -p "$SEEDDIR"
{
  echo "#cloud-config"
  echo "users:"
  echo "  - name: ubuntu"
  echo "    groups: [sudo]"
  echo "    shell: /bin/bash"
  echo '    sudo: ["ALL=(ALL) NOPASSWD:ALL"]'
  echo "    lock_passwd: false"
  echo "    plain_text_passwd: ${PASS}"
  echo "    ssh_authorized_keys:"
  echo "      - $(cat "$KEY.pub")"
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

# ★ instance-id 를 **시드 내용의 해시**로 만든다.
#   cloud-init 은 per-instance 모듈을 instance-id 가 바뀔 때만 다시 돈다.
#   고정값이면 시드를 고쳐 붙여도 조용히 무시되어, 키를 추가해 놓고도
#   로그인이 안 되는 상태를 디버깅하게 된다. 해시로 두면 시드가 바뀐
#   경우에만 재실행되고 바뀌지 않았으면 그대로 둔다.
IID="l0-target-$(sha256sum "$SEEDDIR/user-data" | cut -c1-12)"
cat > "$SEEDDIR/meta-data" <<EOF
instance-id: $IID
local-hostname: l0-target
EOF
log "instance-id $IID"

log "시드 ISO 생성 (레이블 cidata)"
# ★ stderr 를 버리지 않는다. 여기 실패의 가장 흔한 원인은 **ISO 가 실행 중인
#   VM 의 DVD 에 물려 잠긴 것**인데(실측), 메시지를 지우면 "Permission denied"
#   대신 줄 번호만 남아 원인을 찾을 수 없다.
genisoimage -output "$OUT/L0-Target-seed.iso" -volid cidata \
  -joliet -rock "$SEEDDIR/user-data" "$SEEDDIR/meta-data" >/dev/null
log "시드 $(stat -c%s "$OUT/L0-Target-seed.iso" | awk '{printf "%.1f MB",$1/1048576}')"

echo
log "완료. 다음은 관리자 PowerShell 에서 setup-l0-lab.ps1 실행"
log "  콘솔 로그인: ubuntu / ${PASS}"
