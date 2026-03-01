#!/usr/bin/env bash
# 7-4: 비밀번호 로테이션 dry-run + 의존관계 연쇄 재시작 검증
# 사전 조건: kubectl (클러스터 연결 상태)
# 실행: ./04-rotation-dryrun.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  로테이션 Dry-Run 검증"
echo "============================================"
echo ""

# 1. CronJob 존재 확인
echo "=== 1. 로테이션 CronJob 존재 확인 ==="
CRONJOBS=(
  "rotate-postgresql-password"
  "rotate-mariadb-password"
  "rotate-mongodb-password"
  "rotate-redis-password"
  "rotate-elasticsearch-password"
  "rotate-minio-password"
  "rotate-admin-passwords"
  "rotation-git-sync"
)

for cj in "${CRONJOBS[@]}"; do
  if kubectl get cronjob "$cj" > /dev/null 2>&1; then
    SCHEDULE=$(kubectl get cronjob "$cj" -o jsonpath='{.spec.schedule}')
    printf "${GREEN}[OK]${NC}   %-35s schedule: %s\n" "$cj" "$SCHEDULE"
  else
    printf "${RED}[MISS]${NC} %-35s NOT FOUND\n" "$cj"
  fi
done

echo ""

# 2. Secret 존재 확인
echo "=== 2. 대상 Secret 존재 확인 ==="
SECRETS=(
  "postgresql-secret"
  "mariadb-secret"
  "mongodb-secret"
  "redis-secret"
  "elasticsearch-secret"
  "minio-secret"
  "keycloak-secret"
  "gitlab-secret"
)

for secret in "${SECRETS[@]}"; do
  if kubectl get secret "$secret" > /dev/null 2>&1; then
    KEYS=$(kubectl get secret "$secret" -o jsonpath='{.data}' | grep -o '"[^"]*":' | tr -d '":' | tr '\n' ', ')
    printf "${GREEN}[OK]${NC}   %-25s keys: %s\n" "$secret" "$KEYS"
  else
    printf "${RED}[MISS]${NC} %-25s NOT FOUND\n" "$secret"
  fi
done

echo ""

# 3. ServiceAccount + RBAC 확인
echo "=== 3. secret-rotator RBAC 확인 ==="
if kubectl get sa secret-rotator > /dev/null 2>&1; then
  printf "${GREEN}[OK]${NC}   ServiceAccount: secret-rotator\n"
else
  printf "${RED}[MISS]${NC} ServiceAccount: secret-rotator NOT FOUND\n"
fi

if kubectl get role secret-rotator > /dev/null 2>&1; then
  VERBS=$(kubectl get role secret-rotator -o jsonpath='{.rules[0].verbs}')
  printf "${GREEN}[OK]${NC}   Role: secret-rotator (verbs: %s)\n" "$VERBS"
else
  printf "${RED}[MISS]${NC} Role: secret-rotator NOT FOUND\n"
fi

echo ""

# 4. Reloader 어노테이션 확인
echo "=== 4. Stakater Reloader 어노테이션 확인 ==="
WORKLOADS=$(kubectl get statefulsets,deployments -o json 2>/dev/null \
  | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//' | sort -u)

for wl in $WORKLOADS; do
  ANNO=$(kubectl get statefulset "$wl" -o jsonpath='{.metadata.annotations.reloader\.stakater\.com/auto}' 2>/dev/null || \
    kubectl get deployment "$wl" -o jsonpath='{.metadata.annotations.reloader\.stakater\.com/auto}' 2>/dev/null || echo "")
  if [ "$ANNO" = "true" ]; then
    printf "${GREEN}[OK]${NC}   %-25s reloader.stakater.com/auto: true\n" "$wl"
  else
    printf "${YELLOW}[WARN]${NC} %-25s reloader annotation missing\n" "$wl"
  fi
done

echo ""

# 5. 의존관계 연쇄 재시작 시뮬레이션
echo "=== 5. 의존관계 연쇄 재시작 맵 ==="
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

  Elasticsearch 비번 변경
  ├── kibana → Kibana 재시작
  ├── logstash → Logstash 재시작
  └── filebeat → Filebeat 재시작

  MinIO 비번 변경
  ├── trino → Trino 재시작
  └── hive-metastore → Hive Metastore 재시작
DEPMAP

echo ""
echo "============================================"
echo "  검증 완료"
echo "============================================"
