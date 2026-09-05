# -*- coding: utf-8 -*-
"""Hyper-V 풀 HA + zram — 전 컴포넌트 메모리 표.

★ 첫 판은 CronJob 15종과 requests 가 0인 오퍼레이터 7종을 건너뛰었다.
  "전체" 라고 적으려면 빠지는 것이 없어야 한다 — 값이 0이거나 성격이 달라도
  행은 남기고 그렇게 표시한다.
"""
import json, re, subprocess

ROOT = "/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev"

def sh(a):
    return subprocess.run(["sudo", "k3s", "kubectl"] + a, capture_output=True, text=True).stdout

def mi(v):
    if not v: return 0.0
    m = re.match(r"^(\d+(?:\.\d+)?)(Ki|Mi|Gi|)$", v)
    return float(m.group(1)) * {"Ki":1/1024.0,"Mi":1.0,"Gi":1024.0,"":1/1048576.0}[m.group(2)] if m else 0.0

src = open(ROOT + "/scripts/ha-verification/ha-classify.py", encoding="utf-8").read()
ns = {}
exec(src.split("def sh(")[0], ns)
RULES, DEFAULT_TARGET, TARGET_OVERRIDE, NEW = ns["RULES"], ns["DEFAULT_TARGET"], ns["TARGET_OVERRIDE"], ns["NEW_WORKLOADS"]

def grade_of(name, kind):
    if kind == "DaemonSet": return "D"
    if kind == "CronJob": return "J"
    for pat, g, _ in RULES:
        if re.search(pat, name): return g
    return "?"

def target_of(name, g, cur):
    for pat, t, _ in TARGET_OVERRIDE:
        if re.search(pat, name): return t
    return DEFAULT_TARGET.get(g, cur)

use = {}
for line in sh(["top", "pod", "-A", "--no-headers"]).splitlines():
    f = line.split()
    if len(f) >= 4: use[f[1]] = mi(f[3])

rows = []
for kind, api in [("Deployment","deploy"), ("StatefulSet","sts"), ("DaemonSet","ds"), ("CronJob","cronjob")]:
    for it in json.loads(sh(["get", api, "-A", "-o", "json"]) or "{}").get("items", []):
        name, sp = it["metadata"]["name"], it["spec"]
        if kind == "CronJob":
            tpl = sp["jobTemplate"]["spec"]["template"]["spec"]; cur = 0
        else:
            tpl = sp["template"]["spec"]; cur = 1 if kind == "DaemonSet" else sp.get("replicas", 1)
        req = sum(mi((c.get("resources",{}).get("requests") or {}).get("memory")) for c in tpl["containers"])
        lim = sum(mi((c.get("resources",{}).get("limits") or {}).get("memory")) for c in tpl["containers"])
        g = grade_of(name, kind)
        tgt = 1 if kind == "DaemonSet" else (0 if kind == "CronJob" else max(target_of(name, g, cur), cur))
        u = [v for pn, v in use.items() if pn.startswith(name + "-")]
        u = sum(u) / len(u) if u else 0.0
        qos = "Guaranteed" if (req == lim and req > 0) else ("Burstable" if req > 0 else "**BestEffort**")
        rows.append((g, name, kind, req, lim, u, qos, cur, tgt))

order = {"C":0, "S":1, "R":2, "L":3, "D":4, "J":5, "X":6, "?":7}
rows.sort(key=lambda r: (order.get(r[0], 9), -(r[3] * max(r[8], 1))))

print("| 등급 | 컴포넌트 | 종류 | 파드당 req | 파드당 lim | 실사용 | QoS | HA 복제본 | **HA req** | HA lim |")
print("|:-:|---|:-:|---:|---:|---:|:-:|:-:|---:|---:|")
tr = tl = 0.0; dsr = dsl = 0.0; cj_r = cj_l = 0.0; be = 0
for g, n, k, req, lim, u, q, cur, tgt in rows:
    if q.startswith("**"): be += 1
    if k == "DaemonSet":
        dsr += req; dsl += lim
        print("| D | `%s` | DS | %.0f | %.0f | %.0f | %s | 노드당 1 | **%.0f×N** | %.0f×N |" % (n, req, lim, u, q, req, lim))
    elif k == "CronJob":
        cj_r += req; cj_l += lim
        print("| J | `%s` | CJ | %.0f | %.0f | — | %s | 실행 시에만 | **(%.0f)** | (%.0f) |" % (n, req, lim, q, req, lim))
    else:
        tr += req * tgt; tl += lim * tgt
        print("| %s | `%s` | %s | %.0f | %.0f | %.0f | %s | %d | **%.0f** | %.0f |"
              % (g, n, "Dep" if k == "Deployment" else "STS", req, lim, u, q, tgt, req * tgt, lim * tgt))
for nm, cnt, mem, g, _ in NEW:
    tr += mem * cnt; tl += mem * 2 * cnt
    print("| %s | `%s` (신규) | STS | %.0f | %.0f | — | Burstable | %d | **%.0f** | %.0f |" % (g, nm, mem, mem*2, cnt, mem*cnt, mem*2*cnt))

print()
print("행 수 %d (신규 %d 포함)  · BestEffort(requests 없음) %d 종" % (len(rows) + len(NEW), len(NEW), be))
print("상시 비-DaemonSet   requests %.1f GiB · limits %.1f GiB" % (tr/1024, tl/1024))
print("DaemonSet 노드당    requests %.0fMi · limits %.0fMi  → 3노드 %.1f / %.1f GiB" % (dsr, dsl, dsr*3/1024, dsl*3/1024))
print("CronJob 전부 동시   requests %.1f GiB · limits %.1f GiB  (실제로는 겹치지 않는다)" % (cj_r/1024, cj_l/1024))
print("─" * 72)
print("3노드 상시 합계     requests %.1f GiB · limits %.1f GiB" % ((tr+dsr*3)/1024, (tl+dsl*3)/1024))
print("  + CronJob 최악    requests %.1f GiB" % ((tr+dsr*3+cj_r)/1024))
