#!/usr/bin/env bash
# 7-4: 비밀번호 로테이션 dry-run + 의존관계 연쇄 재시작 검증
# 실행: ./04-rotation-dryrun.sh [namespace]
#
# ★★★ 2026-10-09: 이 스크립트는 셋으로 고장나 있었다.
#   ① exit 문이 아예 없어 무엇을 발견해도 0 을 돌려줬다 — run-all.sh 가 그것을
#      "통과" 로 집계했다(거짓 통과, Gotcha 191 과 같은 부류).
#   ② 모든 kubectl 호출에 네임스페이스를 넘기지 않아 현재 컨텍스트의 기본
#      네임스페이스를 봤다. run-all.sh 는 이미 인자로 넘겨 주고 있었다 —
#      실측에서 CronJob·Secret 이 전부 MISS 로 나온 이유가 이것이다.
#   ③ §4 가 워크로드 목록을 JSON 텍스트에서 긁었다. 컨테이너·포트·볼륨의
#      name 까지 걸리므로 결과가 워크로드 112개가 아니라 고유 name 699개였고
#      590개에 "annotation missing" 을 찍었다. 게다가 클러스터가 없으면 그
#      grep 이 rc=1 이라 set -e 가 거기서 스크립트를 끝냈다 — 거짓 실패다.
#
# 판정은 셋이다: 0 통과 · 1 실패 · 2 측정 불가.
# ★ 측정 불가를 통과로 접지 않는다. 클러스터나 네임스페이스를 읽을 수 없으면
#   모든 항목이 MISS 로 보이는데 그것은 "없다" 가 아니라 "못 봤다" 다.
#   그래서 §0 에 장치 대조군을 둔다.

set -euo pipefail

FAILED=0
WARNED=0
UNMEASURED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 네임스페이스: 인자가 없으면 현재 컨텍스트에서 읽는다.
# ★ 하드코딩하지 않는다 — 05 는 dev·prod 를 박아 두어 없는 네임스페이스를
#   보고 있었고, 그래서 PolicyReport 를 한 번도 읽지 못했다.
NAMESPACE="${1:-}"
if [ -z "$NAMESPACE" ]; then
  NAMESPACE="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  [ -n "$NAMESPACE" ] || NAMESPACE=default
fi

echo "============================================"
echo "  로테이션 Dry-Run 검증 (ns=${NAMESPACE})"
echo "============================================"
echo ""

echo "=== 0. 측정 장치 확인 ==="
if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} 클러스터에 닿지 못한다 — 모든 항목이 MISS 로 보이지만 그것은 없다는 뜻이 아니다\n"
  exit 2
fi
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} 네임스페이스 %s 가 없다 — 대상을 잘못 보고 있다\n" "$NAMESPACE"
  exit 2
fi
printf "${GREEN}[OK]${NC}   클러스터·네임스페이스 %s 를 읽을 수 있다\n" "$NAMESPACE"
echo ""

echo "=== 1. 로테이션 CronJob 존재·가동 확인 ==="
# ★ Elasticsearch 항목은 2026-09-11 에 걷어냈다 — 엔진을 OpenSearch 로 바꾸며
#   rotate-elasticsearch-password 와 elasticsearch-secret 을 함께 지웠다.
#   그래서 검색 계층의 비밀번호 로테이션은 지금 없다 — 커버리지 회귀이고
#   숨기지 않고 적어 둔다. 바로 만들지 않은 이유: OpenSearch 의 자격은
#   StatefulSet 의 initContainer 가 internal_users.yml 로 굽는다. Secret 만
#   바꾸면 반영되지 않는다(LOCAL-DEPLOYMENT §9-17 에 복귀 조건이 있다).
CRONJOBS=(
  "rotate-postgresql-password"
  "rotate-mariadb-password"
  "rotate-mongodb-password"
  "rotate-redis-password"
  "rotate-minio-password"
  "rotate-admin-passwords"
  "rotation-git-sync"
)

