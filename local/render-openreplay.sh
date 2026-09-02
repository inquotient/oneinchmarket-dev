#!/usr/bin/env bash
# OpenReplay 매니페스트 생성기.
#
# 왜 렌더해서 커밋하는가 —
#   ① 이 레포는 배포 시점에 Helm 을 쓰지 않는다(ADR-003). Tetragon 과 같은
#      방식으로 `helm template` 은 **생성 도구**로만 쓴다.
#   ② 차트가 워크로드 20종의 requests·limits 를 **하나도 선언하지 않는다.**
#      limits 없는 파드를 이미 111% 인 노드에 올리면 무한정 먹는다.
#      여기서 주입한다.
#   ③ 레포 규약 라벨(part-of·component)도 차트가 붙이지 않는다.
#
# 재생성: bash local/render-openreplay.sh
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OPENREPLAY_SRC:-/tmp/or-tar/openreplay-main/scripts/helmcharts}"
OUT="$REPO/kubernetes/overlays/local/openreplay/openreplay.yaml"

[ -d "$SRC/openreplay" ] || { echo "차트가 없다: $SRC" >&2; exit 1; }

helm template openreplay "$SRC/openreplay" \
  -f "$SRC/vars.yaml" \
  -f "$REPO/local/openreplay-values.yaml" \
  --namespace local > /tmp/or-raw.yaml

python3 - "$OUT" <<'PY'
import sys, yaml
out = sys.argv[1]
# 차트가 자원을 선언하지 않는다. 역할에 따라 보수적으로 준다.
BIG   = {"chalice", "api", "assist", "spot"}        # 파이썬/무거운 쪽
SMALL = {"alerts", "heuristics", "sourcemapreader"} # 경량 워커
def res(name):
    if name in BIG:   return {"requests": {"cpu": "50m", "memory": "256Mi"},
                              "limits":   {"cpu": "1",   "memory": "768Mi"}}
    if name in SMALL: return {"requests": {"cpu": "20m", "memory": "64Mi"},
                              "limits":   {"cpu": "300m","memory": "192Mi"}}
    return {"requests": {"cpu": "25m", "memory": "128Mi"},
            "limits":   {"cpu": "500m","memory": "384Mi"}}

docs=[]
for d in yaml.safe_load_all(open('/tmp/or-raw.yaml')):
    if not d: continue
    d.setdefault('metadata', {}).setdefault('labels', {}).update({
        'app.kubernetes.io/part-of': 'oneinchmarket',
        'app.kubernetes.io/component': 'observability',
    })
    k = d.get('kind')
    spec = None
    if k in ('Deployment','StatefulSet','DaemonSet','Job'):
        spec = d['spec']['template']['spec']
        d['spec']['template'].setdefault('metadata', {}).setdefault('labels', {}).update({
            'app.kubernetes.io/part-of': 'oneinchmarket',
            'app.kubernetes.io/component': 'observability',
        })
    elif k == 'CronJob':
        spec = d['spec']['jobTemplate']['spec']['template']['spec']
    if spec:
        for c in spec.get('containers', []) + spec.get('initContainers', []):
            if not c.get('resources'):
                c['resources'] = res(c.get('name',''))
    docs.append(d)
with open(out, 'w', encoding='utf-8') as f:
    f.write("# 생성 파일 — 직접 고치지 말 것. local/render-openreplay.sh 가 만든다.\n")
    yaml.safe_dump_all(docs, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print(f"  {out} — 오브젝트 {len(docs)}개")
PY
