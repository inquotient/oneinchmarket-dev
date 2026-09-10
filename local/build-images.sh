#!/usr/bin/env bash
# 커스텀 이미지 8종 빌드 후 k3s containerd 로 직접 반입한다.
# 레지스트리(registry.oneinchmarket.co.kr)를 참조하는 매니페스트가 없고
# imagePullSecrets 도 없으므로, 로컬에서는 import 가 정답이다.
#
# 왜 podman 인가 —
#   ① 데몬이 없다. 빌드가 끝나면 메모리를 전혀 남기지 않는다.
#      48GB 예산에서 상주 데몬 하나가 아깝다.
#   ② docker.io 의 containerd 는 k3s 와 소켓 경로를 다툰다. 이 호스트에서는
#      /run/containerd/containerd.sock 이 디렉터리로 존재해 기동에 실패했다
#      (Docker Desktop WSL 통합 잔재로 추정):
#        containerd: failed to create unix socket ...: is a directory
#   ③ Docker Desktop 은 자체 WSL 배포판을 띄워 같은 예산을 경합한다.
set -Eeuo pipefail
trap 'echo "[build][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log() { echo "[build] $*"; }

# ★★ 단건 선택 — 인자를 주면 그 이미지만 빌드한다.
#   왜 필요한가: 한 이미지의 한 줄을 고치려고 9종을 통째로 빌드하는 것은
#   Ranger Maven 빌드와 HBase tarball 때문에 아주 비싸다. 그래서 실제로
#   "고쳤지만 반영하지 않은" 상태가 생겼다(§8-94 의 ranger-usersync).
#   반입·push 목록도 같은 선택을 따른다 — 빌드만 하고 반입을 잊으면
#   파드는 옛 이미지로 계속 돈다(IfNotPresent 다).
#
# 사용
#   local/build-images.sh                      # 10종 전부
#   local/build-images.sh ranger-usersync      # 하나만
#   local/build-images.sh livy jenkins         # 여럿
#   local/build-images.sh --list               # 이름 목록
ALL_IMAGES="spark-iceberg livy ranger-usersync hbase ranger-hdfs-plugin ranger-hbase-plugin ranger-hive-plugin jenkins proxysql kafka-connect"
if [ "${1:-}" = "--list" ]; then
  for n in $ALL_IMAGES; do echo "  $n"; done
  exit 0
fi
ONLY="$*"
for n in $ONLY; do
  case " $ALL_IMAGES " in
    *" $n "*) ;;
    *) echo "[build] 그런 이미지가 없다: $n (--list 로 확인할 것)" >&2; exit 1;;
  esac
done
[ -n "$ONLY" ] && log "선택: $ONLY"
want() {
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0;; esac
  return 1
}

# k3s 와 경합하지 않도록 도커 계열 서비스를 내린다 (패키지는 남긴다)
for s in docker.socket docker containerd; do
  systemctl list-unit-files "$s"* >/dev/null 2>&1 && sudo systemctl disable --now "$s" 2>/dev/null || true
done

# ★ 빌드는 --network host 로 한다.
#   `podman network ls` 에 k3s 가 만든 `cilium`(cilium-cni) 네트워크가 함께
#   보이고, 빌드 컨테이너가 그쪽을 잡으면 밖으로 나가지 못한다.
#   실제로 HBase tarball 을 받다 curl(28) Failed to connect 로 죽었다.
#   호스트에서는 되고 컨테이너에서만 안 되므로 원인을 찾는 데 시간이 든다.
if ! command -v podman >/dev/null 2>&1; then
  log "podman 설치"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman
fi
podman --version

if want spark-iceberg; then
  log "oneinch/spark-iceberg 빌드"
  sudo podman build --format docker --network host \
    -t oneinch/spark-iceberg:latest -t oneinch/spark-iceberg:3.5.6 \
    "${REPO_ROOT}/docker/spark-iceberg"
fi

if want livy; then
  log "oneinch/livy 빌드"
  sudo podman build --format docker --network host \
    -t oneinch/livy:latest -t oneinch/livy:0.9.0-incubating \
    "${REPO_ROOT}/docker/livy"
fi

if want ranger-usersync; then
  log "oneinch/ranger-usersync 빌드"
  # Ranger UserSync 는 공식 이미지가 없다. Dockerfile 은 upstream 에 있다
  #   apache/ranger @ release-ranger-2.9.0
  #     dev-support/ranger-docker/Dockerfile.ranger-usersync
  # 베이스(apache/ranger-base)와 릴리스 tarball 모두 Apache 배포물이다.
  sudo podman build --format docker --network host \
    -t oneinch/ranger-usersync:latest -t oneinch/ranger-usersync:2.9.0 \
    "${REPO_ROOT}/docker/ranger-usersync"