for cj in "${CRONJOBS[@]}"; do
  if INFO=$(kubectl get cronjob "$cj" -n "$NAMESPACE" -o go-template='{{.spec.schedule}}{{"|"}}{{if .spec.suspend}}true{{else}}false{{end}}' 2>/dev/null); then
    SCHEDULE="${INFO%%|*}"
    SUSPEND="${INFO##*|}"
    # ★★ 존재만 보던 것이 결함이었다 — suspend 가 true 인 로테이션 CronJob 은
    #   조용한 비-로테이션이다. 오브젝트는 있고 아무 일도 하지 않는다.
    if [ "$SUSPEND" = true ]; then
      printf "${RED}[FAIL]${NC} %-35s suspend: true — 존재하지만 돌지 않는다\n" "$cj"
      FAILED=$((FAILED + 1))
    else
      printf "${GREEN}[OK]${NC}   %-35s schedule: %s\n" "$cj" "$SCHEDULE"
    fi
  else
    printf "${RED}[FAIL]${NC} %-35s 없다\n" "$cj"
    FAILED=$((FAILED + 1))
  fi
done
echo ""
echo "=== 2. 대상 Secret 존재 확인 ==="
# ★★ 값은 보지 않는다. 이 레포 규약이다 — 키 이름만 읽는다. 옛 판은
#   jsonpath '{.data}' 를 받아 grep 으로 키를 뽑았는데, 그러면 값이 담긴
#   문자열이 셸 변수에 한 번 들어온다. go-template 으로 키만 찍는다.
SECRETS=(
  "postgresql-secret"
  "mariadb-secret"
  "mongodb-secret"
  "redis-secret"
  "minio-secret"
  "keycloak-secret"
  "gitlab-secret"
)

for secret in "${SECRETS[@]}"; do
  if KEYS=$(kubectl get secret "$secret" -n "$NAMESPACE" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>/dev/null); then
    NKEY=$(printf '%s\n' "$KEYS" | wc -w | tr -d ' ')
    printf "${GREEN}[OK]${NC}   %-22s 키 %s개: %s\n" "$secret" "$NKEY" "$KEYS"
  else
    printf "${RED}[FAIL]${NC} %-22s 없다\n" "$secret"
    FAILED=$((FAILED + 1))
  fi
done
echo ""

echo "=== 3. secret-rotator RBAC 확인 ==="
if kubectl get sa secret-rotator -n "$NAMESPACE" >/dev/null 2>&1; then
  printf "${GREEN}[OK]${NC}   ServiceAccount: secret-rotator\n"
else
  printf "${RED}[FAIL]${NC} ServiceAccount: secret-rotator 가 없다 — CronJob 이 Secret 을 고치지 못한다\n"
  FAILED=$((FAILED + 1))
fi
if VERBS=$(kubectl get role secret-rotator -n "$NAMESPACE" -o go-template='{{range .rules}}{{.verbs}}{{end}}' 2>/dev/null); then
  printf "${GREEN}[OK]${NC}   Role: secret-rotator (verbs: %s)\n" "$VERBS"
else
  printf "${RED}[FAIL]${NC} Role: secret-rotator 가 없다\n"
  FAILED=$((FAILED + 1))
fi
echo ""

echo "=== 4. Reloader 커버리지 ==="
# ★★★ 옛 판은 "모든 이름에 어노테이션이 있는가" 를 물었다. 질문이 틀렸고
#   이름 목록도 틀렸다. 바른 질문은 하나다:
#     로테이션 Secret 을 참조하는 워크로드 중 최상위 어노테이션을 가진 것은?
#   Reloader 는 최상위 metadata.annotations 만 본다(Gotcha 84). 그리고 scoped
#   모드라 local 네임스페이스만 본다 — 다른 곳에 붙여도 아무 일도 없다.
# ★ 실측(2026-10-09, local): 워크로드 112 · 참조 43 · 어노테이션 있음 43.
#   Gotcha 84 의 "41개 중 20개" 는 그 시점의 값이고 지금은 메워졌다.
if ! command -v jq >/dev/null 2>&1; then
  printf "${BLUE}[측정 불가]${NC} jq 가 없다 — 참조 관계를 정확히 셀 수 없다. 추정으로 적지 않는다\n"
  UNMEASURED=$((UNMEASURED + 1))
