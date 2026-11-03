#!/usr/bin/env python3
# contracts/ -> Apicurio 게시 요청 본문 ConfigMap (2026-11-03)
#
# 왜: 계약을 레지스트리에 올리는 일이 GitLab CI 잡(publish-contracts)에만 있었는데,
#   베어메탈 재구축(2026-10-04) 뒤로 클러스터 안 GitLab 에 레포가 없어 그 잡이
#   한 번도 돌 수 없었다. ArgoCD 는 GitHub 를 읽고 git push 도 GitHub 로만 간다
#   (GitHub Actions 는 없다). 그래서 레지스트리의 아티팩트가 0개였다.
#   게시를 클러스터 안 PostSync 훅(base/bootstrap/apicurio-contracts.yaml)으로 옮겼다 —
#   ArgoCD 가 이미 읽는 git 하나가 원천이 되고, CI 가 없어도 끊기지 않는다.
#
# 왜 생성하나: kustomize 는 오버레이 밖 파일(contracts/)을 configMapGenerator 로 읽지
#   못한다(load restrictor). 그리고 요청 본문의 JSON 이스케이프를 셸에서 하지 않으려고
#   여기서 **완성된 본문**을 만든다 — 예전 CI 스크립트는 awk 로 따옴표만 이스케이프해서
#   백슬래시가 든 계약을 망가뜨렸을 것이다. 이미지에는 python·jq 가 없다.
#
# 키 이름 규칙(ConfigMap 키에는 `/` 를 쓸 수 없다):
#   ccompat--<subject>.json    contracts/schemas/*.avsc|*.json  -> /apis/ccompat/v7
#   v3--<artifactId>.json      contracts/openapi|asyncapi/*.yaml -> /apis/registry/v3
#   파일명이 곧 subject·artifactId 다(contracts/README.md).
#
# 사용
#   local/render-contracts.py           # 생성 파일을 다시 쓴다
#   local/render-contracts.py --check   # 뒤처졌으면 1 (CI 게이트)
import argparse, io, json, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC = os.path.join(ROOT, "contracts")
OUT = os.path.join(ROOT, "kubernetes", "base", "bootstrap", "apicurio-contracts-configmap.yaml")
KEY_OK = re.compile(r"^[-._a-zA-Z0-9]+$")


def files(sub, exts):
    d = os.path.join(SRC, sub)
    if not os.path.isdir(d):
        return []
    return sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(exts))


def read(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def bodies():
    out = {}
    for p in files("schemas", (".avsc", ".json")):
        name = os.path.splitext(os.path.basename(p))[0]
        text = read(p)
        json.loads(text)  # 스키마 둘 다 JSON 이다 — 깨졌으면 여기서 멈춘다
        stype = "AVRO" if p.endswith(".avsc") else "JSON"
        out["ccompat--%s.json" % name] = {"schema": text, "schemaType": stype}
    for sub, atype in (("openapi", "OPENAPI"), ("asyncapi", "ASYNCAPI")):
        for p in files(sub, (".yaml", ".yml")):
            name = os.path.splitext(os.path.basename(p))[0]
            out["v3--%s.json" % name] = {
                "artifactId": name,
                "artifactType": atype,
                "firstVersion": {"content": {"content": read(p), "contentType": "application/x-yaml"}},
            }
    for k in out:
        if not KEY_OK.match(k):
            sys.exit("ConfigMap 키로 쓸 수 없는 이름: %s" % k)
    return out


def render(b):
    lines = [
        "# 생성 파일 — 손으로 고치지 말 것. 원천은 contracts/, 생성기는 local/render-contracts.py",
        "#   (`--check` 가 뒤처지면 1). 소비자는 apicurio-contracts.yaml 의 PostSync 훅이다.",
        "apiVersion: v1",
        "kind: ConfigMap",
        "metadata:",
        "  name: apicurio-contracts",
        "  labels:",
        "    app.kubernetes.io/name: apicurio-contracts",
        "    app.kubernetes.io/component: bootstrap",
        "    app.kubernetes.io/part-of: oneinchmarket",
        "    app.kubernetes.io/managed-by: kustomize",
        "data:",
    ]
    for k in sorted(b):
        # 한 줄 JSON 을 YAML 작은따옴표 스칼라로 — 작은따옴표만 겹쳐 쓰면 된다.
        v = json.dumps(b[k], ensure_ascii=True, separators=(",", ":"))
        lines.append("  %s: '%s'" % (k, v.replace("'", "''")))
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="쓰지 않고 최신인지만 본다")
    a = ap.parse_args()
    b = bodies()
    if not b:
        sys.exit("contracts/ 에서 계약을 하나도 찾지 못했다 — 경로를 확인할 것")
    new = render(b)
    if a.check:
        try:
            with io.open(OUT, encoding="utf-8", newline="") as f:
                cur = f.read()
        except FileNotFoundError:
            cur = ""
        if cur != new:
            print("[contracts] **뒤처졌다** — local/render-contracts.py 를 돌려 커밋할 것")
            return 1
        print("[contracts] 생성 결과가 git 과 같다 (계약 %d건)" % len(b))
        return 0
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(new)
    print("[contracts] 썼다: %s (계약 %d건: %s)" % (os.path.relpath(OUT, ROOT), len(b), ", ".join(sorted(b))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