fi

if want hbase; then
  log "oneinch/hbase 빌드"
  # HBase 는 공식 이미지가 없다(Docker Hub 에 apache/hbase 저장소가 없음).
  # v1/hbase/Dockerfile 을 고쳐 docker/hbase 로 옮겼다 — 상세는 그 파일 주석.
  sudo podman build --format docker --network host \
    -t oneinch/hbase:latest -t oneinch/hbase:3.0.0 \
    "${REPO_ROOT}/docker/hbase"
fi

if want ranger-hdfs-plugin; then
  log "oneinch/ranger-hdfs-plugin 빌드"
  # Ranger 2.9 의 REST 클라이언트는 Jersey 1 을 쓰는데 Hadoop 3.5 가 그것을
  # 걷어냈다. upstream 이 master 에서 이미 Jersey 2 로 옮겼고, 그 수정을 2.9.0 에
  # 백포트해 빌드한다 — 상세와 실패했던 우회들은
  # docker/ranger-hdfs-plugin/Dockerfile 주석과 §8-68 에 있다.
  # Ranger 3.0.0 이 릴리스되면 이 이미지는 지운다.
  # ★ 오래 걸린다 — Maven 이 Ranger 부모 모듈 의존성을 받는다.
  sudo podman build --format docker --network host \
    -t oneinch/ranger-hdfs-plugin:latest -t oneinch/ranger-hdfs-plugin:2.9.0-jersey2 \
    "${REPO_ROOT}/docker/ranger-hdfs-plugin"
fi

if want ranger-hbase-plugin; then
  log "oneinch/ranger-hbase-plugin 빌드"
  # HBase 3 이 구 protobuf 패키지를 걷어내 Ranger 2.9 코프로세서가 적재되지
  # 못한다(마스터 ABORT). ★ 이것은 §8-68 의 Jersey 건과 달리 **백포트가 아니다** —
  # Ranger master 조차 hbase 2.6.0 을 겨냥해 대조할 구현이 없다. 우리가 이식했다.
  # 상세는 docker/ranger-hbase-plugin/Dockerfile 주석과 §8-69.
  # ★ docker/hbase 의 HBASE_VERSION 과 **짝이 맞아야 한다.**
  # ★ 오래 걸린다 — JDK 8/17 두 단계로 Ranger 를 빌드한다.
  sudo podman build --format docker --network host \
    -t oneinch/ranger-hbase-plugin:latest -t oneinch/ranger-hbase-plugin:2.9.0-hbase3 \
    "${REPO_ROOT}/docker/ranger-hbase-plugin"
fi

if want ranger-hive-plugin; then
  log "oneinch/ranger-hive-plugin 빌드"
  # Hive 4 가 HiveConf.ConfVars 상수를 개명하고 인덱스 연산을 걷어내 Ranger 2.9
  # Hive 플러그인이 기동하지 못한다(NoSuchFieldError: PREEXECHOOKS).
  # ★ 이것은 §8-69 의 HBase 와 달리 **백포트**다 — upstream master 가 Hive 4 를
  # 겨냥한다. 상세는 docker/ranger-hive-plugin/Dockerfile 주석과 §8-70.
  sudo podman build --format docker --network host \
    -t oneinch/ranger-hive-plugin:latest -t oneinch/ranger-hive-plugin:2.9.0-hive4 \
    "${REPO_ROOT}/docker/ranger-hive-plugin"
fi

if want jenkins; then
  log "oneinch/jenkins 빌드"
  # 공식 이미지에는 플러그인이 없다. JCasC 로 관리자 계정을 선언하려면
  # configuration-as-code 플러그인이 필요하고, 런타임에 받으면 SEC-512 다.
  # 상세는 docker/jenkins/Dockerfile 주석.
  sudo podman build --format docker --network host \
    -t oneinch/jenkins:latest -t oneinch/jenkins:2.568.3-lts \
    "${REPO_ROOT}/docker/jenkins"
fi

