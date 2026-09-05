# -*- coding: utf-8 -*-
# Hyper-V 3노드 용량 계산기 — docs/LOCAL-DEPLOYMENT.md §12 의 근거
#
# 살아 있는 클러스터의 requests 를 읽어 세 시나리오의 VM 메모리를 계산한다.
# 숫자를 문서에 박아 두면 워크로드가 늘 때 조용히 낡는다 — 다시 돌릴 것.
#
#   python3 local/hyperv-capacity.py
#
# 모델:  Σ VM 메모리 = 배치된 파드 requests + 노드당 DaemonSet + 시스템 예약(1.9 GiB)
# 가용:  63.4(물리) − 7.0(Windows) − 8.8(L0 랩) = 47.6 GiB
import json, subprocess, re
def sh(ns,a): return json.loads(subprocess.run(["sudo","k3s","kubectl","-n",ns]+a+["-o","json"],capture_output=True,text=True).stdout or "{}")
def mem(v):
    if not v: return 0
    m=re.match(r'^(\d+(?:\.\d+)?)(Ki|Mi|Gi|)$',v)
    return float(m.group(1))*{"Ki":1/1024,"Mi":1,"Gi":1024,"":1/1048576}[m.group(2)] if m else 0
def cpu(v):
    if not v: return 0
    return float(v[:-1]) if v.endswith("m") else float(v)*1000
inv={}
for ns in ["local","kube-system","istio-system","tetragon","kyverno","elastic-system"]:
    for kind,api in [("Deployment","deploy"),("StatefulSet","sts"),("DaemonSet","ds")]:
        for it in sh(ns,["get",api]).get("items",[]):
            sp=it["spec"]; tpl=sp["template"]["spec"]
            m=sum(mem((c.get("resources",{}).get("requests") or {}).get("memory")) for c in tpl["containers"])
            c=sum(cpu((c.get("resources",{}).get("requests") or {}).get("cpu")) for c in tpl["containers"])
            if m==0 and c==0: continue
            pvc = bool(sp.get("volumeClaimTemplates")) or any(v.get("persistentVolumeClaim") for v in tpl.get("volumes",[]))
            inv[it["metadata"]["name"]]={"kind":kind,"mem":m,"cpu":c,"pvc":pvc}
DS=[n for n,v in inv.items() if v["kind"]=="DaemonSet"]
ds_mem=sum(inv[n]["mem"] for n in DS); ds_cpu=sum(inv[n]["cpu"] for n in DS)
RES=1.9*1024

def run(label, A, B, trim=0.0):
    node={k:{"mem":0.0,"cpu":0.0,"pods":0,"items":[]} for k in (1,2,3)}
    placed=set(DS)
    def put(k,n,tag,m,c):
        node[k]["mem"]+=m; node[k]["cpu"]+=c; node[k]["pods"]+=1; node[k]["items"].append((tag,m))
    for n,rep in list(A.items())+list(B.items()):
        if n not in inv: continue
        v=inv[n]; placed.add(n)
        for i in range(rep): put((i%3)+1, n, "%s(%d/%d)"%(n,i+1,rep), v["mem"], v["cpu"])
    rest=sorted([n for n in inv if n not in placed], key=lambda n:-inv[n]["mem"])
    for n in rest:
        k=min(node,key=lambda x:node[x]["mem"]); v=inv[n]
        put(k,n,n,v["mem"],v["cpu"])
    tot=0; out=[]
    for k in (1,2,3):
        vm=(node[k]["mem"]+ds_mem+RES)*(1-trim)
        tot+=vm
        out.append((k,node[k]["mem"],node[k]["pods"]+len(DS),vm,(node[k]["cpu"]+ds_cpu)/1000))
    return label,out,tot,node

A_full={"kafka":3,"elasticsearch-es-default":3,"zookeeper":3}
B_full={"ingress-istio":2,"nginx":2,"logstash":2,"otel-gateway":2,"admin":2,"cmmn-api":2,
        "openmeter-api":2,"openmeter-sink-worker":2,"waypoint":2,"istiod":2,"coredns":2}
A_lean={"kafka":3}
B_lean={"ingress-istio":2,"nginx":2,"otel-gateway":2,"openmeter-api":2,"istiod":2,"coredns":2}

for lbl,A,B,trim in [("① 완전 HA",A_full,B_full,0.0),
                     ("② 실용 HA",A_lean,B_lean,0.0),
                     ("③ 실용 HA + requests 정정(-16%)",A_lean,B_lean,0.16)]:
    l,out,tot,node=run(lbl,A,B,trim)
    print("\n=== %s ==="%l)
    print("%-8s %11s %6s %11s %8s"%("노드","파드requests","파드수","VM 메모리","CPU"))
    for k,m,p,vm,c in out:
        print("%-8s %10.2fGi %6d %10.2fGi %6.1f코어"%("node-%d"%k,m/1024,p,vm/1024,c))
    print("합계 VM %.2f GiB   가용 47.6(L0-Target 종료 시 50.4)  → %s"%
          (tot/1024, "들어감" if tot/1024<=47.6 else ("L0-Target 종료 시 들어감" if tot/1024<=50.4 else "초과 %.1f"%(tot/1024-47.6))))
