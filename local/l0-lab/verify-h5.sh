#!/usr/bin/env bash
# H5 검증 — Hyper-V 합성 NIC(hv_netvsc)에서 Cilium eBPF 가 동작하는가
#
# ★ 왜 이걸 먼저 하는가
#   ADR-051(A안) 전면 실행 = k3s 를 Hyper-V 다중 노드로 이설이다. 그 경우
#   PVC 27개(PostgreSQL·GitLab·ES·MinIO·Kafka 데이터)가 전부 재생성된다.
#   H5 는 `[UNVERIFIED]` 이고, 문서는 WSL2 를 고른 이유 중 하나로
#   "H5 가 WSL2 에서는 오히려 리스크가 낮다" 를 든다.
#   **데이터를 날린 뒤에 H5 실패를 알게 되는 것보다, 랩 VM 한 대에서 먼저
#   확인하는 편이 훨씬 싸다.**
#
# 실행 위치: Hyper-V Ubuntu 게스트(L0-Target) 안. 호스트가 아니다.
# 전제: 이 VM 의 NIC 이 hv_netvsc 여야 한다(Hyper-V 합성 NIC).
set -uo pipefail

K3S_VERSION="${K3S_VERSION:-v1.31.4+k3s1}"
CILIUM_VERSION="${CILIUM_VERSION:-1.16.5}"
PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [ .. ] $*"; }

echo "══════ 0. 전제 — 합성 NIC 과 커널 기능"
drv=$(basename "$(readlink -f /sys/class/net/eth0/device/driver 2>/dev/null)" 2>/dev/null)
[ "$drv" = "hv_netvsc" ] && ok "NIC 드라이버 hv_netvsc — Hyper-V 합성 NIC 맞음" \
                         || bad "NIC 드라이버가 '$drv' 다. Hyper-V 게스트가 아니면 이 검증은 의미가 없다"
[ -f /sys/kernel/btf/vmlinux ] && ok "BTF 존재 ($(stat -c%s /sys/kernel/btf/vmlinux) 바이트) — CO-RE 가능" \
                               || bad "BTF 없음 — Cilium·Tetragon CO-RE 불가. 이것만으로 이설 중단 사유다"
for m in xt_TPROXY xt_socket nf_conntrack; do
  (grep -qw "$m" /proc/modules || modinfo "$m" >/dev/null 2>&1) \
    && ok "$m 사용 가능" || bad "$m 없음 — Istio ambient ztunnel 인터셉트 불가"
done

echo "══════ 1. k3s ${K3S_VERSION} (클러스터와 동일 플래그)"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
    --write-kubeconfig-mode 644 --disable traefik --disable servicelb \
    --flannel-backend=none --disable-network-policy
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for _ in $(seq 1 60); do kubectl get node >/dev/null 2>&1 && break; sleep 3; done
kubectl get node >/dev/null 2>&1 && ok "k3s API 응답" || { bad "k3s 기동 실패"; exit 1; }

echo "══════ 2. Cilium ${CILIUM_VERSION} (M1·M2 동일)"
if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  command -v cilium >/dev/null 2>&1 || {
    curl -sL --fail https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz \
      | sudo tar xzvfC - /usr/local/bin >/dev/null; }
  cilium install --version "${CILIUM_VERSION}" \
    --set socketLB.hostNamespaceOnly=true \
    --set cni.exclusive=false \
    --set k8sServiceHost=127.0.0.1 --set k8sServicePort=6443 \
    --set operator.replicas=1
fi
if cilium status --wait --wait-duration 5m >/dev/null 2>&1; then
  ok "Cilium 정상 — **H5 의 핵심 질문에 대한 답이다**"
else
  bad "Cilium 미준비. 아래 진단을 볼 것:"; cilium status 2>&1 | tail -20
fi

echo "══════ 3. 데이터패스 — 실제로 통신이 되는가"
# ★ CoreDNS 를 먼저 기다린다. Cilium 이 Ready 가 된 직후에도 CoreDNS 는
#   아직 재기동 중일 수 있다(CNI 가 바뀌며 IP 를 다시 받는다). 이걸 기다리지
#   않았더니 3단계가 DNS 때문에 FAIL 났고 **원인을 Cilium 으로 오해할 뻔했다**
#   — 같은 검사를 몇 분 뒤에 하면 200 이 나온다(실측 2026-09-04).
kubectl -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null 2>&1 \
  && ok "CoreDNS 준비됨" || bad "CoreDNS 준비 실패 — 이후 DNS 검사는 신뢰할 수 없다"
