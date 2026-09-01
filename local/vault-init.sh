#!/usr/bin/env bash
# Vault 초기화 · 봉인 해제 (로컬 한정)
#
# 왜 별도 스크립트인가 —
#   Vault 는 dev 모드가 아니면 **봉인(sealed) 상태로 뜬다.** 이것은 결함이
#   아니라 설계다. 초기화하면 unseal 키와 root token 이 나오는데, 그 순간
#   외에는 다시 볼 수 없다. 매니페스트로 자동화할 수 없는 이유다.
#
#   readiness 프로브가 봉인 중에는 실패하도록 되어 있어 vault-0 은
#   0/1 로 남는다. 이 스크립트를 돌린 뒤에야 1/1 이 된다.
#
# ★ 재시작하면 다시 봉인된다. auto-unseal 은 KMS(클라우드 또는 Transit)를
#   요구하는데 로컬에는 없다. 재시작 후 `unseal` 서브커맨드로 다시 연다.
#
# ★ 저장 위치 — unseal 키와 root token 을 k8s Secret `vault-init` 에 넣는다.
#   같은 클러스터에 Vault 의 열쇠를 두는 것은 프로덕션에서는 틀렸다.
#   로컬 검증 편의이며, ADR-024 로 Vault 를 실제 시크릿 원천으로 삼을 때
#   반드시 다시 논의해야 한다.
set -Eeuo pipefail
trap 'echo "[vault][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${NS:-local}"
POD="vault-0"
log() { echo "[vault] $*"; }
vx() { kubectl -n "$NS" exec "$POD" -- env VAULT_ADDR=http://127.0.0.1:8200 vault "$@"; }

case "${1:-init}" in
  init)
    log "파드 대기"
    kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Running "pod/$POD" --timeout=300s
    until vx status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 3; done

    # `vault status` 종료 코드: 0=열림 2=봉인 1=오류(미초기화 포함)
    if vx status 2>/dev/null | grep -q "Initialized.*true"; then
      log "이미 초기화되어 있다 — unseal 로 넘어간다"
    else
      log "초기화 (key-shares=1, key-threshold=1)"
      # 로컬은 키를 나눠 가질 사람이 없다. 샤딩은 운영 절차이지 기술 요구가 아니다.
      OUT=$(vx operator init -key-shares=1 -key-threshold=1 -format=json)

      # ★★ 순서가 중요하다 — 파싱보다 저장이 먼저다.
      #   unseal 키는 이 출력 외에는 어디에도 없다. 파싱을 먼저 하다
      #   실패하면 Vault 는 이미 초기화된 채 열쇠만 사라진다(실제로 겪었다:
      #   여러 줄 JSON 을 한 줄 grep 으로 읽다 실패 -> PVC 폐기 후 재초기화).
      #   그래서 출력을 통째로 먼저 Secret 에 넣고, 그다음 파싱한다.
      kubectl -n "$NS" delete secret vault-init --ignore-not-found >/dev/null
      kubectl -n "$NS" create secret generic vault-init --from-literal="init-json=$OUT" >/dev/null
      kubectl -n "$NS" label secret vault-init \
        app.kubernetes.io/part-of=oneinchmarket \
        app.kubernetes.io/managed-by=local-script >/dev/null
      log "init 출력 원본을 Secret vault-init(init-json)에 저장했다"

      # 편의 키 추가. -format=json 은 여러 줄이므로 먼저 개행을 없앤다.
      FLAT=$(printf '%s' "$OUT" | tr -d ' \n')
      UNSEAL=$(printf '%s' "$FLAT" | grep -o '"unseal_keys_b64":\["[^"]*"' | sed 's/.*\["//;s/"$//')
      ROOT=$(printf   '%s' "$FLAT" | grep -o '"root_token":"[^"]*"'        | sed 's/.*:"//;s/"$//')
      if [ -z "$UNSEAL" ] || [ -z "$ROOT" ]; then
        echo "[vault] 파싱 실패 — 원본은 Secret vault-init 의 init-json 에 있다"
        printf '%s\n' "$OUT"
        exit 1
      fi
      kubectl -n "$NS" patch secret vault-init --type merge -p "{\"stringData\":{\
\"unseal-key\":\"$UNSEAL\",\"root-token\":\"$ROOT\"}}" >/dev/null
      log "unseal 키·root token 을 Secret vault-init 에 저장했다"
    fi
    # bash 로 명시 호출한다. `bash local/vault-init.sh` 처럼 실행 비트 없이
    # 불린 경우 "$0" 직접 실행이 Permission denied 로 실패한다.
    bash "$0" unseal
    ;;

  unseal)
    UNSEAL=$(kubectl -n "$NS" get secret vault-init -o jsonpath='{.data.unseal-key}' | base64 -d)
    log "봉인 해제"
    vx operator unseal "$UNSEAL" >/dev/null
    vx status | grep -E "Initialized|Sealed|Version"
    log "Ready 대기"
    kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s
    echo
    log "접속 정보 (커밋되지 않는다)"
    printf "  root token : %s\n" "$(kubectl -n "$NS" get secret vault-init -o jsonpath='{.data.root-token}' | base64 -d)"
    printf "  UI         : kubectl -n %s port-forward vault-0 8200:8200\n" "$NS"
    ;;

  status)
    vx status || true
    ;;

  *)
    echo "사용법: $0 [init|unseal|status]"; exit 2
    ;;
esac
