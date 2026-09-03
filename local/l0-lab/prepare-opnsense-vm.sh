#!/usr/bin/env bash
# L0-OPNsense 부팅 디스크 준비 — nano 이미지 → Hyper-V VHDX
#
# ★ 왜 DVD 가 아니라 nano 인가
#   DVD 는 **설치 프로그램**이고 VGA 프레임버퍼에 그린다. 텍스트 스트림이
#   아니므로 자동화할 수 없다 — 관리자 권한이 있어도 마찬가지다. 사람이
#   콘솔 앞에 앉아야 한다.
#
#   nano 는 **이미 설치된 시스템**이다. 미디어에 그대로 써서 부팅한다.
#   설치 대화 자체가 없고, 임베디드용이라 시리얼 콘솔이 기본이다. 그래서
#   Hyper-V COM 포트를 named pipe 에 붙이면 콘솔을 스크립트로 몰 수 있다.
#   (serial-console.ps1 · serial-expect.ps1)
#
# ★ nano 의 대가 — 알고 쓸 것
#   1. /var 와 /tmp 가 MFS(램디스크)다. 이 랩의 목적이 하필
#      "Suricata EVE JSON · Zeek 로그 → Logstash" 라서 그대로 두면 로그가
#      램에 쌓이다 재부팅에 사라진다. 첫 부팅 후 꺼야 한다
#      (System > Settings > Miscellaneous, 또는 콘솔에서 설정)
#   2. 파티션이 작은 미디어 기준이다. 디스크를 키워도 UFS 는 자동으로 늘지
#      않는다 — gpart recover + gpart resize + growfs 가 필요하다.
#      그래서 여기서는 **원본 크기 그대로** 변환한다. 늘리는 것은 콘솔이
#      잡힌 뒤에 하는 편이 안전하다(백업 GPT 헤더 위치 문제를 피한다)
#
# 실행: WSL 안에서. 관리자 권한 불필요 — VM 조작만 관리자가 필요하다.
set -Eeuo pipefail
trap 'echo "[opnsense][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

OUT="${OUT:-/mnt/c/Users/darka/HyperV/L0Lab}"
CACHE="${CACHE:-/mnt/c/Users/darka/iso}"
VER="${VER:-26.7}"
BZ="OPNsense-${VER}-nano-amd64.img.bz2"
IMG="OPNsense-${VER}-nano-amd64.img"
VHDX="$OUT/L0-OPNsense.vhdx"

log() { echo "[opnsense] $*"; }
mkdir -p "$OUT" "$CACHE"

[ -f "$CACHE/$BZ" ] || { echo "압축 이미지가 없다: $CACHE/$BZ" >&2; exit 1; }

# ── 1. 압축 해제 ────────────────────────────────────────────
if [ ! -f "$CACHE/$IMG" ]; then
  log "bunzip2 ($(stat -c%s "$CACHE/$BZ" | awk '{printf "%.0f MB",$1/1048576}'))"
  bunzip2 -k -c "$CACHE/$BZ" > "$CACHE/$IMG.part"
  mv "$CACHE/$IMG.part" "$CACHE/$IMG"
fi
log "raw 이미지 $(stat -c%s "$CACHE/$IMG" | awk '{printf "%.0f MB",$1/1048576}')"

# ── 2. VHDX 변환 ────────────────────────────────────────────
# nano 는 raw 다(-f raw). Ubuntu 클라우드 이미지의 qcow2 와 다르다.
if [ -f "$VHDX" ]; then
  log "기존 $VHDX 를 .bak 으로 물린다"
  mv "$VHDX" "$VHDX.bak.$(date +%s)"
fi
log "raw -> vhdx 변환"
qemu-img convert -f raw -O vhdx -o subformat=dynamic "$CACHE/$IMG" "$VHDX"
qemu-img info "$VHDX" | sed -n '2,4p'

echo
log "완료. 다음은 관리자 PowerShell 에서:"
log "  Set-VMHardDiskDrive -VMName L0-OPNsense -ControllerType SCSI \\"
log "    -ControllerNumber 0 -ControllerLocation 0 -Path '$(echo "$VHDX" | sed 's|/mnt/c|C:|')'"
log "  Set-VMComPort -VMName L0-OPNsense -Number 1 -Path '\\.\pipe\opnsense-com1'"
log "  Get-VMDvdDrive -VMName L0-OPNsense | Remove-VMDvdDrive   # 설치 미디어는 필요 없다"
