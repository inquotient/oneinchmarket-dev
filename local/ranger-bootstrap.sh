#!/usr/bin/env bash
# Ranger 의 서비스(리포지토리) 정의를 git 에서 클러스터로 밀어 넣는다.
#
# ★★★ 왜 필요한가 — **서비스 정의는 Ranger 의 DB 에만 살기 때문이다.**
#   플러그인(HDFS·Hive·HBase)은 `ranger.plugin.<svc>.service.name` 으로 자기
#   서비스를 찾는다. 그 이름이 Admin 에 없으면 30초마다 `service not found`(404)
#   를 받고 정책 버전이 `-1` 에 머문다. 그때 계층마다 결과가 다르다:
#     HDFS  — `xasecure.add-hadoop-authorization=true` 라 POSIX 로 폴백해 멀쩡해 보인다
#     Hive  — 폴백이 없어 **모든 질의가 거부**된다(`does not have [USE] privilege`)
#     HBase — 폴백이 없어(Gotcha 39) **마스터 자신**이 `hbase:meta` put 을 거부당해
#             초기화를 끝내지 못한다. 파드는 `1/1 Running` 이다
#   실측(2026-10-18): 베어메탈 재구축 뒤 서비스 **0개**, HBase 마스터 7일째 초기화 중.
#   예전 WSL 클러스터에서 손으로 만든 것이 git 에 흔적이 없었다 —
#   Gravitee(Gotcha 159)·SafeLine 과 같은 부류의 "레포 밖 원천"(LOCAL-DEPLOYMENT §25-0).
#
# ★ 원천은 `local/ranger-services/*.json` 하나다(Gotcha 117). 파일 이름이 아니라
#   본문의 `name` 이 플러그인 설정의 service.name 과 같아야 한다.
#
# ★ `username` 은 조회(lookup)용 사용자이면서, Ranger 가 서비스를 만들 때 생성하는
#   **기본 정책에 전권으로 들어가는 사용자**다. 그래서 각 서비스가 실제로 도는
#   사용자(hbase·hive)를 적는다 — HBase 마스터가 hbase:meta 에 쓰려면 이것이 필요하다.
#   `password` 는 조회 기능(UI 자동완성)에만 쓰이고 이 클러스터는 그것을 쓰지 않으므로
#   자리표시자다. 필수 필드라 비울 수 없다.
#
# ★★★ Gotcha 11 — Ranger 는 로그인 실패가 쌓이면 계정을 **영구히** 잠근다.
#   그래서 이 스크립트는 ① 자격을 **한 번** 시험하고 ② 401 이면 재시도 없이 즉시
#   멈춘다. 반복 실행 루프·cron 에 넣지 말 것.
#
# 멱등하다 — 같은 이름의 서비스가 있으면 만들지 않는다(설정이 git 과 다르면
# 표시만 한다. 덮어쓰면 손으로 고친 정책·설정을 잃을 수 있다).
#
# 사용법:  bash local/ranger-bootstrap.sh            # 없는 것을 만든다
#          bash local/ranger-bootstrap.sh --check    # 만들지 않고 보고만 (없으면 1)
set -Eeuo pipefail
trap 'echo "[ranger][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="${NS:-local}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/ranger-services"
PORT="${PORT:-16080}"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
log() { echo "[ranger] $*"; }

tmp=$(mktemp -d); trap 'shred -u "$tmp"/* 2>/dev/null; rm -rf "$tmp"; kill %1 2>/dev/null || true' EXIT
pw=$(kubectl -n "$NS" get secret ranger-secret -o jsonpath='{.data.admin-password}' | base64 -d)
[ -n "$pw" ] || { echo "[ranger] ranger-secret/admin-password 가 비었다 — create-secrets.sh 를 볼 것" >&2; exit 1; }
# 자격을 명령줄(-u)에 두지 않는다 — 노드의 ps 에 남는다.
printf 'machine 127.0.0.1 login admin password %s\n' "$pw" > "$tmp/netrc"; unset pw
chmod 600 "$tmp/netrc"

