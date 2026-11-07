#!/usr/bin/env bash
# Trivy Operator 의 리포트가 **컨테이너 단위로** 빠진 것을 찾고, 원하면 고친 뒤 다시 스캔시킨다.
#
# 왜 필요한가 (Gotcha 221)
#   trivy-operator 0.36.1 은 실패한 스캔 Job 을 **지우기만 하고 워크로드를 다시 큐에 넣지 않는다**
#   (pkg/vulnerabilityreport/controller/scanjob.go — 모든 반환이 ctrl.Result{} 이고 requeue 가 없다.
#   OPERATOR_SCAN_JOB_RETRY_AFTER 는 이 경로에서 쓰이지 않는다). 그래서 원인을 고쳐도 워크로드에
#   변경 이벤트가 오기 전에는 다시 스캔하지 않는다. 실측 2026-11-08: cert-manager 컨트롤러가
#   블롭을 채운 뒤 26분 동안 한 번도 재시도되지 않았다.
#
# ★ 컨테이너 단위로 센다 — init 컨테이너 리포트 하나만 있어도 워크로드 단위로는 "있음" 이고
#   오퍼레이터도 그 워크로드를 끝난 것으로 본다(실측: caldera).
#
# 하는 일
#   (기본·--check)  빠진 (워크로드, 컨테이너) 를 이미지·노드와 함께 출력한다. 고치지 않는다.
#   --fix           ① 그 이미지가 있는 노드마다 `ctr images check` 로 블롭 누락을 보고 있으면
#                     `content fetch` 로 채운다(Gotcha 134 — `images pull` 은 소용없다)
#                   ② 워크로드에 임시 어노테이션을 달아 오퍼레이터에 변경 이벤트를 준다
#                     (메타데이터만 바뀐다 — 파드 템플릿이 아니라 파드는 재시작하지 않는다)
#                   ③ 리포트가 생길 때까지 기다린 뒤 어노테이션을 지운다
#
# ★ 갓 생긴 워크로드(기본 30분 이내)는 아직 큐에 있을 수 있어 "대기" 로 세고 실패로 치지 않는다.
# ★ 크기 초과(kine 2MiB · API 서버 3MiB)는 이것으로 풀리지 않는다 — 그때는 install-operators.sh 의
#   워크로드 단위 ignore 정책을 볼 것. 출력 끝에 최근 크기 초과 오류의 Job 을 함께 보여 준다.
#
# 판정은 셋이다 — 0 빠진 것 없음 · 1 빠진 것 있음 · 2 측정 불가(Gotcha 191).
# 전제: control-plane 에서 root 로 · kubectl · python3 · 다른 노드로 root ssh 키 인증(Gotcha 175).
set -uo pipefail

MODE=check
case "${1:-}" in
  ""|--check) MODE=check ;;
  --fix) MODE=fix ;;
  *) echo "usage: $0 [--check|--fix]" >&2; exit 2 ;;
esac
GRACE_MIN="${GRACE_MIN:-30}"
WAIT_SEC="${WAIT_SEC:-900}"
ANN=oneinchmarket.io/trivy-rescan

command -v kubectl >/dev/null && command -v python3 >/dev/null \
  || { echo "[측정 불가] kubectl·python3 가 없다" >&2; exit 2; }
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

kubectl get vulnerabilityreports -A -o json > "$TMP/reports.json" 2>"$TMP/err" \
  && kubectl get rs,sts,ds -A -o json > "$TMP/wl.json" 2>>"$TMP/err" \
  && kubectl get pods -A -o json > "$TMP/pods.json" 2>>"$TMP/err" \
  && kubectl get nodes -o json > "$TMP/nodes.json" 2>>"$TMP/err" \
  || { echo "[측정 불가] API 조회 실패: $(head -c 300 "$TMP/err")" >&2; exit 2; }

# 출력: ns kind name container image node,node age_min
python3 - "$TMP" > "$TMP/missing.txt" <<'EOF' || { echo "[측정 불가] 분석 실패" >&2; exit 2; }
import json, sys, datetime
d = sys.argv[1]
L = lambda f: json.load(open(f"{d}/{f}"))["items"]
have = set()
for r in L("reports.json"):
    l = r["metadata"].get("labels", {})
    have.add((r["metadata"]["namespace"], l.get("trivy-operator.resource.name"), l.get("trivy-operator.container.name")))
ip = {}
for n in L("nodes.json"):
    for a in n["status"]["addresses"]:
        if a["type"] == "InternalIP": ip[n["metadata"]["name"]] = a["address"]
nodes_of = {}
for p in L("pods.json"):
    nn = p["spec"].get("nodeName")
    for o in p["metadata"].get("ownerReferences", []):
        if nn: nodes_of.setdefault((p["metadata"]["namespace"], o["kind"], o["name"]), set()).add(ip.get(nn, nn))