if want proxysql; then
  log "oneinch/proxysql 빌드"
  # ProxySQL 은 패키지와 컨테이너 이미지의 릴리스 주기가 다르다 — 4.x 는
  # 릴리스 자산이 rpm·deb·tar.gz 뿐이고 Docker Hub 에도 ghcr 에도 이미지가 없다.
  # 그래서 릴리스 tarball 로 직접 굽는다. 상세는 docker/proxysql/Dockerfile 과 §8-76.
  # ★ 업스트림이 4.x 컨테이너를 내기 시작하면 이 항목과 docker/proxysql 을 지울 것.
  sudo podman build --format docker --network host \
    -t oneinch/proxysql:latest -t oneinch/proxysql:4.0.11 \
    "${REPO_ROOT}/docker/proxysql"
fi

if want kafka-connect; then
  log "oneinch/kafka-connect 빌드"
  # 브로커와 **같은 베이스**(apache/kafka:4.3.1) 위에 Debezium MariaDB
  # 커넥터만 얹는다. 상류의 quay.io/debezium/connect 는 715 MiB 에 쓰지 않는
  # 커넥터가 14종 더 들어 있어 취약점 표면만 늘린다 — 이 클러스터는 Trivy
  # Operator·Dependency-Track 이 상시로 돈다. 상세는
  # docker/kafka-connect/Dockerfile 주석.
  #
  # ★ 태그가 두 버전을 함께 담는 이유: 이 이미지는 **조합**이라 어느 한쪽만
  #   올려도 다른 이미지가 된다. kafka-statefulset.yaml 의 image 를 올릴 때
  #   이 태그와 Dockerfile 의 FROM 을 함께 움직일 것.
  sudo podman build --format docker --network host \
    -t oneinch/kafka-connect:latest -t oneinch/kafka-connect:4.3.1-dbz3.6.2 \
    "${REPO_ROOT}/docker/kafka-connect"
fi

# ── GitLab 컨테이너 레지스트리로 push ──────────────────────────────
#
# ★ 왜 push 하는가 — 파드를 띄우는 데는 필요 없다(아래 containerd 반입으로
#   충분하다). 필요한 것은 **Trivy Operator** 다. 스캔 Job 은 파드라 노드의
#   containerd 소켓을 볼 수 없어 이미지를 레지스트리에서 직접 당긴다.
#   레지스트리에 없던 시절 이 9종은 **한 번도 스캔되지 않았다**(§8-79):
#     unable to find the specified image "oneinch/spark-iceberg:3.5.6"
#     in ["docker" "containerd" "podman" "remote"]
#
# ★ 그래서 **push 와 반입을 둘 다** 한다. 순환 의존을 피하기 위해서다 —
#   GitLab 은 wave 5 인데 이 이미지를 쓰는 워크로드는 wave 3 에 있다.
#   반입 덕에 파드는 레지스트리 없이도 뜨고(IfNotPresent), 레지스트리는
#   Trivy 가 당길 때만 쓰인다.
#
# ★ 레지스트리가 아직 없으면 **건너뛴다.** 클러스터를 처음 세울 때는
#   GitLab 자체가 없으므로 여기서 실패하면 안 된다.
REGISTRY_SVC="gitlab-registry"
REGISTRY_NS="local"
# ★★ 이미지 이름은 **FQDN** 이어야 한다 — 짧은 이름이었다.
#   매니페스트는 gitlab-registry.local.svc.cluster.local:5050/... 을
#   참조하는데 이 스크립트는 gitlab-registry:5050/... 로 반입했다.
#   그러면 **빌드는 성공하고 파드는 옛 이미지로 계속 돌다**
#   (imagePullPolicy: IfNotPresent 라 이미 있는 이름을 그대로 쓴다).
#   오류가 한 줄도 나지 않는다 — §8-95.
REGISTRY_FQDN="${REGISTRY_SVC}.${REGISTRY_NS}.svc.cluster.local"
REGISTRY_HOST="${REGISTRY_FQDN}:5050"

# ★ 그리고 믿지 말고 매니페스트에 물어본다.
#   위 값을 고치더라도 다음에 또 어긋나면 같은 일이 조용히 반복된다.
MANIFEST_PREFIX="$(grep -rho 'image: *[A-Za-z0-9./_:-]*/oneinch/' "${REPO_ROOT}/kubernetes" 2>/dev/null                    | sed 's/^image:[[:space:]]*//; s#/oneinch/$##' | sort -u | head -1)"
if [ -n "$MANIFEST_PREFIX" ] && [ "$MANIFEST_PREFIX" != "$REGISTRY_HOST" ]; then
  log "★★ 반입 이름이 매니페스트와 다르다 — 중단한다"
  log "     스크립트  : $REGISTRY_HOST"
  log "     매니페스트: $MANIFEST_PREFIX"
  log "   그대로 두면 빌드는 성공하고 파드는 옛 이미지로 돌다."
  exit 1
