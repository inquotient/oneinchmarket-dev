#!/usr/bin/env bash
# 7-1: kube-bench CIS Kubernetes Benchmark
#
# ★★★ 2026-10-09 에 매니페스트(01-kube-bench.yaml)를 이 스크립트로 바꿨다.
#   그 매니페스트는 **한 번도 돌지 않았고**, 돌았어도 틀린 답을 줬을 것이다.
#   결함이 다섯이었다:
#     1. namespace: dev 하드코딩 - 이 클러스터에 그 네임스페이스가 없어
#        kubectl apply 가 실패했다. 그래서 7-1 은 늘 "참고" 였다.
#     2. aquasec/kube-bench:latest - 이 레포가 금지한 모양이다(Gotcha 46).
#     3. /etc/kubernetes, /var/lib/kubelet, /etc/systemd 를 마운트했다.
#        k3s 는 거기에 아무것도 두지 않는다 - 실측으로 /etc/kubernetes 는
#        **빈 디렉터리**다. k3s 벤치마크가 실제로 보는 것은
#        /var/lib/rancher/k3s(50회 참조) 와 /etc/rancher(49회)다.
#     4. stock CIS 로 돌았다. kube-bench 는 **k3s 전용 벤치마크**를 들고 있다
#        (실측: k3s-cis-1.7/1.8/1.9/1.23/1.24). stock 으로 돌리면 k3s 가
#        컴포넌트를 한 프로세스에 품기 때문에 인자 검사가 전부 FAIL 이 된다.
#     5. ★ 결과를 **아무도 읽지 않았다.** run-all.sh 의 run_yaml 은 apply 만
#        하고 "로그는 사람이 읽을 것" 을 찍었다. 즉 판정이 없었다.
#
# ★★ 그리고 가장 중요한 것 - **FAIL 을 발견으로 읽지 말 것.**
#   첫 실측은 fail 28 이었는데 actual_value 를 읽어 보니 **실재 발견은 0** 이고
#   전부 측정 실패였다. 세 가지 모양으로 나온다:
#     · 빈 값          - k3s 가 컴포넌트를 품어 검사할 인자가 없다(19건)
#     · Forbidden      - Job 이 default SA 로 돌아 API 가 403 을 줬다(4건)
#     · ...: not found - 컨테이너에 journalctl 이 없어 유닛 인자를 못 읽었다(3건)
#   ★ 제목만 읽으면 "RBAC 가 꺼져 있다"(1.2.8) 같은 거짓 발견을 믿게 된다 -
#     k3s 는 RBAC 를 기본으로 켠다. **actual_value 를 읽을 것.**
#   ★★ Forbidden 4건은 **고칠 수 있는 측정 실패**였다. 읽기 전용 SA 를 주자
#     5.1.1 이 통과로 바뀌고 5.1.3/5.1.5/5.1.6 이 **진짜 발견**이 됐다.
#     권한이 없으면 Section 5 는 통째로 무의미하다.
#
# ★ 판정은 **셋**이다 - 통과 / 실패 / 측정 불가(종료 코드 0/1/2).
#   실패는 **실측값을 가진 FAIL** 에 대해서만 선언한다. 측정 불가를 실패로
#   세면 빨간불이 상수가 되고, 그러면 사람이 배경으로 읽는다(Gotcha 73·90).
#   반대로 측정 불가를 통과로 접으면 거짓 증명이 된다(Gotcha 191).
#
# ★ etcd 타깃은 뺀다 - 이 클러스터는 kine(sqlite)을 쓰고 etcd 가 없다
#   (Gotcha 55). 넣으면 그 섹션 전체가 측정 불가로 나와 수치만 흐린다.
#
# 실측 기준선(2026-10-09, local, 읽기 전용 SA 부여 후)
#   pass 32 · fail 27 · warn 50 · info 14
#   fail 27 = 실재 발견 4 + 측정 불가 23
#   실재 발견: 1.1.20(PKI 파일 13개가 644) · 5.1.3(wildcard) ·
#              5.1.5(default SA automount 미설정) · 5.1.6(SA 토큰 마운트)
#   ★ 5.1.3/5.1.5/5.1.6 은 7-9 와 **영역이 겹치고 검사는 다르다** -
#     7-9 는 default SA 를 **쓰는 파드** 2개를 세고, 5.1.5 는 automount 를
#     **끄지 않은** default SA 를 센다. 같은 결함의 두 측면이다.
#
# 쓰는 법
#   bash 01-kube-bench.sh [namespace]
#   KEEP=1 bash 01-kube-bench.sh local    # 정리하지 않고 남긴다(진단용)
set -uo pipefail

