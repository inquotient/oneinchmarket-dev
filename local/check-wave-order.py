#!/usr/bin/env python3
"""렌더 안에서 **wave 순서가 뒤집힌 의존**을 전수로 찾는다.

왜 있는가
---------
ArgoCD 는 wave 경계마다 Healthy 를 기다린다. 그래서 앞 wave 의 워크로드가
뒤 wave 의 오브젝트를 필요로 하면 **그 자리에서 영원히 선다.** 2026-10-05
베어메탈 첫 구축에서 이 모양을 **네 번** 밟았다:

  databases-migrate  PreSync 훅인데 DB 는 wave 1          -> Synced 1/573
  openmeter 9종      wave 선언 없음(=0)인데 DB 1·Kafka 2  -> Synced 138/575
  HTTPRoute api·managed-api  wave 0 인데 백엔드는 8·5      -> Synced 126/575
  hive-schematool    wave 2 인데 ConfigMap 은 wave 3       -> Synced 167/582

★ 넷 다 **이미 떠 있는 클러스터에서는 드러나지 않는다** — 대상이 이미 있으니
  순서가 틀려도 아무 일도 없다(Gotcha 58). 재구축이 비로소 청구한다.
★★ 그리고 증상이 전부 **침묵**이다 — 마운트할 것이 없는 파드는 CrashLoop 이
  아니라 ContainerCreating/Init 에서 기다리고, 오류는 이벤트에만 한 줄 남는다.

무엇을 보는가
-------------
① ConfigMap·Secret **볼륨**(`configMap:`/`secret:`)
② `envFrom` 의 configMapRef·secretRef
③ `secretKeyRef`·`configMapKeyRef`
④ HTTPRoute 의 `backendRefs` -> Service

각 참조 대상이 렌더 안에 있고 그 wave 가 **참조하는 쪽보다 크면** 보고한다.
렌더 밖에 있는 것(create-secrets.sh 가 만드는 Secret 등)은 세지 않는다 —
그것은 check-secret-refs.py 가 보는 질문이다. 달성할 수 없는 게이트는 없는
게이트보다 나쁘다(Gotcha 73·90).

사용
----
    kubectl kustomize kubernetes/overlays/local | python3 local/check-wave-order.py -
    python3 local/check-wave-order.py --check        # 뒤집힘이 있으면 exit 1

★ 훅(`argocd.argoproj.io/hook`)의 단계도 함께 본다 — `PreSync` 는 **모든
  wave 보다 앞**이므로, PreSync 훅이 렌더 안의 무엇이든 참조하면 뒤집힘이다.
"""
import argparse
import re
import subprocess
import sys

WAVE = "argocd.argoproj.io/sync-wave"
HOOK = "argocd.argoproj.io/hook"
WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"}
# PreSync 는 모든 wave 앞이므로 아주 작은 수로 취급한다
PHASE_RANK = {"PreSync": -1000, "Sync": 0, "PostSync": 1000, "SyncFail": 1000}


def split_docs(text):
    docs, cur = [], []
    for line in text.splitlines():
        if line.rstrip("\r") == "---":
            if cur:
                docs.append("\n".join(cur))
            cur = []
        else:
            cur.append(line)
    if cur:
        docs.append("\n".join(cur))
    return [d for d in docs if d.strip()]


def meta(doc):
    kind = name = None
    wave = 0
    hook = None
    for line in doc.splitlines():
        m = re.match(r"^kind:\s*(\S+)", line)
        if m and kind is None:
            kind = m.group(1)
        m = re.match(r"^  name:\s*(\S+)", line)
        if m and name is None:
            name = m.group(1).strip("\"'")
        m = re.match(r"^\s+" + re.escape(WAVE) + r':\s*"?(-?\d+)"?', line)
        if m:
            wave = int(m.group(1))
        m = re.match(r"^\s+" + re.escape(HOOK) + r":\s*(\S+)", line)
        if m:
            hook = m.group(1).strip("\"'")
    return kind, name, wave, hook


def refs(doc):
    """(kind, name) 들을 모은다. 들여쓰기로 블록을 읽는다."""
    out = set()
    lines = doc.splitlines()
    i = 0
    simple = {
        "configMap": "ConfigMap", "secret": "Secret",
        "configMapRef": "ConfigMap", "secretRef": "Secret",
        "configMapKeyRef": "ConfigMap", "secretKeyRef": "Secret",
    }
    while i < len(lines):
        m = re.match(r"^(\s*)-?\s*(\w+):\s*$", lines[i])
        if m and m.group(2) in simple:
            base = len(m.group(1))
            j = i + 1
            while j < len(lines):
                m2 = re.match(r"^(\s*)(\w+):\s*(.*)$", lines[j])
                if not m2 or len(m2.group(1)) <= base:
                    break
                if m2.group(2) in ("name", "secretName"):
                    out.add((simple[m.group(2)], m2.group(3).strip().strip("\"'")))
                j += 1
            i = j
            continue
        # secret 볼륨은 `secretName:` 을 쓴다
        m = re.match(r"^\s+secretName:\s*(\S+)", lines[i])
        if m:
            out.add(("Secret", m.group(1).strip("\"'")))
        i += 1
    # HTTPRoute 의 backendRefs -> Service
    if re.search(r"^kind:\s*HTTPRoute", doc, re.M):
        blk = re.search(r"backendRefs:(.*?)(?=\n  \w|\Z)", doc, re.S)
        if blk:
            for nm in re.findall(r"^\s+name:\s*(\S+)", blk.group(1), re.M):
                out.add(("Service", nm.strip("\"'")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("render", nargs="?", default=None)
    ap.add_argument("--overlay", default="kubernetes/overlays/local")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()

    if a.render == "-":
        text = sys.stdin.read()
    elif a.render:
        text = open(a.render, encoding="utf-8").read()
    else:
        r = subprocess.run(["kubectl", "kustomize", a.overlay],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            return 2
        text = r.stdout

    docs = split_docs(text)
    index = {}
    for d in docs:
        kind, name, wave, hook = meta(d)
        if kind and name:
            index[(kind, name)] = (wave, hook)

    bad = []
    for d in docs:
        kind, name, wave, hook = meta(d)
        if kind not in WORKLOADS and kind != "HTTPRoute":
            continue
        mine = PHASE_RANK.get(hook, 0) + wave if hook else wave
        for rk, rn in sorted(refs(d)):
            tgt = index.get((rk, rn))
            if tgt is None:
                continue          # 렌더 밖 — check-secret-refs.py 의 질문이다
            twave, thook = tgt
            theirs = PHASE_RANK.get(thook, 0) + twave if thook else twave
            if theirs > mine:
                bad.append((kind, name, hook or "Sync", wave,
                            rk, rn, thook or "Sync", twave))

    print(f"워크로드·라우트 검사 · 오브젝트 {len(index)}개")
    print(f"\nwave 가 뒤집힌 의존 {len(bad)}건")
    for k, n, h, w, rk, rn, th, tw in bad:
        print(f"  {k}/{n} ({h} wave {w})  ->  {rk}/{rn} ({th} wave {tw})")
    if a.check and bad:
        print(f"\n[check-wave-order] 뒤집힘 {len(bad)}건 — 그 wave 에서 동기화가 선다",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
