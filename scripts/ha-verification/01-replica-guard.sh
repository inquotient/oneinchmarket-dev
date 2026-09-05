#!/usr/bin/env bash
# HA-1: 복제본 수 가드 — §11-3 회귀 방지
#
# ★ 이 검사가 존재하는 이유
#   prod 오버레이가 postgresql 2 · mariadb 2 · mongodb 3 으로 올리고 있었다.
#   셋 다 StatefulSet + volumeClaimTemplates 라 파드마다 별도 PVC 를 받고
#   복제 설정이 하나도 없다. 헤드리스 서비스가 두 파드 IP 를 모두 반환하므로
#   올리는 순간 서로 다른 DB 로 쓰기가 갈린다 — **접속은 성공하므로 오류가
#   나지 않는다.** 사람이 알아채지 못하는 종류의 결함이라 검사로 막는다.
#
# 판정: 복제 기구(wal_level/primary_conninfo/patroni/repmgr/wsrep/replSet)가
#       매니페스트에 없는데 replicas >= 2 이면 FAIL.
# 실행: ./01-replica-guard.sh [repo_root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAIL=0

echo "=== HA-1: 복제본 수 가드 (§11-3) ==="
echo ""

check_db() {
  local db="$1"
  local dir="$ROOT/kubernetes/base/database/$db"
  [ -d "$dir" ] || { printf "  ${YELLOW}[SKIP]${NC} %s — 디렉터리 없음\n" "$db"; return; }

  # 복제 기구가 매니페스트에 있는가
  local repl=0
  if grep -rqi "wal_level\|primary_conninfo\|repmgr\|patroni\|wsrep\|galera\|replSet\|replicaSet" "$dir" 2>/dev/null; then
    repl=1
  fi

  # 오버레이가 지정하는 최대 replicas
  local maxrep=1
  for f in $(grep -rl "name: $db" "$ROOT/kubernetes/overlays" --include=*.yaml 2>/dev/null); do
    local r
    r=$(awk -v n="$db" '
      /^kind:/{k=$2} /^  name: /{cur=$2}
      /^  replicas:/{ if (cur==n) print $2 }' "$f" 2>/dev/null | sort -n | tail -1)
    [ -n "${r:-}" ] && [ "$r" -gt "$maxrep" ] && maxrep="$r"
  done

  if [ "$repl" -eq 0 ] && [ "$maxrep" -ge 2 ]; then
    printf "  ${RED}[FAIL]${NC} %-12s replicas=%s 인데 복제 기구가 없다 — 데이터 분기\n" "$db" "$maxrep"
    FAIL=1
  elif [ "$repl" -eq 0 ]; then
    printf "  ${GREEN}[OK]${NC}   %-12s replicas=%s · 복제 미구성이나 1이라 안전\n" "$db" "$maxrep"
  else
    printf "  ${GREEN}[OK]${NC}   %-12s replicas=%s · 복제 기구 있음\n" "$db" "$maxrep"
  fi
}

for db in postgresql mariadb mongodb; do check_db "$db"; done

echo ""
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}HA-1 통과${NC} — 복제 없이 복제본을 올린 곳이 없다\n"
else
  printf "${RED}HA-1 실패${NC} — docs/LOCAL-DEPLOYMENT.md §13 참조\n"
fi
exit $FAIL