now = datetime.datetime.now(datetime.timezone.utc)
for o in L("wl.json"):
    k, m = o["kind"], o["metadata"]
    if k == "ReplicaSet" and (o["spec"].get("replicas") or 0) == 0: continue
    age = int((now - datetime.datetime.fromisoformat(m["creationTimestamp"].replace("Z", "+00:00"))).total_seconds() // 60)
    ps = o["spec"]["template"]["spec"]
    nodes = ",".join(sorted(nodes_of.get((m["namespace"], k, m["name"]), []))) or "-"
    for c in ps.get("initContainers", []) + ps["containers"]:
        if (m["namespace"], m["name"], c["name"]) not in have:
            print(m["namespace"], k, m["name"], c["name"], c["image"], nodes, age)
EOF

FAIL=0; PEND=0
while read -r ns kind name ctr img nodes age; do
  if [ "$age" -lt "$GRACE_MIN" ]; then
    echo "[대기] $ns/$kind/$name  $ctr  (${age}분 전 생성 — 아직 큐에 있을 수 있다)"; PEND=$((PEND+1))
  else
    echo "[빠짐] $ns/$kind/$name  $ctr  $img  노드=$nodes"; FAIL=$((FAIL+1))
  fi
done < "$TMP/missing.txt"
echo "빠짐 $FAIL · 대기 $PEND"

SELF_IPS=" $(hostname -I 2>/dev/null) "
on_node() {  # on_node <ip> <명령>
  case "$SELF_IPS" in
    *" $1 "*) sh -c "$2" ;;
    *) ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$1" "$2" ;;
  esac
}

if [ "$MODE" = fix ] && [ "$FAIL" -gt 0 ]; then
  echo "== 블롭 검사(Gotcha 134)"
  awk -v g="$GRACE_MIN" '$7>=g {n=split($6,a,","); for(i=1;i<=n;i++) if(a[i]!="-") print $5, a[i]}' \
    "$TMP/missing.txt" | sort -u > "$TMP/imgnode.txt"
  while read -r img ip; do
    out=$(on_node "$ip" "k3s ctr -n k8s.io images check 'name==$img' 2>&1" </dev/null)
    case "$out" in
      *incomplete*)
        if on_node "$ip" "timeout 900 k3s ctr -n k8s.io content fetch '$img' >/dev/null 2>&1" </dev/null; then
          echo "  채움   $img  ($ip)"
        else
          echo "  ★ 실패 $img  ($ip) — content fetch 가 실패했다(레지스트리 접근을 볼 것)"
        fi ;;
      *complete*) echo "  온전   $img  ($ip)" ;;
      *) echo "  ★ 판정 불가 $img  ($ip): $(printf %s "$out" | head -c 160)" ;;
    esac
  done < "$TMP/imgnode.txt"

  echo "== 재스캔 유도(임시 어노테이션 $ANN)"
  awk -v g="$GRACE_MIN" '$7>=g {print $1, $2, $3}' "$TMP/missing.txt" | sort -u > "$TMP/owners.txt"
  stamp=$(date +%s)
  while read -r ns kind name; do
    if kubectl -n "$ns" annotate "$kind" "$name" "$ANN=$stamp" --overwrite >/dev/null; then
      echo "  $ns/$kind/$name"
    else
      echo "  ★ 어노테이션 실패 $ns/$kind/$name"
    fi
  done < "$TMP/owners.txt"

  echo "== 리포트 대기(최대 ${WAIT_SEC}초)"
  end=$(( $(date +%s) + WAIT_SEC ))
  while :; do
    left=0
    while read -r ns kind name ctr img nodes age; do
      [ "$age" -lt "$GRACE_MIN" ] && continue
      n=$(kubectl -n "$ns" get vulnerabilityreports \
            -l "trivy-operator.resource.name=$name,trivy-operator.container.name=$ctr" \
            --no-headers 2>/dev/null | wc -l)
      [ "$n" -ge 1 ] || left=$((left+1))
    done < "$TMP/missing.txt"
    [ "$left" -eq 0 ] && break
    [ "$(date +%s)" -ge "$end" ] && break
    sleep 20
  done
  while read -r ns kind name; do
    kubectl -n "$ns" annotate "$kind" "$name" "$ANN-" >/dev/null 2>&1
  done < "$TMP/owners.txt"
  echo "남은 빠짐 $left (어노테이션은 지웠다)"
  FAIL=$left
fi

big=$(kubectl -n trivy-system logs deploy/trivy-operator --since=1h 2>/dev/null \
        | grep -E 'larger than max|Request entity too large' \
        | grep -oE '"name":"scan-vulnerabilityreport-[a-z0-9]+"' | sort -u | tr '\n' ' ')
[ -n "$big" ] && echo "★ 최근 1시간 크기 초과 Job: $big— 위 빠짐 목록에 남아 있으면 재스캔으로는 풀리지 않는다(ignore 정책을 볼 것). 목록에 없으면 이미 풀린 것이다"

echo "★ 이것이 재지 못하는 것: CronJob·단독 파드의 리포트, 리포트 내용이 옳은지."
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
