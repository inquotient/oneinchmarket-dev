# -*- coding: utf-8 -*-
"""Hyper-V 풀 HA + zram — 컴포넌트별 메모리 표."""
import json, re, subprocess, sys
sys.path.insert(0, "/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev/scripts/ha-verification")

def sh(a):
    return subprocess.run(["sudo","k3s","kubectl"]+a, capture_output=True, text=True).stdout
def mi(v):
    if not v: return 0.0
    m=re.match(r"^(\d+(?:\.\d+)?)(Ki|Mi|Gi|)$", v)
    return float(m.group(1))*{"Ki":1/1024.0,"Mi":1.0,"Gi":1024.0,"":1/1048576.0}[m.group(2)] if m else 0.0

import importlib.util
spec=importlib.util.spec_from_file_location("hc","/mnt/c/Users/darka/OneDrive/Desktop/Portfolio/oneinchmarket/oneinchmarket-dev/scripts/ha-verification/ha-classify.py")
# ha-classify 는 import 시 main() 을 돈다 — RULES 만 따로 읽는다
src=open(spec.origin,encoding="utf-8").read()
ns={}
exec(src.split("def sh(")[0], ns)
RULES=ns["RULES"]; DEFAULT_TARGET=ns["DEFAULT_TARGET"]; TARGET_OVERRIDE=ns["TARGET_OVERRIDE"]; NEW=ns["NEW_WORKLOADS"]

def classify(name, kind):
    if kind=="DaemonSet": return "D"
    if kind=="CronJob": return "J"
    for pat,g,_ in RULES:
        if re.search(pat,name): return g
    return "?"
def target(name,g,cur):
    for pat,t,_ in TARGET_OVERRIDE:
        if re.search(pat,name): return t
    return DEFAULT_TARGET.get(g,cur)

# 실사용
use={}
for line in sh(["top","pod","-A","--no-headers"]).splitlines():
    f=line.split()
    if len(f)>=4: use[f[1]]=mi(f[3])

rows=[]
for kind,api in [("Deployment","deploy"),("StatefulSet","sts"),("DaemonSet","ds")]:
    d=json.loads(sh(["get",api,"-A","-o","json"]) or "{}")
    for it in d.get("items",[]):
        name=it["metadata"]["name"]; sp=it["spec"]; tpl=sp["template"]["spec"]
        req=sum(mi((c.get("resources",{}).get("requests") or {}).get("memory")) for c in tpl["containers"])
        lim=sum(mi((c.get("resources",{}).get("limits") or {}).get("memory")) for c in tpl["containers"])
        if req==0 and lim==0: continue
        g=classify(name,kind)
        cur=1 if kind=="DaemonSet" else sp.get("replicas",1)
        tgt=1 if kind=="DaemonSet" else max(target(name,g,cur),cur)
        u=0.0; n=0
        for pn,v in use.items():
            if pn.startswith(name+"-"): u+=v; n+=1
        u = u/n if n else 0.0
        qos = "Guaranteed" if (req==lim and req>0) else ("Burstable" if req>0 else "BestEffort")
        rows.append((g,name,kind,req,lim,u,qos,cur,tgt))

rows.sort(key=lambda r:-(r[3]*r[8]))
print("| 등급 | 컴포넌트 | 파드당 req | 파드당 lim | 실사용 | QoS | HA 복제본 | **HA requests** | HA limits |")
print("|:-:|---|---:|---:|---:|:-:|:-:|---:|---:|")
tr=tl=tu=0; dsr=dsl=0
for g,n,k,req,lim,u,q,cur,tgt in rows:
    if k=="DaemonSet":
        dsr+=req; dsl+=lim
        print("| D | `%s` | %.0f | %.0f | %.0f | %s | 노드당 1 | %.0f×N | %.0f×N |"%(n,req,lim,u,q,req,lim))
        continue
    tr+=req*tgt; tl+=lim*tgt; tu+=u*tgt
    print("| %s | `%s` | %.0f | %.0f | %.0f | %s | %d | **%.0f** | %.0f |"%(g,n,req,lim,u,q,tgt,req*tgt,lim*tgt))
for nm,cnt,mem,g,_ in NEW:
    tr+=mem*cnt; tl+=mem*2*cnt
    print("| %s | `%s` (신규) | %.0f | %.0f | — | Burstable | %d | **%.0f** | %.0f |"%(g,nm,mem,mem*2,cnt,mem*cnt,mem*2*cnt))
print()
print("비-DaemonSet  requests %.1f GiB · limits %.1f GiB · 현재실사용기준 %.1f GiB"%(tr/1024,tl/1024,tu/1024))
print("DaemonSet 노드당  requests %.0fMi · limits %.0fMi  → 3노드 %.1f / %.1f GiB"%(dsr,dsl,dsr*3/1024,dsl*3/1024))
print("3노드 합계    requests %.1f GiB · limits %.1f GiB"%((tr+dsr*3)/1024,(tl+dsl*3)/1024))
