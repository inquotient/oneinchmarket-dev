#!/usr/bin/env python3
"""OpenMeter 렌더 후처리 — 레포 규약을 주입한다.

차트가 붙이지 않는 것을 여기서 넣는다:
  · 규약 라벨(part-of · component · managed-by)
  · securityContext(runAsNonRoot · seccomp · APE false · drop ALL)

★ 전용 ServiceAccount 는 차트가 이미 만든다(`openmeter`). ambient 에서
  ServiceAccount 는 곧 신원이므로 그것을 AuthorizationPolicy 에서 쓴다.
"""
import sys, pathlib, yaml

OUT = pathlib.Path(sys.argv[1])
docs = [d for d in yaml.safe_load_all(open("/tmp/om-raw.yaml", encoding="utf-8")) if d]

# ★ 기존 키를 덮지 않는다. 차트는 `app.kubernetes.io/component` 를
# 컴포넌트 구분(api·sink-worker…)에 쓰고 **Deployment selector 가 그것을
# 참조한다.** 덮어쓰면 `selector does not match template labels` 로 거부된다.
LABELS = {
    "app.kubernetes.io/part-of": "oneinchmarket",
    "app.kubernetes.io/component": "billing",
    "app.kubernetes.io/managed-by": "kustomize",
}
POD_SC = {
    "runAsNonRoot": True,
    "runAsUser": 1000,
    "runAsGroup": 1000,
    "seccompProfile": {"type": "RuntimeDefault"},
}
CTR_SC = {
    "allowPrivilegeEscalation": False,
    "capabilities": {"drop": ["ALL"]},
}


# ★ 비밀번호 치환 — ranger-usersync 와 같은 패턴이다.
#   차트에는 extraEnv 도 secret 마운트도 없고, 환경변수 오버라이드도 먹지
#   않는다(OPENMETER_AGGREGATION_CLICKHOUSE_PASSWORD 등 4가지 표기법을
#   실측했으나 전부 무시됐다). 설정 파일이 유일한 경로다.
#   ConfigMap 에 평문 비밀번호를 두지 않기 위해, 기동 시 initContainer 가
#   Secret 에서 읽어 emptyDir 로 치환해 내보내고 본 컨테이너는 그것을 읽는다.
INIT_IMAGE = "busybox:1.36"
SECRET_NAME = "clickhouse-secret"
SECRET_KEY = "openmeter-password"
SECRET_KEY_PG = "openmeter-pg-password"
SECRET_NAME_REDIS = "redis-secret"
SECRET_KEY_REDIS = "redis-password"
SECRET_NAME_REDIS = "redis-secret"
SECRET_KEY_REDIS = "redis-password"


def inject_secret_substitution(spec):
    """ConfigMap 의 config.yaml 을 치환해 emptyDir 로 내보내는 initContainer 를 넣는다."""
    vols = spec.setdefault("volumes", [])
    names = {v.get("name") for v in vols}
    # 차트가 만든 config 볼륨(ConfigMap)을 찾는다
    src = next((v for v in vols if v.get("configMap")), None)
    if src is None:
        return False
    if "config-rendered" not in names:
        vols.append({"name": "config-rendered", "emptyDir": {}})

    # 본 컨테이너의 config 마운트를 emptyDir 로 돌린다
    mount_path = None
    for c in spec.get("containers", []):
        for m in c.get("volumeMounts", []) or []:
            if m.get("name") == src["name"]:
                mount_path = m.get("mountPath")
                m["name"] = "config-rendered"
    if mount_path is None:
        return False

    inits = spec.setdefault("initContainers", [])
    if any(c.get("name") == "render-config" for c in inits):
        return True
    inits.insert(0, {
        "name": "render-config",
        "image": INIT_IMAGE,
        "command": ["/bin/sh", "-c"],
        "args": ["""set -eu
sed -e "s|__CLICKHOUSE_PASSWORD__|${CLICKHOUSE_PASSWORD}|" \
    -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|" \
    -e "s|__REDIS_PASSWORD__|${REDIS_PASSWORD}|" \
    /src/config.yaml > /out/config.yaml
if grep -qE '__(CLICKHOUSE|POSTGRES|REDIS)_PASSWORD__' /out/config.yaml; then
  echo '[render-config] 치환 실패 — 자리표시자가 남았다.' >&2
  echo '[render-config] 그대로 기동하면 인증이 실패한다.' >&2
  exit 1
fi
echo '[render-config] 완료'
"""],
        "env": [{
            "name": "CLICKHOUSE_PASSWORD",
            "valueFrom": {"secretKeyRef": {"name": SECRET_NAME, "key": SECRET_KEY}},
        }, {
            "name": "POSTGRES_PASSWORD",
            "valueFrom": {"secretKeyRef": {"name": SECRET_NAME, "key": SECRET_KEY_PG}},
        }, {
            "name": "REDIS_PASSWORD",
            "valueFrom": {"secretKeyRef": {"name": SECRET_NAME_REDIS, "key": SECRET_KEY_REDIS}},
        }],
        "securityContext": {**CTR_SC},
        "resources": {
            "requests": {"cpu": "10m", "memory": "16Mi"},
            "limits": {"cpu": "100m", "memory": "64Mi"},
        },
        "volumeMounts": [
            {"name": src["name"], "mountPath": "/src", "readOnly": True},
            {"name": "config-rendered", "mountPath": "/out"},
        ],
    })
    return True


def podspec(d):
    k = d.get("kind")
    if k in ("Deployment", "StatefulSet", "DaemonSet"):
        return d["spec"]["template"]
    if k == "CronJob":
        return d["spec"]["jobTemplate"]["spec"]["template"]
    if k == "Job":
        return d["spec"]["template"]
    return None


n_sc = 0
for d in docs:
    ml = d.setdefault("metadata", {}).setdefault("labels", {})
    for k, v in LABELS.items():
        ml.setdefault(k, v)
    t = podspec(d)
    if not t:
        continue
    tl = t.setdefault("metadata", {}).setdefault("labels", {})
    for k, v in LABELS.items():
        tl.setdefault(k, v)
    spec = t["spec"]
    spec["securityContext"] = {**(spec.get("securityContext") or {}), **POD_SC}
    inject_secret_substitution(spec)
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        c["securityContext"] = {**(c.get("securityContext") or {}), **CTR_SC}
        n_sc += 1

with open(OUT, "w", encoding="utf-8", newline="\n") as f:
    f.write(
        "# ─────────────────────────────────────────────────────────────────\n"
        "# OpenMeter — API 과금 계량 백엔드. **생성 파일이다. 직접 고치지 말 것.**\n"
        "#   bash local/render-openmeter.sh\n"
        "# 값은 local/openmeter-values.yaml 에 있다.\n"
        "# ─────────────────────────────────────────────────────────────────\n"
    )
    yaml.safe_dump_all(docs, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"문서 {len(docs)}개 · securityContext 주입 {n_sc}개 컨테이너")