else
  ROT_JSON=$(printf '%s\n' "${SECRETS[@]}" | jq -R . | jq -sc .)
  COV=$(kubectl get deployments,statefulsets -n "$NAMESPACE" -o json 2>/dev/null | jq -r --argjson rot "$ROT_JSON" '
    .items[]
    | (.metadata.annotations["reloader.stakater.com/auto"] // "-") as $a
    | ([ (.spec.template.spec.volumes // [])[] | .secret.secretName // empty ]
       + [ (.spec.template.spec.containers // [])[], (.spec.template.spec.initContainers // [])[] | (.env // [])[] | .valueFrom.secretKeyRef.name // empty ]
       + [ (.spec.template.spec.containers // [])[], (.spec.template.spec.initContainers // [])[] | (.envFrom // [])[] | .secretRef.name // empty ]
       | unique) as $s
    | ($s - ($s - $rot)) as $hit
    | select(($hit | length) > 0)
    | [(.kind // "?"), .metadata.name, $a, ($hit | join(","))] | @tsv' 2>/dev/null || true)
  if [ -z "$COV" ]; then
    printf "${BLUE}[측정 불가]${NC} 워크로드를 읽지 못했다\n"
    UNMEASURED=$((UNMEASURED + 1))
  else
    TOTAL_WL=$(kubectl get deployments,statefulsets -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    NREF=$(printf '%s\n' "$COV" | grep -c . || true)
    NYES=$(printf '%s\n' "$COV" | awk -F'\t' '$3=="true"' | grep -c . || true)
    NNO=$((NREF - NYES))
    printf "  워크로드 %s개 중 로테이션 Secret 을 참조하는 것 %s개\n" "$TOTAL_WL" "$NREF"
    printf "${GREEN}[OK]${NC}   최상위 reloader.stakater.com/auto 가 true — %s개\n" "$NYES"
    if [ "$NNO" -gt 0 ]; then
      # ★ 실패로 세지 않는다. 상류 차트가 붙이지 않는 경우가 있어 빨간불이
      #   상수가 되면 사람이 배경으로 읽는다(Gotcha 73·90). 숫자로 보고한다 —
      #   비밀번호가 바뀌어도 이 워크로드는 모른다.
      printf "${YELLOW}[WARN]${NC} 어노테이션 없음 — %s개 (비밀번호가 바뀌어도 재시작하지 않는다)\n" "$NNO"
      printf '%s\n' "$COV" | awk -F'\t' '$3!="true" {printf "         %-34s (%s)\n", $2, $4}'
      WARNED=$((WARNED + NNO))
    fi
  fi
fi
echo ""
echo "=== 5. 의존관계 연쇄 재시작 맵 (참고) ==="
# ★ 이것은 측정이 아니다 — 손으로 적은 문서다. 옛 판은 이것을 다른 절과 같은
#   모양으로 출력해서 검증한 것처럼 보였다. 참고라고 적는다.
echo "  아래는 설계 문서이고 이 스크립트가 확인한 것이 아니다"
cat << 'DEPMAP'
  PostgreSQL 비번 변경
  ├── keycloak-secret → Keycloak 재시작
  ├── hive-metastore-secret → Hive Metastore 재시작
  ├── apicurio-secret → Apicurio 재시작
  └── gitlab-secret → GitLab 재시작

  MariaDB 비번 변경
  ├── admin-secret → Admin 재시작
  └── cmmn-api-secret → CMMN-API 재시작

  MongoDB 비번 변경
  └── (application 직접 참조)

  Redis 비번 변경
  └── keycloak-secret → Keycloak 재시작

  (OpenSearch 는 로테이션이 없다 — §1 의 주석 참조)

  MinIO 비번 변경
  ├── trino → Trino 재시작
  └── hive-metastore → Hive Metastore 재시작
DEPMAP
echo ""

echo "============================================"
echo "  로테이션 검증 결과"
echo "============================================"
printf "  실패: %d\n" "$FAILED"
printf "  경고: %d (커버리지 숫자 — 실패로 세지 않는다)\n" "$WARNED"
printf "  측정 불가: %d\n" "$UNMEASURED"
echo "============================================"
if [ "$FAILED" -gt 0 ]; then
  printf "  판정: ${RED}실패${NC}\n"
  exit 1
fi
if [ "$UNMEASURED" -gt 0 ]; then
  printf "  판정: ${BLUE}측정 불가${NC} — 통과로 접지 않는다\n"
  exit 2
fi
printf "  판정: ${GREEN}통과${NC} (경고 %d건)\n" "$WARNED"
