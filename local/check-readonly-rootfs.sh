#!/usr/bin/env bash
# readOnlyRootFilesystem 을 켜도 되는 컨테이너를 **측정으로** 가른다
#
# ★★ 왜 필요한가 — Trivy 가 KSV-0014 로 312건을 지적하지만(§8-97), 켜면
#   조용히 깨지는 것이 있다. 이 레포에 실제 사례가 있다: Dependency-Track
#   프런트의 엔트리포인트가 자기 static 디렉터리의 config.json 을 제자리에서
#   고치는데, readOnlyRootFilesystem 이면 그 touch 가 실패하고 **환경변수를
#   통째로 버린다.** 파드는 Ready 이고 로그는 info 한 줄뿐이다(Gotcha 48).
#
# ★ 그래서 추측하지 않는다. 도는 컨테이너에 직접 물어본다:
#     find / -xdev -newer /etc/hostname
#   `-xdev` 가 마운트된 볼륨(다른 디바이스)을 빼주므로 **순수 rootfs 쓰기만**
#   남는다. 0건이면 켜도 안전하고, 그렇지 않으면 그 경로들이 emptyDir 로
#   빠져야 한다는 뜻이다.
#
# ★★★ **가장 중요한 한계 — 기동 중의 쓰기는 놓친다.**
#   기준 파일(/etc/hostname)이 기동 순간에 써지므로, 엔트리포인트가
#   거의 동시에 고친 파일은 `-newer` 에 걸리지 않는다.
#   ★ 실제 반례가 있다 — **dependency-track-frontend 는 이 검사에서
#   '쓰기 0건'으로 나오지만 실제로는 깨진다.** 그 엔트리포인트가
#   자기 static 디렉터리의 config.json 을 기동 시 제자리에서 고치고,
#   실패하면 환경변수를 통째로 버리면서도 파드는 Ready 다(Gotcha 48).
#   즉 **이 목록은 후보이지 보증이 아니다.** 켜본 뒤 기동 로그와
#   설정 반영 여부를 반드시 확인할 것 — 파드 상태만으로는 모른다.
#
# ★★ 또 하나 — 이것은 **기동 이후 지금까지** 쓴 것이다.
#   드물게 도는 경로(주기 작업·오류 처리·종료 훅)는 잡히지 않는다.
#   그래서 켠 뒤에도 재시작·CrashLoop 을 확인해야 한다.
#   실측 예: caldera 는 /usr/src/app/conf/local.yml 을, hive-server 는
#   /opt/hive/conf/hiveserver2.pid 를 쓴다 — 둘 다 "안전해 보이는" 후보였다.
#
# 사용
#   local/check-readonly-rootfs.sh            # local 네임스페이스 전체
#   local/check-readonly-rootfs.sh argocd     # 다른 네임스페이스
set -Eeuo pipefail
NS="${1:-local}"
log() { echo "[rofs] $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/probe.sh" <<'INNER'
# ★★ kubelet 이 관리하는 경로를 반드시 뺀다 — 빼지 않으면 **거의 모든
#   컨테이너가 '쓴다' 로 나온다.** /etc/hosts · /etc/hostname · /etc/resolv.conf ·
#   SA 토큰은 kubelet 이 바인드 마운트하므로 readOnlyRootFilesystem 과
#   **무관하게** 쓰기 가능하다. 빼기 전에는 kafka·grafana·hbase 등이
#   전부 NO 로 나왔다 — 측정이 아니라 소음이었다.
# ★ 디렉터리는 세지 않는다 — 위 파일 하나 때문에 부모 디렉터리 mtime 이
#   바뀌어 /etc · / 가 항상 따라나온다.
find / -xdev -newer /etc/hostname -type f 2>/dev/null \
  | grep -vE '^/(proc|sys|dev)/' \
  | grep -vE '^/etc/(hosts|hostname|resolv[.]conf)$' \
  | grep -vE '^/run/secrets/kubernetes[.]io/' \
  | grep -vE '^/tmp/probe[.]sh$' \
  | head -30
INNER

log "네임스페이스 $NS 의 실행 중인 컨테이너를 훑는다"
kubectl -n "$NS" get pod -o json > "$WORK/pods.json"

python3 - "$WORK" "$NS" <<'PY' > "$WORK/targets.txt"
import json, sys
W, NS = sys.argv[1], sys.argv[2]
d = json.load(open(W + "/pods.json"))
seen = set()
for p in d["items"]:
    if p["status"].get("phase") != "Running":
        continue
    ready = {c["name"] for c in (p["status"].get("containerStatuses") or []) if c.get("ready")}
    owner = (p["metadata"].get("ownerReferences") or [{}])[0].get("name", p["metadata"]["name"])
    for c in p["spec"]["containers"]:
        if c["name"] not in ready:
            continue
        sc = c.get("securityContext") or {}
        if sc.get("readOnlyRootFilesystem") is True:
            continue
        key = (owner, c["name"])
        if key in seen:
            continue
        seen.add(key)
        print("%s\t%s\t%s" % (p["metadata"]["name"], c["name"], owner))
PY

TOTAL=$(wc -l < "$WORK/targets.txt")
log "대상 $TOTAL 개 (이미 켜진 것과 미실행은 제외)"
echo

SAFE=0; UNSAFE=0; ERR=0
: > "$WORK/safe.txt"; : > "$WORK/unsafe.txt"

while IFS=$'\t' read -r pod cont owner; do
  [ -z "${pod:-}" ] && continue
  if ! kubectl -n "$NS" cp "$WORK/probe.sh" "$NS/$pod:/tmp/probe.sh" -c "$cont" >/dev/null 2>&1; then
    printf "  %-34s %-24s ?  (cp 불가 — 셸이 없을 수 있다)\n" "$owner" "$cont"
    ERR=$((ERR+1)); continue
  fi
  out="$(kubectl -n "$NS" exec "$pod" -c "$cont" -- sh /tmp/probe.sh 2>/dev/null || true)"
  n="$(printf '%s' "$out" | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    printf "  %-34s %-24s OK   쓰기 0건\n" "$owner" "$cont"
    echo "$owner/$cont" >> "$WORK/safe.txt"; SAFE=$((SAFE+1))
  else
    printf "  %-34s %-24s NO   쓰기 %s건: %s\n" "$owner" "$cont" "$n" \
      "$(printf '%s' "$out" | grep -vE '^/$' | head -2 | tr '\n' ' ')"
    echo "$owner/$cont" >> "$WORK/unsafe.txt"; UNSAFE=$((UNSAFE+1))
  fi
done < "$WORK/targets.txt"

echo
log "== 결과 =="
log "  켤 수 있다(쓰기 0건) : $SAFE"
log "  켜면 깨진다          : $UNSAFE"
log "  측정 불가            : $ERR"
echo
log "켤 수 있는 것 목록:"
sort "$WORK/safe.txt" | sed 's/^/     /'
echo
log "★ 켠 뒤에는 반드시 재시작 횟수와 로그를 볼 것 — 이 측정은"
log "  '기동 이후 지금까지' 이지 '앞으로 영원히' 가 아니다."
