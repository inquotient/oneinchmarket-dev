#!/usr/bin/env bash
# HA-4: 단일 노드에서 **할 수 없는** 시험 목록
#
# ★ 이 스크립트는 아무것도 시험하지 않는다. 목적은 **없는 것을 눈에 보이게
#   하는 것**이다. 이 레포에서 반복된 실패 유형이 "설정은 있으나 한 번도
#   실행된 적이 없어 아무 증상도 내지 않는" 것이었다(§8-64). 검증 스위트가
#   통과 항목만 출력하면 같은 함정에 빠진다 — 통과 4건이 "HA 검증 완료" 로
#   읽힌다.
#
# 실행: KUBECTL="sudo k3s kubectl" ./04-multinode-gaps.sh [namespace]

set -uo pipefail
K="${KUBECTL:-kubectl}"; NS="${1:-local}"
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

NODES=$($K get node --no-headers 2>/dev/null | wc -l)
echo "=== HA-4: 다중 노드가 있어야 하는 시험 (현재 노드 $NODES개) ==="
echo ""

gap() { printf "  ${YELLOW}[GAP]${NC} %-28s %s\n" "$1" "$2"; }

if [ "$NODES" -lt 2 ]; then
  gap "노드 드레인"        "drain 하면 전 워크로드가 축출된다 — 단일 노드에서 무의미"
  gap "PDB 실동작"         "축출 대상 노드가 없어 PodDisruptionBudget 이 발동하지 않는다"
  gap "안티어피니티"       "분산할 노드가 없어 규칙이 항상 만족되거나 항상 실패한다"
  gap "topologySpread"     "위 동일"
  gap "볼륨 재배치"        "PVC 가 다른 노드에서 뜨는지 — local-path 라 노드 고정(§11-2-b)"
  gap "노드 간 CNI"        "Cilium 데이터패스·정책이 노드를 넘을 때 — §1 의 '검증 불가'"
  gap "etcd 정족수"        "서버 1대라 정족수 상실 시나리오를 만들 수 없다"
else
  echo "  노드가 ${NODES}개다 — 위 항목들을 실제로 시험할 수 있다"
fi
echo ""

# 복제본이 1이라 지금은 시험 자체가 성립하지 않는 것들
echo "  ── 복제본이 1이라 성립하지 않는 시험 ──"
for w in kafka elasticsearch-es-default redis clickhouse; do
  R=$($K -n "$NS" get sts "$w" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  [ -z "$R" ] && continue
  if [ "$R" -lt 2 ]; then
    gap "$w 복제본 손실" "replicas=$R — 죽이면 그냥 정지다. 3중화 후에 의미가 생긴다"
  else
    printf "  ${BLUE}[READY]${NC} %-26s replicas=%s — 브로커/노드 손실 시험 가능\n" "$w" "$R"
  fi
done
echo ""
echo "  ── DB 복제 (§13-2 미구성) ──"
gap "PostgreSQL 페일오버" "스트리밍 복제·자동 승격 미구성 — CloudNativePG 도입 후"
gap "MariaDB Galera"      "wsrep 미구성"
gap "MongoDB replica set" "replSet 미구성"
echo ""
echo "  이 목록이 비어야 'HA 검증 완료' 라고 말할 수 있다."
echo "  현재 상태와 계획: docs/LOCAL-DEPLOYMENT.md §11 · §12 · §13"