fi

# Secret(dockerconfigjson)에서 토큰만 꺼내는 조각. 셸 따옴표 안에서
# 한 줄로 쓰면 읽을 수 없어 변수로 뺀다.
REG_TOKEN_PY='
import base64, json, sys
sec = json.load(sys.stdin)
cfg = json.loads(base64.b64decode(sec["data"][".dockerconfigjson"]).decode())
sys.stdout.write(list(cfg["auths"].values())[0]["password"])
'

push_to_registry() {
  if ! kubectl get svc -n "$REGISTRY_NS" "$REGISTRY_SVC" >/dev/null 2>&1; then
    log "레지스트리 Service 가 없다 — push 를 건너뛴다(반입만 한다)"
    return 1
  fi
  if ! kubectl get secret -n "$REGISTRY_NS" gitlab-registry-secret >/dev/null 2>&1; then
    log "gitlab-registry-secret 이 없다 — local/gitlab-registry-bootstrap.sh --secret 를 먼저 돌릴 것"
    return 1
  fi

  # ★ 노드는 CoreDNS 를 쓰지 않으므로 이름을 스스로 풀지 못한다.
  #   ClusterIP 를 /etc/hosts 에 박는다 — **매번 조회해서** 다시 쓴다.
  #   Service 를 재생성하면 ClusterIP 가 바뀌는데, 낡은 값이 남으면
  #   push 가 타임아웃으로 죽고 원인이 멀어진다.
  #   ★★ 127.0.0.1 을 쓰지 말 것 — /etc/hosts 는 **kubelet 도 읽는다.**
  #     루프백을 박아 두면 kubelet 의 이미지 pull 이
  #     `dial tcp 127.0.0.1:5050: connect: connection refused` 로 깨진다.
  local cip
  cip="$(kubectl get svc -n "$REGISTRY_NS" "$REGISTRY_SVC" \
          -o jsonpath='{.spec.clusterIP}')"
  if [ -z "$cip" ] || [ "$cip" = "None" ]; then
    log "ClusterIP 를 읽지 못했다 — push 를 건너뛴다"
    return 1
  fi
  # ★ FQDN 과 짧은 이름을 한 줄에 함께 박는다 — podman 은 REGISTRY_HOST(FQDN)로
  #   붙고, 짧은 이름은 수작업 시험에 쓰인다.
  sudo sed -i "/[[:space:]]${REGISTRY_FQDN}\$/d; /[[:space:]]${REGISTRY_SVC}\$/d; /[[:space:]]${REGISTRY_FQDN}[[:space:]]/d" /etc/hosts
  echo "${cip} ${REGISTRY_FQDN} ${REGISTRY_SVC}" | sudo tee -a /etc/hosts >/dev/null
  log "  ${REGISTRY_FQDN} -> ${cip} (/etc/hosts)"

  # 토큰은 Secret 이 정본이다 — 사본을 따로 두지 않는다.
  local tokfile; tokfile="$(mktemp)"
  # ★ jsonpath 의 `.dockerconfigjson` 은 앞에 역슬래시가 필요하다(키 이름에
  #   점이 들어 있다). 빠뜨리면 **빈 문자열**이 나오고 오류는 나지 않는다 —
  #   그대로 로그인하면 "invalid username/password" 로 엉뚱한 곳을 의심하게 된다.
  kubectl get secret -n "$REGISTRY_NS" gitlab-registry-secret -o json \
    | python3 -c "$REG_TOKEN_PY" > "$tokfile"

  # 평문 HTTP 다 — 클러스터 안에서만 노출되고 ambient mTLS 가 감싼다.
  if ! sudo podman login "$REGISTRY_HOST" -u k8s-image-pull         --password-stdin --tls-verify=false < "$tokfile" >/dev/null 2>&1; then
    rm -f "$tokfile"
    log "레지스트리 로그인 실패 — 토큰이 만료됐거나 GitLab 이 재시작하며"
    log "  /etc/gitlab 의 db_key_base 가 바뀌었을 수 있다(§8-79)."
    log "  local/gitlab-registry-bootstrap.sh --secret 로 재발급할 것"
    return 1
  fi
  rm -f "$tokfile"
  return 0
}

