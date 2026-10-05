#!/usr/bin/env bash
# 베어메탈 Ubuntu control-plane k3s 부트스트랩 (2026-10-04)
#
# ★★★ 이 환경이 **새 로컬 서버**다 — WSL2 를 대체한다.
#   실측 노드: Intel NUC15 CRSU9 · 16코어 · 60 GiB · NVMe 915G(854G 여유)
#              Ubuntu 26.04.1 LTS(resolute) · 커널 7.0 · cgroup v2
#   2대가 있고(192.168.0.103 server · 192.168.0.104 agent) **둘 다 필요하다**:
#   플랫폼 CPU 요청이 19,725m 인데 한 노드의 할당가능이 ~15.5 vCPU 다.
#   메모리는 49.3 GiB 요청 / ~54 GiB 라 한 대에 들어가지만 CPU 가 먼저 막는다.
#
# ────────────────────────────────────────────────────────────────
# `bootstrap-wsl-k3s.sh` 와 무엇이 다른가 — 그 차이가 이 파일의 존재 이유다
# ────────────────────────────────────────────────────────────────
#  1. ★★ `--node-ip` · `--tls-san` 을 **명시한다.**
#     WSL 판에는 없다 — 인터페이스가 하나뿐이어서 드러나지 않았다. 여기서는
#     생략하면 k3s 가 주소를 자동으로 고르고, 그 주소가 인증서와 kine 의
#     `masterleases` 에 박힌다. 주소가 바뀌면 apiserver->kubelet 이 끊기고
#     Cilium -> CoreDNS -> Kyverno 순으로 연쇄 붕괴한다(Gotcha 49).
#     더 나쁜 것은 **죽은 주소가 kine 에 남아 k3s 재시작으로도 안 풀리는 것**
#     이다(Gotcha 55) — 그래서 설치 **전에** 주소를 고정해야 하고, 이 스크립트는
#     고정되지 않았으면 기동을 거부한다.
#  2. ★★ `--resolv-conf` 를 상류 파일로 지정한다.
#     Ubuntu 의 `/etc/resolv.conf` 는 `127.0.0.53` 스텁이다. CoreDNS 는
#     `forward . /etc/resolv.conf` 이므로 그 값을 받으면 **파드의 루프백**을
#     가리켜 모든 파드의 외부 DNS 가 죽는다 — 내부 이름은 멀쩡하고 외부만
#     죽어서 원인이 멀다(Gotcha 111 이 WSL 에서 세 층을 헤맨 그 부류).
#  3. zram 을 넣지 않는다.
#     WSL 노드는 43 GiB 였고 zram 32G 이 requests 를 실사용보다 낮게 잡는 것을
#     **안전하게** 만드는 장치였다(Gotcha 101). 60 GiB 에서는 그 전제가 약해지고,
#     여기 스왑은 디스크 파일 8 GiB(zram 보다 훨씬 느리다)라 의지할 대상이
#     아니다. kubelet 의 `LimitedSwap` 은 그대로 둔다 — 안전망으로만 쓴다.
#  4. `mount-rshared` · `mount-debugfs` 를 넣지 않는다.
#     둘 다 WSL2 가 `/` 를 private 으로 두고 debugfs 를 안 올리는 것에 대한
#     우회였다. 실측으로 이 노드는 `/` 가 이미 **shared** 이고 debugfs 가
#     마운트돼 있다 — 그래도 **확인하고, 아니면 멈춘다**(추측하지 않는다).
#  5. 사전 점검에 **주소 고정**과 **DNS 스텁** 검사를 넣었다.
#     WSL 판의 네 검사(MemTotal·BTF·cgroup2·systemd)는 그대로 둔다.
#
# ★ 데이터스토어는 기본값(SQLite/kine)이다 — `--cluster-init`(내장 etcd)을
#   쓰지 않는다. 기계가 2대뿐이라 어차피 HA 정족수(3)가 성립하지 않고, 이
#   레포의 Gotcha 55 가 kine 을 전제로 쓰여 있다. **서버를 3대로 늘릴 날**
#   그때 etcd 로 가되 재구축이 필요하다는 것을 알고 가야 한다.
#
# 사용
#   local/bootstrap-baremetal-k3s.sh                     # server(기본)
#   local/bootstrap-baremetal-k3s.sh --check             # 점검만
#   K3S_URL=https://192.168.0.103:6443 K3S_TOKEN=... \
#     local/bootstrap-baremetal-k3s.sh agent             # agent 조인
#
# ★★ 왜 한 파일에 두 역할을 담는가 — **사전 점검이 같기 때문이다.** BTF·
#   cgroup2·systemd·/ shared·debugfs·주소 고정·DNS 스텁은 server 든 agent 든
#   똑같이 요구된다. 두 파일로 쪼개면 그 목록이 두 곳에 살고 반드시 어긋난다
#   (Gotcha 117 이 이미지 목록에서 실제로 밟은 자리다).
# ★ 토큰은 **환경변수로만** 받고 출력하지 않는다. 서버에서 꺼내는 경로는
#   /var/lib/rancher/k3s/server/node-token 이다.
set -Eeuo pipefail
trap 'echo "[bootstrap][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

