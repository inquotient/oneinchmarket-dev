#!/usr/bin/env python3
"""렌더가 요구하는 Secret·ConfigMap 키가 클러스터에 실제로 있는지 전수 검사한다.

왜 있는가
---------
`create-secrets.sh` 의 `mk` 는 오래도록 "Secret 이 있으면 통째로 건너뛴다" 였다.
그래서 **나중에 더한 키가 영원히 빠졌고 아무도 알려 주지 않았다.** 2026-10-05
베어메탈 첫 구축에서 이 검사를 처음 돌려 보니 필수 참조 91건 중 **12건**이
비어 있었다 — 키 없음 8건(clickhouse·ranger·ds389·keycloak) + 오브젝트 없음 4건.

증상이 원인을 가리키지 않는다
-----------------------------
파드는 `Init:CreateContainerConfigError` 로만 보이고, `kubectl get pods` 로는
어느 키가 없는지 알 수 없다. 이벤트를 읽어야 비로소
`couldn't find key <키> in Secret local/<이름>` 이 나온다. 그리고 그 파드가
wave 0 에 있으면 **동기화가 그 자리에서 영원히 선다**(Gotcha 58).

사용
----
    python3 local/check-secret-refs.py              # 렌더를 직접 만들어 검사
    kubectl kustomize kubernetes/overlays/local | python3 local/check-secret-refs.py -
    python3 local/check-secret-refs.py --check      # 결함이 있으면 exit 1 (게이트)

★ `optional: true` 인 참조는 세지 않는다 — 없어도 되는 것을 결함으로 세면
  빨간불이 상수가 되고 사람이 배경으로 읽는다(Gotcha 73·90 과 같은 구조).
★ 아래 EXTERNAL 은 **이 레포가 만들 수 없는** 자격이다. 원천이 밖에 있다는
  사실 자체를 적어 둔다 — 빠뜨리면 "왜 안 되지" 가 되고, 결함으로 세면
  달성할 수 없는 게이트가 된다. 전체 목록은 LOCAL-DEPLOYMENT §25-0.
"""
import argparse
import json
import re
import subprocess
import sys

# 이 레포 밖이 원천인 것 — 해당 도구를 돌려야 생긴다
EXTERNAL = {
    "gitlab-runner-token": "GitLab 이 발급한다 (local/gitlab-runner-register.sh)",
    "openbao-keys": "openbao-init.sh 가 봉인 해제 키를 넣는다",
    "gitlab-registry-secret": "gitlab-registry-bootstrap.sh --secret (Gotcha 118)",
}

REF_RE = re.compile(r"^(\s*)(secretKeyRef|configMapKeyRef):\s*$")
KV_RE = re.compile(r"^(\s*)([A-Za-z]+):\s*(.*)$")


def collect_refs(lines):
    """YAML 파서 없이 들여쓰기로 참조 블록을 모은다.

    파서를 쓰지 않는 이유: 이 검사는 클러스터 노드에서도 돌아야 하고
    거기에 PyYAML 이 있다고 가정할 수 없다.
    """
    refs = set()
    i = 0
    while i < len(lines):
        m = REF_RE.match(lines[i])
        if not m:
            i += 1
            continue
        base, kind = len(m.group(1)), m.group(2)
        name = key = None
        optional = False
        j = i + 1
        while j < len(lines):
            m2 = KV_RE.match(lines[j])
            if not m2 or len(m2.group(1)) <= base:
                break
            k, v = m2.group(2), m2.group(3).strip().strip("\"'")
            if k == "name":
                name = v
            elif k == "key":
                key = v
            elif k == "optional":
                optional = v == "true"
            j += 1
        if name and key and not optional:
            refs.add((kind, name, key))
        i = j
    return refs


def cluster_keys(kind, ns):
    out = subprocess.run(
        ["kubectl", "-n", ns, "get", kind, "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"[check-secret-refs] kubectl get {kind} 실패: {out.stderr.strip()}",
              file=sys.stderr)
        sys.exit(2)
    data = json.loads(out.stdout) if out.stdout.strip() else {"items": []}
    return {
        it["metadata"]["name"]:
            set((it.get("data") or {}).keys()) | set((it.get("stringData") or {}).keys())
        for it in data["items"]
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("render", nargs="?", default=None,
                    help="렌더 파일 경로. '-' 면 표준입력. 생략하면 직접 렌더한다")
    ap.add_argument("--overlay", default="kubernetes/overlays/local")
    ap.add_argument("--namespace", default="local")
    ap.add_argument("--check", action="store_true", help="결함이 있으면 exit 1")
    a = ap.parse_args()

    if a.render == "-":
        text = sys.stdin.read()
    elif a.render:
        with open(a.render, encoding="utf-8") as f:
            text = f.read()
    else:
        r = subprocess.run(["kubectl", "kustomize", a.overlay],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"[check-secret-refs] 렌더 실패:\n{r.stderr}", file=sys.stderr)
            sys.exit(2)
        text = r.stdout

    refs = collect_refs(text.splitlines())
    sec = cluster_keys("secret", a.namespace)
    cm = cluster_keys("configmap", a.namespace)

    missing_obj, missing_key, external = [], [], []
    for kind, name, key in sorted(refs):
        pool = sec if kind == "secretKeyRef" else cm
        if name in EXTERNAL and name not in pool:
            external.append((name, key))
        elif name not in pool:
            missing_obj.append((kind, name, key))
        elif key not in pool[name]:
            missing_key.append((kind, name, key))

    print(f"필수 참조 {len(refs)}건 · Secret {len(sec)}개 · ConfigMap {len(cm)}개")
    if external:
        print(f"\n레포 밖 원천 {len(external)}건 (결함이 아니다):")
        for name, key in external:
            print(f"  {name} / {key}   <- {EXTERNAL[name]}")
    for title, rows in (("오브젝트 자체가 없음", missing_obj),
                        ("오브젝트는 있으나 키가 없음", missing_key)):
        print(f"\n{title} {len(rows)}건")
        for kind, name, key in rows:
            print(f"  {name} / {key}   ({kind})")

    bad = len(missing_obj) + len(missing_key)
    if a.check and bad:
        print(f"\n[check-secret-refs] 결함 {bad}건 — create-secrets.sh 를 보라",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