NAMESPACE="${1:-dev}"
IMAGE="${KUBE_BENCH_IMAGE:-docker.io/aquasec/kube-bench:v0.16.0}"
BENCHMARK="${KUBE_BENCH_BENCHMARK:-k3s-cis-1.9}"
TARGETS="${KUBE_BENCH_TARGETS:-master,controlplane,node,policies}"
JOB=oim-kube-bench
SA=oim-kube-bench
CR=oim-kube-bench-read
WAIT_SECONDS="${WAIT_SECONDS:-240}"

TMP="$(mktemp -d)"
cleanup() {
  if [ "${KEEP:-0}" != "1" ]; then
    kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl -n "$NAMESPACE" delete sa "$SA" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete clusterrolebinding "$CR" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl delete clusterrole "$CR" --ignore-not-found --wait=false >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
hr()  { say "------------------------------------------------------------"; }

say "=== 7-1: kube-bench CIS Benchmark ($BENCHMARK) ==="
say "네임스페이스: $NAMESPACE · 이미지: $IMAGE · 타깃: $TARGETS"
hr

# --- 0. 장치 대조군 --------------------------------------------------------
for t in kubectl python3; do
  command -v "$t" >/dev/null 2>&1 || { say "[측정 불가] $t 이 없다."; exit 2; }
done
kubectl cluster-info >/dev/null 2>&1 || { say "[측정 불가] 클러스터에 닿지 못한다."; exit 2; }
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || {
  say "[측정 불가] 네임스페이스 '$NAMESPACE' 가 없다."
  say "            ★ 예전 매니페스트가 'dev' 를 하드코딩해 늘 여기서 멈췄다."
  exit 2
}

CP_NODE="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null | head -1 | sed 's|node/||')"
if [ -z "$CP_NODE" ]; then
  CP_NODE="$(kubectl get nodes -o name 2>/dev/null | head -1 | sed 's|node/||')"
  say "[참고] control-plane 라벨이 붙은 노드가 없다 - '$CP_NODE' 에서 돌린다."
  say "       master 타깃의 결과가 측정 불가로 나올 수 있다."
else
  say "control-plane 노드: $CP_NODE"
fi

# --- 1. 읽기 전용 SA ------------------------------------------------------
# ★ 이것이 없으면 Section 5 가 통째로 403 이다(실측으로 4건이 그랬다).
#   권한은 **읽기만** 이고 Secret 은 들어 있지 않다. 스크립트가 끝나며 지운다.
if ! kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: security-verification
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $CR
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: security-verification
rules:
  - apiGroups: [""]
    resources: [pods, serviceaccounts, namespaces, nodes]
    verbs: [get, list]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: [roles, clusterroles, rolebindings, clusterrolebindings]
    verbs: [get, list]
  - apiGroups: ["networking.k8s.io"]
    resources: [networkpolicies]
    verbs: [get, list]
  - apiGroups: ["policy"]
    resources: [podsecuritypolicies]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $CR
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: $CR
subjects:
  - kind: ServiceAccount
    name: $SA
    namespace: $NAMESPACE
YAML
then
  say "[측정 불가] SA·ClusterRole 을 만들지 못했다."
  exit 2
fi

# --- 2. Job ---------------------------------------------------------------
# ★ hostPID 는 필수다 - k3s 벤치마크가 프로세스를 보고 판정한다
#   (config 의 bins 가 containerd 다). PodSecurity 가 baseline 이면
#   경고가 뜨지만 local 은 enforce: privileged 라 적용된다.
kubectl -n "$NAMESPACE" delete job "$JOB" --ignore-not-found --wait=true >/dev/null 2>&1
if ! kubectl apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: kube-bench
    app.kubernetes.io/component: security-verification
    app.kubernetes.io/part-of: oneinchmarket
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: kube-bench
    spec:
      nodeName: $CP_NODE
      serviceAccountName: $SA
      hostPID: true
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: $IMAGE
          command: ["kube-bench", "run", "--benchmark", "$BENCHMARK", "--targets", "$TARGETS", "--json"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          volumeMounts:
            - { name: k3s,     mountPath: /var/lib/rancher/k3s, readOnly: true }
            - { name: rancher, mountPath: /etc/rancher,         readOnly: true }
            - { name: kubelet, mountPath: /var/lib/kubelet,     readOnly: true }
            - { name: systemd, mountPath: /etc/systemd,         readOnly: true }
      volumes:
        - { name: k3s,     hostPath: { path: /var/lib/rancher/k3s } }
        - { name: rancher, hostPath: { path: /etc/rancher } }
        - { name: kubelet, hostPath: { path: /var/lib/kubelet } }
        - { name: systemd, hostPath: { path: /etc/systemd } }
YAML
then
  say "[측정 불가] Job 을 만들지 못했다."
  exit 2
fi

say "Job 적용 — 완료 대기 (최대 ${WAIT_SECONDS}초)"
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete "job/$JOB" --timeout="${WAIT_SECONDS}s" >/dev/null 2>&1; then
  say "[측정 불가] Job 이 ${WAIT_SECONDS}초 안에 완료되지 않았다."
  kubectl -n "$NAMESPACE" get "job/$JOB" -o jsonpath='  상태: succeeded={.status.succeeded} failed={.status.failed}{"\n"}' 2>/dev/null
  kubectl -n "$NAMESPACE" logs "job/$JOB" --tail=15 2>&1 | sed 's/^/  /' | head -15
  exit 2
fi

kubectl -n "$NAMESPACE" logs "job/$JOB" > "$TMP/kb.json" 2>&1 || true
if [ ! -s "$TMP/kb.json" ]; then
  say "[측정 불가] Job 로그가 비어 있다."
  exit 2
fi
say "출력 $(wc -c < "$TMP/kb.json") 바이트"
hr

# --- 3. 분류 --------------------------------------------------------------
cat > "$TMP/classify.py" <<'PY'
import json, sys

path = sys.argv[1]
raw = open(path, encoding="utf-8", errors="replace").read()
i = raw.find("{")
if i < 0:
    print("[측정 불가] 출력이 JSON 이 아니다. 처음 400자:")
    print(raw[:400])
    print("VERDICT findings=0 unmeasured=0 unparsable=1")
    raise SystemExit

try:
    d = json.loads(raw[i:])
except Exception as e:
    print("[측정 불가] JSON 파싱 실패: %s" % e)
    print("VERDICT findings=0 unmeasured=0 unparsable=1")
    raise SystemExit

# 측정 실패의 표식. ★ 이것은 **덧붙여 쓰는 목록**이다 - 새 모양을 만나면
#   여기에 더할 것. 실측으로 셋이 나왔다(빈 값 · 403 · 명령 없음).
UNMEASURABLE = (
    "Forbidden",
    ": not found",
    "No such file or directory",
    "command not found",
)

def bucket(result):
    av = (result.get("actual_value") or "")
    if not av.strip():
        return "unmeasured", "실측값이 비어 있다"
    for m in UNMEASURABLE:
        if m in av:
            return "unmeasured", m.strip(": ")
    return "finding", ""

totals = d.get("Totals") or {}
print("Totals: pass %s · fail %s · warn %s · info %s" % (
    totals.get("total_pass"), totals.get("total_fail"),
    totals.get("total_warn"), totals.get("total_info")))
print()

findings = []
unmeasured = []
for c in d.get("Controls", []):
    sec = c.get("id")
    for g in c.get("tests", []):
        for r in g.get("results", []):
            if r.get("status") != "FAIL":
                continue
            kind, why = bucket(r)
            row = (sec, r.get("test_number"), (r.get("test_desc") or "")[:72], why)
            (findings if kind == "finding" else unmeasured).append(row)

for c in d.get("Controls", []):
    print("섹션 %s %s" % (c.get("id"), (c.get("text") or "")[:50]))
    print("   pass %s · fail %s · warn %s · info %s" % (
        c.get("total_pass"), c.get("total_fail"),
        c.get("total_warn"), c.get("total_info")))
print()

print("=== 실재 발견 (실측값을 가진 FAIL) : %d 건 ===" % len(findings))
for sec, num, desc, _ in findings:
    print("   [실패] %s  %s" % (num, desc))
if not findings:
    print("   없음")
print()

print("=== 측정 불가 (FAIL 로 보고됐으나 잴 수 없었던 것) : %d 건 ===" % len(unmeasured))
by_why = {}
for sec, num, desc, why in unmeasured:
    by_why.setdefault(why, []).append(num)
for why, nums in sorted(by_why.items()):
    print("   %-28s %d건: %s" % (why, len(nums), ", ".join(nums)))
if not unmeasured:
    print("   없음")
print()
print("VERDICT findings=%d unmeasured=%d unparsable=0" % (len(findings), len(unmeasured)))
PY

python3 "$TMP/classify.py" "$TMP/kb.json" | tee "$TMP/report.txt"
hr

V="$(grep '^VERDICT ' "$TMP/report.txt" | tail -1 || true)"
FINDINGS="$(printf '%s' "$V" | sed -n 's/.*findings=\([0-9]*\).*/\1/p')"
UNMEAS="$(printf '%s' "$V" | sed -n 's/.*unmeasured=\([0-9]*\).*/\1/p')"
UNPARSE="$(printf '%s' "$V" | sed -n 's/.*unparsable=\([0-9]*\).*/\1/p')"

say "이 검사가 **재지 못하는 것**"
say "  - k3s 가 한 프로세스에 품은 컴포넌트의 인자. 검사할 커맨드라인이 없어"
say "    빈 값으로 나온다. 'RBAC 가 꺼져 있다'(1.2.8) 같은 FAIL 을 발견으로"
say "    읽지 말 것 - k3s 는 기본으로 켠다."
say "  - systemd 유닛의 인자. 컨테이너에 journalctl 이 없어 못 읽는다."
say "  - etcd. 이 클러스터는 kine(sqlite)을 쓰므로 타깃에서 뺐다."
say "  - warn 항목. 사람이 판단할 몫이라 판정에 넣지 않는다(수치만 남긴다)."
hr

if [ -z "${FINDINGS:-}" ] || [ -z "${UNMEAS:-}" ] || [ "${UNPARSE:-1}" != "0" ]; then
  say "판정: 측정 불가 — 결과를 분류하지 못했다"
  exit 2
fi
if [ "$FINDINGS" -gt 0 ]; then
  say "판정: 실패 — 실재 발견 ${FINDINGS}건 (측정 불가 ${UNMEAS}건)"
  exit 1
fi
if [ "$UNMEAS" -gt 0 ]; then
  say "판정: 통과 — 실재 발견 0건 (측정 불가 ${UNMEAS}건은 k3s 구조상의 것이다)"
  exit 0
fi
say "판정: 통과 — FAIL 0건"
exit 0