# ★★ install-operators.sh 의 ISTIO_VERSION 과 짝이 맞아야 한다(§8-73, Gotcha 47).
#   Istio 1.31 은 k8s **1.32~1.36** 만 지원한다 — 이 값을 1.32 미만으로 내리면
#   메시가 뜨지 않고, 1.36 을 넘기면 Istio 쪽이 지원 밖으로 나간다.
K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_RESOLV="/run/systemd/resolve/resolv.conf"

CHECK=no
ROLE=server
case "${1:-}" in
  --check) CHECK=yes ;;
  agent)   ROLE=agent ;;
  server|"") ROLE=server ;;
  *) echo "사용: $0 [server|agent|--check]" >&2; exit 2 ;;
esac

log()  { echo "[bootstrap] $*"; }
fail() { echo "[bootstrap] FAIL: $*" >&2; exit 1; }
warn() { echo "[bootstrap] WARN: $*" >&2; WARNED=$(( ${WARNED:-0} + 1 )); }

# ── 0. 사전 점검 ────────────────────────────────────────────────
log "사전 점검"

[ "$(id -u)" = 0 ] || fail "root 로 돌릴 것"

# (1) 기본 도구 — curl 이 없으면 k3s 설치 자체가 불가능하다. Ubuntu 26.04
#     데스크톱 설치본에는 **curl 과 git 이 없다**(실측).
for c in curl git python3; do
  command -v "$c" >/dev/null || fail "$c 없음 — apt-get install -y curl git 먼저"
done

# (1-b) ★★ 로컬 빌드 이미지용 전제 — 2026-10-05 에 더했다.
#   `local/build-images.sh` 는 podman 으로 11종을 빌드하고 **모든 노드에**
#   반입한다. 베어메탈 첫 구축에서 둘 다 빠져 있었다:
#     · podman 이 없어 그 스크립트가 첫 빌드에서 죽는다
#     · control-plane -> 다른 노드 ssh 가 안 되면 반입이 **한 노드에만** 들어가고,
#       거기 스케줄되지 않은 파드는 `ImagePullBackOff` 다. 그런데 오류 문구가
#       레지스트리 DNS 실패라 "레지스트리가 없다" 로 읽힌다(Gotcha 175).
#   ★ 그래서 **치명이 아니라 경고**로 둔다 — k3s 자체는 이것 없이도 선다.
#     막아 세우면 "이미지는 나중에" 라는 정상 절차를 못 쓴다.
if ! command -v podman >/dev/null; then
  warn "podman 없음 — local/build-images.sh 가 돌지 않는다 (apt-get install -y podman)"
fi
if [ "$ROLE" = server ]; then
  # 노드가 둘 이상일 때만 뜻이 있다. 지금은 조인 전이라 셀 수 없으므로
  # 키가 있는지만 본다 — 없으면 반입이 이 노드에만 들어간다.
  if [ ! -f /root/.ssh/id_ed25519 ] && [ ! -f /root/.ssh/id_rsa ]; then
    warn "root ssh 키가 없다 — 다른 노드로 이미지 반입이 안 된다. 노드를 더한 뒤:
      ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
      ssh-copy-id -i /root/.ssh/id_ed25519.pub root@<다른 노드>"
  fi
fi

