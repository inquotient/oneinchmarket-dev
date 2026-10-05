#!/usr/bin/env bash
# 렌더 안에 박힌 **셸 스크립트의 문법**을 전수 검사한다.
#
# 왜 있는가
# ---------
# 이 레포의 부트스트랩 Job·initContainer 는 `args: [- |]` 블록에 셸을 담는다.
# 그 안이 깨져도 **`kubectl kustomize` 와 `kubeconform` 은 통과한다** — YAML 로는
# 올바른 문자열이기 때문이다. 깨진 것은 파드가 뜬 뒤에야 드러나고, 그 파드가
# 훅이면 **동기화 전체가 그 자리에 선다.**
#
# ★★★ 2026-10-06 에 실제로 그랬다. `kafka-connect-connectors` 의 대기 루프에
#   상한을 넣으면서 여러 줄짜리 `until` 의 **첫 줄만** 바꿨고, 원래 본문과 `done`
#   이 잔해로 남았다. 렌더는 통과했고 클러스터에서 이렇게 나왔다:
#       /bin/bash: -c: line 23: syntax error near unexpected token `done'
#   훅이 CrashLoop 하면서 wave 3 이 9분 넘게 섰다.
#   ★ Gotcha 8(`.sh` 안의 리터럴 `\n`)·83(YAML 리터럴 블록 안의 `#`)·160(셸
#     문자열 안의 백틱)과 같은 뿌리다 — **담는 그릇의 검증이 담긴 것을 검증하지
#     않는다.** 그래서 담긴 것을 따로 검사한다.
#
# 쓰는 법
#   bash local/check-embedded-shell.sh                 # local 오버레이
#   bash local/check-embedded-shell.sh dev prod        # 여러 오버레이
#   OVERLAY_DIR=kubernetes/overlays bash local/check-embedded-shell.sh local
#
# ★ `set -` 로 시작하는 블록만 본다 — 셸이 아닌 블록 스칼라(설정 파일·SQL·XML)를
#   bash 로 검사하면 거짓 경보가 쏟아진다. 그러면 사람이 빨간불을 배경으로
#   읽게 되고, 그때는 진짜 결함도 함께 묻힌다(Gotcha 73·90).
set -Eeuo pipefail
OVERLAY_DIR="${OVERLAY_DIR:-kubernetes/overlays}"
OVERLAYS=("$@"); [ "${#OVERLAYS[@]}" -eq 0 ] && OVERLAYS=(local)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
RC=0

for ov in "${OVERLAYS[@]}"; do
  R="${WORK}/${ov}.yaml"
  if ! kubectl kustomize "${OVERLAY_DIR}/${ov}" > "$R" 2>"${WORK}/err"; then
    echo "[shell] ${ov}: 렌더 실패 — $(head -1 "${WORK}/err")" >&2
    RC=1; continue
  fi
  mkdir -p "${WORK}/${ov}"
  # 블록 스칼라(`- |` / `- |-`)를 들여쓰기로 잘라낸다. 첫 `-` 다음 칸이 본문 기준이다.
  awk -v out="${WORK}/${ov}" '
    /^[ ]+- \|-?[ ]*$/ { base=index($0,"-")+1; inblk=1; n++; f=sprintf("%s/%04d.sh", out, n); next }
    inblk {
      if ($0 ~ /^[ ]*$/) { print "" > f; next }
      match($0, /^[ ]*/)
      if (RLENGTH < base) { inblk=0; next }
      print substr($0, base+1) > f
    }
  ' "$R"

  cnt=0; bad=0
  for f in "${WORK}/${ov}"/*.sh; do
    [ -e "$f" ] && [ -s "$f" ] || continue
    head -3 "$f" | grep -q 'set -' || continue
    cnt=$((cnt+1))
    if ! bash -n "$f" 2>"${WORK}/e"; then
      bad=$((bad+1)); RC=1
      echo "  ★ ${ov}: $(sed -n '2p' "$f" | cut -c1-50) -> $(head -1 "${WORK}/e" | cut -c1-90)" >&2
    fi
  done
  printf '[shell] %-6s 셸 블록 %d 건 · 오류 %d\n' "$ov" "$cnt" "$bad"
done

[ "$RC" = 0 ] || echo "[shell] 문법 오류가 있다 — 그 훅은 파드가 뜬 뒤 CrashLoop 한다" >&2
exit "$RC"