PUSH_OK=0
if push_to_registry; then PUSH_OK=1; fi

log "k3s containerd 로 반입 + 레지스트리 push"
# ★ 매니페스트가 참조하는 **정확한 이름**을 반입해야 한다.
#   2026-09-07 부터 그 이름에는 레지스트리 호스트가 붙는다
#   (gitlab-registry.local.svc.cluster.local:5050/oneinch/...). 접두가 빠지면 파드가
#   ImagePullBackOff 로 멈춘다 — 예전에 ranger-hdfs-plugin 이 그랬다.
# ★ :latest 는 반입도 push 도 하지 않는다. 매니페스트가 쓰지 않고
#   Kyverno disallow-latest 가 막는 이름이다.
for img in oneinch/spark-iceberg:3.5.6 \
           oneinch/livy:0.9.0-incubating \
           oneinch/ranger-usersync:2.9.0 \
           oneinch/hbase:3.0.0 \
           oneinch/jenkins:2.568.3-lts \
           oneinch/proxysql:4.0.11 \
           oneinch/ranger-hdfs-plugin:2.9.0-jersey2 \
           oneinch/ranger-hbase-plugin:2.9.0-hbase3 \
           oneinch/kafka-connect:4.3.1-dbz3.6.2 \
           oneinch/ranger-hive-plugin:2.9.0-hive4; do
  # ★ 빌드하지 않은 것을 반입하면 옛 레이어가 그대로 올라간다.
  base="${img%%:*}"; want "${base#oneinch/}" || continue
  ref="${REGISTRY_HOST}/${img}"
  sudo podman tag "localhost/${img}" "$ref"
  sudo podman save --format docker-archive "$ref"     | sudo k3s ctr -n k8s.io images import --base-name "$ref" - >/dev/null
  log "  imported $ref"
  if [ "$PUSH_OK" = "1" ]; then
    if sudo podman push --tls-verify=false "localhost/${img}" "$ref" >/dev/null 2>&1; then
      log "  pushed   $ref"
    else
      log "  ★ push 실패 $ref — Trivy 가 이 이미지를 스캔하지 못한다"
    fi
  fi
done

log "반입 확인"
sudo k3s ctr -n k8s.io images ls 2>/dev/null | awk '{print $1}' | grep oneinch || true
if [ "$PUSH_OK" != "1" ]; then
  log "★ 레지스트리 push 를 건너뛰었다 — Trivy Operator 는 이 이미지들을"
  log "  스캔하지 못한다. GitLab 이 뜬 뒤 이 스크립트를 다시 돌릴 것."
fi

# ── imagePullSecrets 누락 검사 ──────────────────────────────────────
# ★★ push 가 성공해도 **당겨 오는 쪽**이 빠지면 소용이 없다.
#   2026-09-11 실측: kafka-connect 만 `imagePullSecrets` 가 없었고, 그 탓에
#   Trivy 가 익명으로 토큰을 요청해 `DENIED: access forbidden` 을 받아
#   **스캔 리포트가 0건**이었다. 파드는 잘 뜬다 — 이미지가 이미 노드에 있고
#   IfNotPresent 였기 때문이다. 즉 **공급망 구멍이 생기고도 아무 증상이
#   없는** 부류다(Gotcha 85 와 같은 구조).
#   ★ 그래서 값을 고치는 것으로 끝내지 않고 **렌더에서 센다.**
if command -v kubectl >/dev/null 2>&1; then
  log "imagePullSecrets 누락 검사 (oneinch/* 를 쓰는 워크로드)"
  MISSING=$(kubectl kustomize "${REPO_ROOT}/kubernetes/overlays/local" 2>/dev/null | python3 -c '
import sys, yaml
bad = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        continue
    t = d["spec"].get("template")
    if not t:
        continue
    sp = t["spec"]
    imgs = [c.get("image", "") for c in sp.get("containers", []) + sp.get("initContainers", [])]
    if any("oneinch/" in i for i in imgs) and not sp.get("imagePullSecrets"):
        bad.append("%s/%s" % (d["kind"], d["metadata"]["name"]))
print(" ".join(bad))
' 2>/dev/null)
  if [ -n "${MISSING:-}" ]; then
    log "  ★ imagePullSecrets 가 없는 워크로드: ${MISSING}"
    log "    → Trivy 가 스캔하지 못하고, 노드가 이미지를 잃으면 뜨지도 않는다"
    exit 1
  fi
  log "  누락 없음"
fi
log "완료 — 상주 데몬 없음"