# (2) 커널·런타임 전제 (WSL 판과 같은 네 가지)
MEM_GIB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
[ "$MEM_GIB" -ge 40 ] || fail "MemTotal ${MEM_GIB}GiB — 이 플랫폼은 49.3 GiB 를 요청한다"
[ -r /sys/kernel/btf/vmlinux ] || fail "BTF 없음 — Cilium·Falco·Tetragon CO-RE 불가"
[ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || fail "cgroup v2 아님"
[ "$(ps -p 1 -o comm=)" = systemd ] || fail "PID1 이 systemd 가 아니다"

# (3) ★★ WSL 에서는 유닛으로 만들어 줘야 했던 둘 — 여기서는 **확인만** 한다.
#     istio-cni 가 /var/run/netns 에 진입하려면 / 가 shared 여야 한다.
PROP="$(findmnt -no PROPAGATION /)"
[ "$PROP" = shared ] || fail "/ 전파가 '$PROP' 다 — istio-cni 가 netns 에 못 들어간다"
findmnt -no TARGET /sys/kernel/debug >/dev/null 2>&1 \
  || fail "debugfs 미마운트 — Tetragon·Falco 가 쓴다"

# (4) ★★★ 주소 고정 — 이것이 이 스크립트의 가장 중요한 검사다.
#     DHCP 주소는 `ip addr` 에 **dynamic** 으로 표시된다. k3s 를 깔기 전에
#     고정해야 한다(Gotcha 49·55). 되돌릴 수 없는 비용이 거기서 생긴다.
IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
[ -n "$IFACE" ] || fail "기본 경로 인터페이스를 찾지 못했다"
NODE_IP="${NODE_IP:-$(ip -o -4 addr show dev "$IFACE" scope global | awk '{print $4}' | cut -d/ -f1 | head -1)}"
[ -n "$NODE_IP" ] || fail "$IFACE 에 전역 IPv4 주소가 없다"
if ip -o -4 addr show dev "$IFACE" | grep -qw dynamic; then
  fail "$IFACE 의 주소가 DHCP(dynamic)다. netplan 에 static 으로 박은 뒤 다시 돌릴 것 —
  주소가 바뀌면 인증서와 kine masterleases 가 어긋나고 재시작으로도 풀리지 않는다(Gotcha 49·55)."
fi

# (5) ★★ DNS — k3s/CoreDNS 에 줄 파일이 스텁이 아닌지 본다.
[ -r "$UPSTREAM_RESOLV" ] || fail "$UPSTREAM_RESOLV 가 없다 — systemd-resolved 를 확인할 것"
grep -qE '^nameserver[[:space:]]+[0-9]' "$UPSTREAM_RESOLV" \
  || fail "$UPSTREAM_RESOLV 에 실제 상류 nameserver 가 없다"
if grep -qE '^nameserver[[:space:]]+127\.0\.0\.53' "$UPSTREAM_RESOLV"; then
  fail "$UPSTREAM_RESOLV 가 스텁(127.0.0.53)을 가리킨다 — 파드의 외부 DNS 가 죽는다"
fi

log "OK — ${MEM_GIB}GiB · $(nproc)코어 · BTF · cgroup2 · systemd · / shared · debugfs"
log "     노드 IP ${NODE_IP} (${IFACE}, static) · DNS $(awk '/^nameserver/{printf "%s ", $2}' "$UPSTREAM_RESOLV")"
log "     역할 ${ROLE}"

# (6) agent 는 서버 주소와 토큰이 있어야 한다. 없으면 설치 스크립트가 **server**
#     로 돌아버려 두 번째 클러스터가 생긴다 — 조용히 틀리는 자리라 먼저 막는다.
if [ "$ROLE" = agent ] && [ "$CHECK" != yes ]; then
  [ -n "${K3S_URL:-}" ]   || fail "agent 인데 K3S_URL 이 없다 (예: https://192.168.0.103:6443)"
  [ -n "${K3S_TOKEN:-}" ] || fail "agent 인데 K3S_TOKEN 이 없다 — 서버의 /var/lib/rancher/k3s/server/node-token"
  log "     서버 ${K3S_URL} · 토큰 ${#K3S_TOKEN}자 (값은 출력하지 않는다)"
fi

if [ "$CHECK" = yes ]; then
  # ★ 경고는 치명이 아니지만 **셋을 보여 주고 끝낸다** — 조용히 넘기면
  #   "점검 통과" 로 읽히고 나중에 이미지 반입에서 막힌다.
  log "점검만 하고 끝낸다 (경고 ${WARNED:-0}건)"
  exit 0
fi


# ── 1. 커널 sysctl (inotify) ───────────────────────────────────
# ★★★ 기본값 `fs.inotify.max_user_instances=128` 은 파드 100여 개짜리 노드에서
#   모자란다. 실측(2026-10-06, local 파드 128개): 이미 **192개**가 쓰이고 있어
#   Falco 가 `Error: could not initialize inotify handler` 로 CrashLoop 했고,
#   그 DaemonSet 이 Healthy 가 되지 않아 **wave 7 에서 동기화가 섰다.**
# ★ 증상이 Falco 를 가리킨다 — 커널 버전과 eBPF 드라이버를 먼저 의심하게
#   되는데(Gotcha 174 의 MongoDB 와 같은 모양) 원인은 노드의 자원 한도다.
#   판정은 둘을 대조하는 것이다:
#       sysctl -n fs.inotify.max_user_instances
#       find /proc/*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l
# ★★ 노드 상태이지만 **이 스크립트가 넣는다** — 레포 밖에 두면 재구축 때
#   빠뜨리고, 빠뜨린 증상이 원인과 아주 멀다. §25-0 목록을 늘리는 것보다
#   스크립트가 하는 쪽이 낫다.
log "sysctl 튜닝 (inotify)"
cat > /etc/sysctl.d/99-oim-k8s.conf <<'SYSCTL'
# OneinchMarket k3s 노드 - pods 100+ 를 전제로 한 한도.
# default (instances 128) 에서는 Falco 가 inotify handler 를 얻지 못한다.
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
SYSCTL
chmod 0644 /etc/sysctl.d/99-oim-k8s.conf
sysctl -q --system
# ★ 되읽어 확인한다 — 적용되지 않았으면 멈춘다(Gotcha 86: 조용한 오설정보다
#   실패가 낫다).
GOT_INST=$(sysctl -n fs.inotify.max_user_instances)
[ "$GOT_INST" -ge 1024 ] || fail "inotify instances 가 ${GOT_INST} 다 - sysctl 이 적용되지 않았다"
log "     fs.inotify.max_user_instances=${GOT_INST}"
# ── 2. kubelet 설정 ────────────────────────────────────────────
# NodeSwap·swapBehavior·maxPods 는 kubelet 설정 파일에만 있는 필드다
# (대응 CLI 플래그가 없어 `unknown flag` 로 기동을 거부한다).
# ★ 설치 시점에만 정할 수 있으므로 여기서 넣는다.
log "kubelet 설정 설치"
mkdir -p /etc/rancher/k3s
install -m 0644 "${REPO_ROOT}/local/kubelet-config.yaml" /etc/rancher/k3s/kubelet-config.yaml

# ── 3. k3s server ──────────────────────────────────────────────
# --flannel-backend=none   Cilium 이 CNI 다. 설치 전까지 NotReady 가 정상
# --disable-network-policy  Cilium 이 정책을 한다
# --disable traefik         진입점은 Istio Gateway 다(ADR-071)
# --disable servicelb       NodePort 로 받는다. LoadBalancer 는 영원히 Pending 이다
log "k3s ${K3S_VERSION} 설치 (role=${ROLE} node-ip=${NODE_IP})"
if [ "$ROLE" = agent ]; then
  # ★ agent 에는 --flannel-backend / --disable / --tls-san 이 없다. 그것들은
  #   서버(컨트롤 플레인)의 인자다. agent 가 공유해야 하는 것은 셋이다:
  #   노드 IP 고정 · 상류 resolv.conf · kubelet 설정(NodeSwap·maxPods).
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    K3S_URL="${K3S_URL}" K3S_TOKEN="${K3S_TOKEN}" \
    sh -s - agent \
      --node-ip "${NODE_IP}" \
      --resolv-conf "${UPSTREAM_RESOLV}" \
      --kubelet-arg=config=/etc/rancher/k3s/kubelet-config.yaml \
    || log "설치 스크립트가 비정상 종료했다 — 아래에서 실제 상태를 확인한다"

  log "k3s-agent 기동 대기"
  for i in $(seq 1 60); do
    systemctl is-active --quiet k3s-agent && break
    sleep 3
  done
  systemctl is-active k3s-agent | sed 's/^/[bootstrap]   k3s-agent=/'
  # ★ 여기서는 kubeconfig 가 없다(agent 에는 apiserver 가 없다). 조인 성공
  #   판정은 **서버에서** `kubectl get node` 로 해야 한다 — 이 노드에서
  #   서비스가 active 인 것은 "붙었다" 를 뜻하지 않는다.
  log "조인 판정은 서버에서: kubectl get node -o wide"
  log "완료 (agent)"
  exit 0
fi

curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
  --write-kubeconfig-mode 644 \
  --node-ip "${NODE_IP}" \
  --tls-san "${NODE_IP}" \
  --resolv-conf "${UPSTREAM_RESOLV}" \
  --disable traefik \
  --disable servicelb \
  --flannel-backend=none \
  --disable-network-policy \
  --kubelet-arg=config=/etc/rancher/k3s/kubelet-config.yaml \
  || log "설치 스크립트가 비정상 종료했다 — 아래에서 실제 상태를 확인한다"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p ~/.kube && cat /etc/rancher/k3s/k3s.yaml > ~/.kube/config && chmod 600 ~/.kube/config

log "k3s 기동 대기 (CNI 부재로 NotReady 가 정상)"
for i in $(seq 1 60); do kubectl get node >/dev/null 2>&1 && break; sleep 3; done
kubectl get node -o wide

# ★ 실제로 그 주소로 섰는지 확인한다 — 인자를 줬다고 반영됐다고 가정하지 않는다.
GOT_IP="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
[ "$GOT_IP" = "$NODE_IP" ] || fail "노드 InternalIP 가 ${GOT_IP} 다 (기대 ${NODE_IP})"
log "노드 InternalIP = ${GOT_IP} 확인"

# ── 4. StorageClass 'standard' 별칭 ────────────────────────────
# 배포 블로커 #5 — 전 PVC 가 존재하지 않는 'standard' 를 참조한다.
# ★★ 2노드가 되면 성질이 바뀐다: local-path 는 **노드 고정** 볼륨이라
#   PVC 를 받은 파드는 그 노드를 떠날 수 없다. ADR-015(스토리지)가 Open 인
#   이유가 여기다 — 분산 스토리지 없이는 상태 있는 워크로드의 HA 가 성립하지
#   않는다(Gotcha 35 와 같은 뿌리).
log "StorageClass 'standard' (local-path 의 default 해제)"
kubectl apply -f "${REPO_ROOT}/local/storageclass-standard.yaml"
# ★★ `local-path` 를 **기다려야 한다.** 갓 설치한 클러스터에서는 k3s 의
#   local-storage 애드온이 아직 적용되지 않아 그 SC 가 없고, 바로 patch 하면
#   `storageclasses.storage.k8s.io "local-path" not found` 로 죽는다
#   (실측 2026-10-04: 설치 직후 18초쯤 뒤에 나타났다). WSL 판은 이미 돌던
#   클러스터에 돌려서 드러나지 않았다 — "있을 것이다" 를 전제로 쓴 코드다.
log "local-path SC 대기 (k3s 애드온이 적용될 때까지)"
for i in $(seq 1 40); do
  kubectl get storageclass local-path >/dev/null 2>&1 && break
  sleep 3
done
kubectl get storageclass local-path >/dev/null 2>&1 \
  || fail "local-path SC 가 120초 안에 생기지 않았다 — k3s 애드온을 확인할 것"
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null
# ★ 기본 SC 가 **하나도 없는 것**이 의도다 — 둘이면 storageClassName 을 생략한
#   PVC 의 동작이 정의되지 않는다(Gotcha 5). 전 PVC 가 명시하도록 고쳐져 있다.
DEFAULTS="$(kubectl get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{" "}{end}' | tr ' ' '\n' | grep -c true || true)"
[ "$DEFAULTS" = 0 ] || fail "기본 SC 가 ${DEFAULTS}개 남았다 — 0개여야 한다"
kubectl get storageclass

# ── 5. 에이전트 조인에 필요한 것 ────────────────────────────────
log "에이전트(192.168.0.104) 조인용:"
log "  K3S_URL=https://${NODE_IP}:6443"
log "  토큰:   /var/lib/rancher/k3s/server/node-token  (값은 출력하지 않는다)"

log "완료. 다음: local/install-platform.sh (Cilium · Gateway API)"
# ★★ Cilium 버전은 k3s 와 짝이 맞아야 한다 — install-platform.sh 가 1.20.2 로
#   정정돼 있다(1.16/1.19 는 k8s 1.36 을 지원하지 않는다, Gotcha 47 부류).
# ★ k8sServiceHost=127.0.0.1 을 **섣불리 바꾸지 말 것.** k3s 에이전트는
#   127.0.0.1:6443 에 로컬 로드밸런서를 띄워 서버로 전달하므로 다중 노드에서도
#   그 값이 성립한다 — 다만 이것은 **104 가 조인한 뒤 실제로 확인할 일**이다
#   (에이전트의 cilium 파드가 apiserver 에 붙는지).
log "노드 Ready 가 되려면 CNI 가 필요하다 — 지금 NotReady 인 것이 정상이다"