kubectl -n "$NS" port-forward pod/ranger-admin-0 "$PORT:6080" >/dev/null 2>&1 &
for i in $(seq 1 20); do
  sleep 1
  # ★ 인증이 필요 없는 경로로만 기다린다 — 대기 루프에서 자격을 쓰면 그것이 곧
  #   Gotcha 11 의 "로그인을 두드리는 자동화" 가 된다.
  curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/login.jsp" && break
  [ "$i" = "20" ] && { echo "[ranger] ranger-admin 에 붙지 못했다" >&2; exit 1; }
done

B="http://127.0.0.1:$PORT/service/public/v2/api"
C=(curl -s --netrc-file "$tmp/netrc" --max-time 30)

# ★★ 자격 시험은 **한 번**이다. 401 이면 그대로 멈춘다(Gotcha 11).
code=$("${C[@]}" -o /dev/null -w '%{http_code}' "$B/service")
case "$code" in
  200) ;;
  401) echo "[ranger] 관리자 자격이 401 이다 — **다시 돌리지 말 것**(Gotcha 11: 실패가 쌓이면 영구 잠금)." >&2
       echo "[ranger]   잠김 여부: kubectl -n $NS logs ranger-admin-0 -c ranger-admin | grep -c 'User account is locked'" >&2
       exit 1 ;;
  *)   echo "[ranger] 서비스 목록이 $code 다" >&2; exit 1 ;;
esac

shopt -s nullglob
files=("$SRC"/*.json)
[ "${#files[@]}" -gt 0 ] || { echo "[ranger] $SRC 에 정의가 없다" >&2; exit 1; }

missing=0
for f in "${files[@]}"; do
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  code=$("${C[@]}" -o "$tmp/cur.json" -w '%{http_code}' "$B/service/name/$name")

  if [ "$code" = "200" ]; then
    # 설정 차이는 보고만 한다. password 는 Admin 이 가려서 돌려주므로 비교하지 않는다.
    diff=$(python3 - "$f" "$tmp/cur.json" <<'PY'
import json,sys
want=json.load(open(sys.argv[1]))["configs"]; have=json.load(open(sys.argv[2])).get("configs",{})
print(" ".join(k for k,v in want.items() if k!="password" and have.get(k)!=v))
PY
)
    if [ -n "$diff" ]; then log "$name: 있다 — 단 git 과 다른 설정: $diff (바꾸지 않는다)"
    else log "$name: 있다"; fi
    continue
  fi
  [ "$code" = "404" ] || { echo "[ranger] $name 조회가 $code 다" >&2; exit 1; }

  if [ "$CHECK" = 1 ]; then log "$name: **없다**"; missing=$((missing+1)); continue; fi

  code=$("${C[@]}" -o "$tmp/new.json" -w '%{http_code}' -X POST \
         -H 'Content-Type: application/json' --data @"$f" "$B/service")
  [ "$code" = "200" ] || { echo "[ranger] $name 생성이 $code 다: $(head -c 300 "$tmp/new.json")" >&2; exit 1; }
  log "$name: 생성됨"
done

[ "$CHECK" = 1 ] && { [ "$missing" = 0 ] && exit 0 || exit 1; }

# ★ "만들었다" 로 끝내지 않는다 — 기본 정책이 서비스 사용자에게 전권을 주는지
#   **되읽어** 확인한다. 그것이 없으면 HBase 마스터는 계속 거부당한다.
fail=0
for f in "${files[@]}"; do
  read -r name user < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["name"], d["configs"]["username"])' "$f")
  n=$("${C[@]}" "$B/service/$name/policy" | python3 -c "
import json,sys
ps=json.load(sys.stdin); u=sys.argv[1]
print(sum(1 for p in ps if p.get('isEnabled') for i in p.get('policyItems',[]) if u in i.get('users',[])))
" "$user")
  if [ "${n:-0}" -gt 0 ]; then log "$name: 기본 정책 중 $n 개가 '$user' 에게 권한을 준다"
  else log "$name: **'$user' 에게 권한을 주는 정책이 없다** — HBase 라면 마스터가 계속 거부된다"; fail=1; fi
done

log "플러그인은 30초(pollIntervalMs) 안에 정책을 받는다 — 판정은 각 서비스 로그의"
log "  'Switched policy engine to [N]' 이 Admin 의 policyVersion 과 같은지로 한다(Gotcha 40)."
exit "$fail"
