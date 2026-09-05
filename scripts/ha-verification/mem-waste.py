# -*- coding: utf-8 -*-
"""requests 대비 실사용 — 낭비가 큰 순서."""
import json, re, subprocess
def sh(a):
    return subprocess.run(["sudo","k3s","kubectl"]+a, capture_output=True, text=True).stdout
def mi(v):
    if not v: return 0.0
    m=re.match(r"^(\d+(?:\.\d+)?)(Ki|Mi|Gi|)$", v)
    return float(m.group(1))*{"Ki":1/1024.0,"Mi":1.0,"Gi":1024.0,"":1/1048576.0}[m.group(2)] if m else 0.0

req={}
d=json.loads(sh(["get","pod","-A","-o","json"]) or "{}")
for p in d.get("items",[]):
    if p["status"].get("phase")!="Running": continue
    k=(p["metadata"]["namespace"], p["metadata"]["name"])
    req[k]=sum(mi((c.get("resources",{}).get("requests") or {}).get("memory")) for c in p["spec"]["containers"])

use={}
for line in sh(["top","pod","-A","--no-headers"]).splitlines():
    f=line.split()
    if len(f)>=4:
        use[(f[0],f[1])]=mi(f[3])

rows=[]
for k,r in req.items():
    u=use.get(k)
    if u is None or r==0: continue
    rows.append((r-u, r, u, k[1]))
rows.sort(reverse=True)
print("%-38s %9s %9s %9s"%("파드","requests","실사용","낭비"))
tot_r=tot_u=0
for waste,r,u,n in rows[:22]:
    print("%-38s %7.0fMi %7.0fMi %7.0fMi"%(n[:38],r,u,waste))
for waste,r,u,n in rows:
    tot_r+=r; tot_u+=u
print("-"*70)
print("합계  requests %.1f GiB · 실사용 %.1f GiB · 낭비 %.1f GiB (%.0f%%)"
      %(tot_r/1024, tot_u/1024, (tot_r-tot_u)/1024, 100*(tot_r-tot_u)/tot_r))