kubectl create deploy h5web --image=nginx:alpine >/dev/null 2>&1
kubectl expose deploy h5web --port=80 >/dev/null 2>&1
kubectl rollout status deploy/h5web --timeout=180s >/dev/null 2>&1 \
  && ok "파드 스케줄·기동 (CNI 가 IP 를 줬다는 뜻)" || bad "파드 기동 실패 — CNI 문제"
# ★ socketLB 검증 — connect() 시점 BPF cgroup 훅이라 이게 M1 의 실체다.
kubectl run h5cli --image=curlimages/curl --restart=Never --rm -i --quiet --timeout=120s \
  -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://h5web 2>/dev/null | grep -q 200 \
  && ok "Service DNS + socketLB 경유 통신 200" || bad "Service 경유 통신 실패 — socketLB 또는 DNS"

echo "══════ 4. NetworkPolicy 강제 (Cilium 이 정책을 실제로 거는가)"
# ★ 기준선을 먼저 세운다.
#   이 검사는 "200 이 아니면 차단된 것" 으로 판정한다. 그런데 **정책과 무관하게
#   이미 통신이 안 되고 있으면 그 판정이 무조건 통과**가 된다. 실제로 그런 일이
#   있었다 — 3단계가 DNS 때문에 실패한 실행에서 4단계가 PASS 로 찍혔고,
#   그것은 정책이 걸렸다는 근거가 전혀 아니었다.
#   그래서 기준선이 200 이 아니면 통과도 실패도 아닌 **판정 불가**로 남긴다.
base=$(kubectl run h5base --image=curlimages/curl --restart=Never --rm -i --quiet \
  -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://h5web 2>/dev/null)
if [ "$base" != "200" ]; then
  bad "기준선이 200 이 아니다(응답 '$base') — 4단계는 **판정 불가**다. 3단계를 먼저 볼 것"
  SKIP4=1
fi
kubectl apply -f - >/dev/null 2>&1 <<'YML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: h5-deny, namespace: default }
spec:
  podSelector: { matchLabels: { app: h5web } }
  policyTypes: [Ingress]
YML
sleep 8
code=$(kubectl run h5cli2 --image=curlimages/curl --restart=Never --rm -i --quiet --timeout=90s \
  -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://h5web 2>/dev/null)
if [ -n "${SKIP4:-}" ]; then
  info "기준선이 없어 판정하지 않는다 (차단 후 응답 '$code')"
elif [ "$code" != "200" ]; then
  ok "default-deny 가 실제로 막는다 (기준선 200 → 차단 '$code')"
else
  bad "정책이 걸리지 않았다 — **조용한 보안 우회**(ADR-043 M1 의 실패 모드)"
fi
kubectl delete netpol h5-deny >/dev/null 2>&1
# ★ 제거 후 복귀까지 본다. 차단만 확인하면 "정책이 걸렸다" 와 "그 사이에
#   무언가 고장났다" 를 구분할 수 없다. 복귀해야 정책이 원인이라 말할 수 있다.
sleep 8
back=$(kubectl run h5back --image=curlimages/curl --restart=Never --rm -i --quiet \
  -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://h5web 2>/dev/null)
if [ -n "${SKIP4:-}" ]; then
  info "복귀 확인도 건너뛴다 (응답 '$back')"
elif [ "$back" = "200" ]; then
  ok "정책 제거 후 200 으로 복귀 — 차단의 원인이 정책이었다"
else
  bad "정책을 지웠는데 복귀하지 않는다(응답 '$back') — 차단이 정책 때문이 아닐 수 있다"
fi

echo "══════ 5. XDP — 문서가 미지원이라 한 지점"
if command -v cilium >/dev/null 2>&1; then
  mode=$(kubectl -n kube-system exec ds/cilium -- cilium-dbg status 2>/dev/null | grep -i "XDP\|Device Mode" | head -2)
  info "${mode:-XDP 상태 조회 불가}"
fi
info "H5 는 '기능은 정상이나 성능 기준선으로 쓰지 말 것' 이다. 위 1~4 가 통과하면 기능은 확인된 것이고,"
info "성능은 여기서 재지 않는다 — XDP 오프로드가 없으므로 수치가 대표성이 없다."

echo "══════ 정리"
kubectl delete deploy h5web >/dev/null 2>&1; kubectl delete svc h5web >/dev/null 2>&1
echo "  PASS $PASS · FAIL $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  → H5 해소. ADR-051(A안) 이설의 기술 위험이 제거된다."
  echo "    남는 판단은 비용이다: PVC 27개 재생성 · 정적 메모리 분할 · 클러스터 재구축."
else
  echo "  → H5 미해소. 이 상태로 이설하면 PVC 27개를 날린 뒤 같은 실패를 만난다."
fi
