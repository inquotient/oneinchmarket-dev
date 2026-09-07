#!/usr/bin/env bash
# OpenBao 초기화 · 봉인 해제 · 키 보관
#
# ★ 왜 스크립트인가 — `bao operator init` 은 **한 번만** 성공한다. 그 출력에
#   unseal 키와 root 토큰이 들어 있고 **그 순간이 아니면 다시 볼 수 없다.**
#   Job 으로 두면 재실행될 때 이미 초기화됐다며 실패하고, 그 실패가
#   "초기화가 안 됐다" 로 읽힌다. 여러 번 돌려도 안전하게 갈라 쓴다.
#
# ★ 키를 어디에 두는가 — Kubernetes Secret `openbao-keys` 다.
#   **이것은 봉인을 약화시킨다** — 여는 열쇠가 여는 대상 옆에 있다.
#   그럼에도 이렇게 하는 이유:
#     · 이 클러스터는 파드가 자주 재시작한다(다른 워크로드 실측 15회).
#       봉인된 OpenBao 는 0/1 이라 External Secrets 가 그때마다 끊긴다.
#     · 로컬에는 auto-unseal 에 쓸 KMS 가 없다(클라우드 KMS·HSM 부재).
#       transit auto-unseal 은 OpenBao 가 하나 더 필요해 순환이다.
#   **prod 에서는 이렇게 하지 말 것** — KMS auto-unseal 또는 M-of-N 분산
#   보관으로 바꿔야 한다. 이 트레이드오프는 §8-80 에 적혀 있다.
#
# ★ 값을 출력하지 않는다. 이 레포 규약이다(local/ACCESS.md 는 비밀번호를
#   값이 아니라 조회 명령으로 적는다).
#
# 사용
#   local/openbao-init.sh          # 초기화(필요하면) + 봉인 해제
#   local/openbao-init.sh --status # 상태만 본다
set -Eeuo pipefail
trap 'echo "[openbao][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
POD="${POD:-openbao-0}"
SECRET="${SECRET:-openbao-keys}"
K() { kubectl -n "$NS" "$@"; }
log() { echo "[openbao] $*"; }
bao() { K exec -i "$POD" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 bao "$@"; }

if [ "${1:-}" = "--status" ]; then
  bao status || true
  exit 0
fi

log "파드 대기"
K wait --for=condition=PodReadyToStartContainers "pod/$POD" --timeout=180s >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6 7 8 9 10; do
  if bao status >/dev/null 2>&1 || [ $? -ne 0 ]; then break; fi
  sleep 5
done

# bao status 의 종료 코드: 0=unsealed · 1=오류 · 2=sealed
set +e
bao status >/tmp/bao-status.txt 2>&1
RC=$?
set -e
log "현재 상태 코드=${RC} (0=해제됨 · 2=봉인됨)"

INITIALIZED="$(grep -c 'Initialized.*true' /tmp/bao-status.txt || true)"

if [ "$INITIALIZED" = "0" ]; then
  log "초기화되지 않았다 — operator init 을 실행한다"
  if K get secret "$SECRET" >/dev/null 2>&1; then
    echo "[openbao] ★ 위험: 스토리지는 미초기화인데 Secret ${SECRET} 이 이미 있다." >&2
    echo "         PVC 가 지워졌을 가능성이 크다. 낡은 키로는 절대 열 수 없으므로" >&2
    echo "         Secret 을 먼저 지우고 다시 실행할 것:" >&2
    echo "           kubectl -n ${NS} delete secret ${SECRET}" >&2
    exit 1
  fi
  # ★ key-shares=1 은 로컬 전용 단순화다. 운영은 5/3 같은 M-of-N 이어야 한다.
  TMP="$(mktemp)"; chmod 600 "$TMP"
  bao operator init -key-shares=1 -key-threshold=1 -format=json > "$TMP"
  # 값을 셸 변수로 꺼내지 않는다 — 프로세스 목록·히스토리에 남지 않게
  # 파일에서 파일로 옮긴다.
  UK="$(mktemp)"; RT="$(mktemp)"; chmod 600 "$UK" "$RT"
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));open(sys.argv[2],"w").write(d["unseal_keys_b64"][0]);open(sys.argv[3],"w").write(d["root_token"])' "$TMP" "$UK" "$RT"
  K create secret generic "$SECRET" \
      --from-file=unseal-key="$UK" \
      --from-file=root-token="$RT" \
      --dry-run=client -o yaml | K apply -f - >/dev/null
  shred -u "$TMP" "$UK" "$RT" 2>/dev/null || rm -f "$TMP" "$UK" "$RT"
  log "초기화 완료 — 키를 Secret ${SECRET} 에 보관했다(값은 출력하지 않는다)"
else
  log "이미 초기화되어 있다"
fi

if [ "$RC" = "2" ]; then
  log "봉인 해제"
  # bao operator unseal - 는 stdin 을 읽지 않는다(실측:
  #   "'key' must be a valid hex or base64 string"). 컨테이너 안에서
  #   read 로 받아 인자로 넘긴다 — 호스트의 프로세스 목록에는 남지 않는다.
  K get secret "$SECRET" -o json > /tmp/bao-sec.json
  python3 -c 'import base64,json,sys;d=json.load(open("/tmp/bao-sec.json"))["data"];sys.stdout.write(base64.b64decode(d["unseal-key"]).decode())' > /tmp/bao-uk.txt
  K exec -i "$POD" -c openbao -- env BAO_ADDR=http://127.0.0.1:8200 \
      sh -c 'read -r K; bao operator unseal "$K"' < /tmp/bao-uk.txt >/dev/null
  shred -u /tmp/bao-sec.json /tmp/bao-uk.txt 2>/dev/null || rm -f /tmp/bao-sec.json /tmp/bao-uk.txt
  log "해제 완료"
fi

# ── 감사 장치 ────────────────────────────────────────────────────
# 여기서 켜지 않는다. OpenBao 2.4 는 API 로 감사 장치를 켤 수 없고
#   (cannot enable audit device via API — 실측 400)
# ConfigMap 의 `audit "stdout"` 스탠자가 선언적으로 켠다.

log "최종 상태"
bao status | grep -E 'Seal Type|Initialized|Sealed|Storage Type|Version' || true
log "root 토큰 조회:  kubectl -n ${NS} get secret ${SECRET} -o jsonpath='{.data.root-token}' | base64 -d"
