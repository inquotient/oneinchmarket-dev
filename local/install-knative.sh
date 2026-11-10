#!/usr/bin/env bash
# Knative 설치 — local 클러스터용(오퍼레이터 계층 · ArgoCD 밖). 2026-11-10 사용자 결정.
#   bash local/install-knative.sh            # Serving + net-gateway-api + Eventing(Kafka 브로커)
#   bash local/install-knative.sh --eventing # Eventing 만(Serving 이 이미 있을 때)
#   SKIP_EVENTING=1 bash local/install-knative.sh  # Serving 만
#   bash local/install-knative.sh --check    # 설치 상태만 본다(0 정상 · 1 문제 · 2 측정 불가)
#
# ★ 구성: Serving + net-gateway-api(기존 Istio Gateway `local/ingress` 에 HTTPRoute 로 붙는다).
#   클러스터 쪽 전제(knative-local Gateway · NetworkPolicy)는 git 에 있다 — kubernetes/overlays/local/knative/.
#   **ArgoCD 가 그것을 먼저 적용해야 한다** — 없으면 cluster-local 라우트가 붙을 게이트웨이가 없다.
# ★ 판: 1.24.0(2026-10-27) — 최소 k8s 1.35(이 클러스터 1.36). net-gateway-api 1.24 는 Istio 1.28 ·
#   Gateway API v1.4.1 로 시험됐고 여기는 1.31 · v1.6.0 이다 — 그래서 끝에서 실제 요청으로 확인한다.
# ★ 릴리스 YAML 은 `curl -f` + 알려진 이름이 들어 있는지로 가드한다(Gotcha 148 — 404 본문이 exit 0 으로 온다).
# ★ helm 을 쓰지 않는다 — Knative 는 릴리스 YAML 이 정식 설치 경로다.
set -Eeuo pipefail
trap 'echo "[knative][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

KNATIVE_VERSION="${KNATIVE_VERSION:-knative-v1.24.0}"
# 호스트 = <이름>-<네임스페이스>.oneinchmarket.local — 와일드카드 인증서가 한 단계만 덮는다.
KNATIVE_DOMAIN="${KNATIVE_DOMAIN:-oneinchmarket.local}"
DL="${DL:-/tmp/knative-${KNATIVE_VERSION}}"
log() { echo "[knative] $*"; }

fetch() {  # fetch <repo-path> <파일> <반드시 들어 있어야 할 문자열>
  mkdir -p "$DL"
  curl -fsSL --max-time 180 "https://github.com/$1/releases/download/${KNATIVE_VERSION}/$2" -o "$DL/$2"
  grep -q -- "$3" "$DL/$2" || { echo "[knative] $2 가 이상하다($(wc -c <"$DL/$2") 바이트) — '$3' 없음" >&2; exit 1; }
}

check() {
  local rc=0 d
  kubectl get ns knative-serving >/dev/null 2>&1 || { echo "[측정 불가] knative-serving 네임스페이스가 없다"; return 2; }
  for d in activator autoscaler controller webhook net-gateway-api-controller net-gateway-api-webhook; do
    if [ "$(kubectl -n knative-serving get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
      echo "[ok]  knative-serving/$d"
    else
      echo "[FAIL] knative-serving/$d 가 Available 이 아니다"; rc=1
    fi
  done
  local cls; cls=$(kubectl -n knative-serving get cm config-network -o jsonpath='{.data.ingress-class}')
  [ "$cls" = "gateway-api.ingress.networking.knative.dev" ] && echo "[ok]  ingress-class=$cls" || { echo "[FAIL] ingress-class=$cls"; rc=1; }
  kubectl -n local get gateway knative-local >/dev/null 2>&1 && echo "[ok]  local/knative-local Gateway" \
    || { echo "[FAIL] local/knative-local Gateway 가 없다 — ArgoCD 동기화(kubernetes/overlays/local/knative)를 먼저"; rc=1; }
  kubectl get ns kn >/dev/null 2>&1 && echo "[ok]  Knative Service 네임스페이스 kn" \
    || { echo "[FAIL] 네임스페이스 kn 이 없다 — Application oneinchmarket-local-kn(argocd/applications)을 적용할 것"; rc=1; }
  if kubectl get ns knative-eventing >/dev/null 2>&1; then
    for d in eventing-controller eventing-webhook kafka-controller kafka-webhook-eventing kafka-broker-receiver; do
      if [ "$(kubectl -n knative-eventing get deploy "$d" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
        echo "[ok]  knative-eventing/$d"
      else echo "[FAIL] knative-eventing/$d 가 Available 이 아니다"; rc=1; fi
    done
    # ★ dispatcher 는 kafka-controller 의 스케줄러가 replicas 를 정한다 — 트리거가 0개면 replicas 0 이 정상이다
    #   (2026-11-10 실측: 설치 직후 spec.replicas=0). ready >= spec 으로 판정한다.
    local want got
    want=$(kubectl -n knative-eventing get sts kafka-broker-dispatcher -o jsonpath='{.spec.replicas}' 2>/dev/null)
    got=$(kubectl -n knative-eventing get sts kafka-broker-dispatcher -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ -n "$want" ] && [ "${got:-0}" -ge "$want" ]; then
      echo "[ok]  knative-eventing/kafka-broker-dispatcher (ready ${got:-0}/${want} — 트리거가 없으면 0)"
    else echo "[FAIL] kafka-broker-dispatcher ready ${got:-0}/${want:-?}"; rc=1; fi
    [ "$(kubectl get ns knative-eventing -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')" = ambient ] \
      && echo "[ok]  knative-eventing 은 ambient" || { echo "[FAIL] knative-eventing 이 ambient 가 아니다 — Kafka 에 메시 신원 없이 붙어 거부된다"; rc=1; }
  else
    echo "[--]  Eventing 은 아직 설치하지 않았다(--eventing)"
  fi
  return $rc
}

eventing() {
  # ── Eventing + Kafka 브로커(2026-11-10) ─────────────────────
  # ★ 전제 넷 — 하나라도 빠지면 브로커가 Ready 가 아니다:
  #   ① local/kafka-knative-secret(knative-password) — create-secrets.sh. kafka-secret 이 아니다(그 사유는 그 파일)
  #   ② SCRAM 사용자 knative — kafka-topics Job(Sync 훅)이 ①로 만든다
  #   ③ Ranger 정책 oim-kafka-knative-* — local/ranger-bootstrap.sh(+ ranger-kafka-seed.sh 로 시드 갱신)
  #   ④ 메시 허용 allow-knative-kafka — overlays/local/knative/kafka-authz.yaml(ArgoCD)
  kubectl -n local get secret kafka-knative-secret >/dev/null 2>&1 \
    || { echo "[knative] local/kafka-knative-secret 이 없다 — create-secrets.sh 의 그 줄을 먼저" >&2; exit 1; }
  kubectl -n local get authorizationpolicy allow-knative-kafka >/dev/null 2>&1 \
    || { echo "[knative] local/allow-knative-kafka 가 없다 — ArgoCD 동기화를 먼저" >&2; exit 1; }

  log "Eventing ${KNATIVE_VERSION} + Kafka 브로커"
  fetch knative/eventing eventing-crds.yaml 'name: brokers.eventing.knative.dev'
  fetch knative/eventing eventing-core.yaml 'name: eventing-controller'
  fetch knative-extensions/eventing-kafka-broker eventing-kafka-controller.yaml 'name: kafka-controller'
  fetch knative-extensions/eventing-kafka-broker eventing-kafka-broker.yaml 'name: kafka-broker-receiver'
  # ★ 네임스페이스를 **먼저** 만들고 ambient 에 넣는다 — 데이터플레인이 메시 신원으로 Kafka 에 붙어야
  #   allow-knative-kafka 가 그것을 허용한다(메시 밖이면 ztunnel 이 거부한다). 파드가 뜬 뒤 라벨을 붙이면
  #   편입이 파드 단위로 어긋날 수 있다(Gotcha 195).
  kubectl create ns knative-eventing --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label ns knative-eventing istio.io/dataplane-mode=ambient --overwrite >/dev/null
  kubectl apply --server-side --force-conflicts -f "$DL/eventing-crds.yaml"
  kubectl wait --for=condition=Established --timeout=120s crd/brokers.eventing.knative.dev crd/triggers.eventing.knative.dev
  kubectl apply --server-side --force-conflicts -f "$DL/eventing-core.yaml"
  kubectl apply --server-side --force-conflicts -f "$DL/eventing-kafka-controller.yaml"
  kubectl apply --server-side --force-conflicts -f "$DL/eventing-kafka-broker.yaml"
  for d in eventing-webhook eventing-controller kafka-webhook-eventing kafka-controller; do
    kubectl -n knative-eventing rollout status deploy/"$d" --timeout=300s
  done

  # 브로커 인증 Secret — 값은 stdin 으로만 지난다(인자·로그에 남기지 않는다, Gotcha 186).
  log "브로커 인증 Secret knative-eventing/kafka-knative-auth"
  kubectl -n local get secret kafka-knative-secret -o jsonpath='{.data.knative-password}' | base64 -d \
    | kubectl -n knative-eventing create secret generic kafka-knative-auth \
        --from-literal=protocol=SASL_PLAINTEXT --from-literal=sasl.mechanism=SCRAM-SHA-512 \
        --from-literal=user=knative --from-file=password=/dev/stdin \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  [ "$(kubectl -n knative-eventing get secret kafka-knative-auth -o jsonpath='{.data.password}' | base64 -d | wc -c)" -ge 16 ] \
    || { echo "[knative] kafka-knative-auth 의 password 가 비었다" >&2; exit 1; }

  log "kafka-broker-config: SASL 9094 · 파티션 3 · 복제 1(단일 브로커)"
  kubectl -n knative-eventing patch cm kafka-broker-config --type merge -p '{"data":{
    "bootstrap.servers":"kafka-headless.local.svc.cluster.local:9094",
    "default.topic.partitions":"3","default.topic.replication.factor":"1",
    "auth.secret.ref.name":"kafka-knative-auth"}}'
  # 기본 브로커 클래스를 Kafka 로 — 아니면 MTChannelBasedBroker(InMemoryChannel)가 되어 재시작에 이벤트가 사라진다.
  kubectl -n knative-eventing patch cm config-br-defaults --type merge -p "$(cat <<'EOF'
{"data":{"default-br-config":"clusterDefault:\n  brokerClass: Kafka\n  apiVersion: v1\n  kind: ConfigMap\n  name: kafka-broker-config\n  namespace: knative-eventing\n  delivery:\n    retry: 10\n    backoffPolicy: exponential\n    backoffDelay: PT0.2S\n"}}
EOF
)"
  # ★★ Kafka 브로커는 자기 주소를 **짧은 이름** `kafka-0.kafka-headless:9094` 로 알린다(kafka-statefulset.yaml 의
  #   KAFKA_ADVERTISED_LISTENERS). `local` 밖에서는 그 이름이 풀리지 않아 브로커가
  #   `Failed to create topic ... lookup kafka-0.kafka-headless ... no such host` 였다(2026-11-10 실측 — SASL·메시는
  #   이미 통과했다: 메타데이터를 받은 뒤의 실패다). 그래서 Knative 의 Kafka 워크로드 셋에 검색 도메인
  #   `local.svc.cluster.local` 을 더한다 — Kafka 를 재시작하지 않는다.
  #   ★ 근본 처방은 브로커가 FQDN 을 알리는 것이다 — 그러려면 Kafka 를 재시작하고 9095(TLS, OpenMeter) 인증서의
  #   SAN 이 그 이름을 덮는지 확인해야 한다(과금 경로). 다음 Kafka 점검 때 하고 그때 이 패치를 지울 것.
  local w
  for w in deploy/kafka-controller deploy/kafka-broker-receiver statefulset/kafka-broker-dispatcher; do
    kubectl -n knative-eventing patch "$w" --type merge \
      -p '{"spec":{"template":{"spec":{"dnsConfig":{"searches":["local.svc.cluster.local"]}}}}}' >/dev/null
  done
  kubectl -n knative-eventing rollout status deploy/kafka-controller --timeout=300s
  # ★ dispatcher 의 기본 requests 가 cpu 1000m 다 — 이 클러스터의 트리거 수에 과하다. limit(2000m)은 그대로 둔다.
  #   릴리스를 다시 적용하면 되돌아가므로 이 스크립트를 다시 돌릴 것(Gotcha 80).
  kubectl -n knative-eventing patch statefulset kafka-broker-dispatcher --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"200m"}]' >/dev/null
  kubectl -n knative-eventing rollout status statefulset/kafka-broker-dispatcher --timeout=300s
  kubectl -n knative-eventing rollout status deploy/kafka-broker-receiver --timeout=300s
  [ "$(kubectl -n knative-eventing get cm kafka-broker-config -o jsonpath='{.data.auth\.secret\.ref\.name}')" = kafka-knative-auth ] \
    || { echo "[knative] kafka-broker-config 가 반영되지 않았다" >&2; exit 1; }
}

if [ "${1:-}" = "--check" ]; then check; exit $?; fi
if [ "${1:-}" = "--eventing" ]; then eventing; check; exit $?; fi

kubectl -n local get gateway knative-local >/dev/null 2>&1 \
  || { echo "[knative] local/knative-local Gateway 가 없다 — git(kubernetes/overlays/local/knative)이 먼저 동기화돼야 한다" >&2; exit 1; }

# ── Serving ───────────────────────────────────────────────
log "Serving ${KNATIVE_VERSION}"
fetch knative/serving serving-crds.yaml 'name: services.serving.knative.dev'
fetch knative/serving serving-core.yaml 'name: activator'
fetch knative-extensions/net-gateway-api net-gateway-api.yaml 'name: net-gateway-api-controller'
kubectl apply --server-side --force-conflicts -f "$DL/serving-crds.yaml"
kubectl wait --for=condition=Established --timeout=120s crd/services.serving.knative.dev crd/revisions.serving.knative.dev
kubectl apply --server-side --force-conflicts -f "$DL/serving-core.yaml"
kubectl apply --server-side --force-conflicts -f "$DL/net-gateway-api.yaml"
for d in webhook controller activator autoscaler net-gateway-api-controller net-gateway-api-webhook; do
  kubectl -n knative-serving rollout status deploy/"$d" --timeout=300s
done

# ── 설정 ──────────────────────────────────────────────────
# ★ ConfigMap 은 Knative 의 검증 webhook 을 지난다 — webhook 이 뜬 뒤에(위 대기) 고친다.
#   kubectl patch(merge)로 우리 키만 넣는다. 릴리스를 다시 적용하면 `_example` 만 있는 원본으로
#   돌아가므로 **이 스크립트를 다시 돌릴 것**(Gotcha 80).
log "config-network: ingress-class · 호스트 템플릿 · http 는 https 로 돌린다"
# ★ http-protocol 로는 평문을 막을 수 없다(2026-11-10 실측) — Redirected·Disabled 는 Knative 가 TLS 를 직접 다룰 때만
#   뜻이 있고, net-gateway-api 는 라우트를 호스트가 맞는 **모든 리스너**에 붙인다. 평문 차단은 네임스페이스 분리가 한다:
#   Knative Service 는 `kn` 에 두고 `ingress` 의 80 리스너는 `local` 라우트만 받는다(overlays/local-kn 머리말).
#   Redirected 는 TLS 를 켜는 날을 위해 둔다.
kubectl -n knative-serving patch cm config-network --type merge -p "$(cat <<'EOF'
{"data":{"ingress-class":"gateway-api.ingress.networking.knative.dev",
         "domain-template":"{{.Name}}-{{.Namespace}}.{{.Domain}}",
         "http-protocol":"Redirected"}}
EOF
)"
kubectl -n knative-serving patch cm config-domain --type merge -p "{\"data\":{\"${KNATIVE_DOMAIN}\":\"\"}}"
log "config-gateway: 외부 local/ingress · 내부 local/knative-local"
kubectl -n knative-serving patch cm config-gateway --type merge -p "$(cat <<'EOF'
{"data":{"external-gateways":"- class: istio\n  gateway: local/ingress\n  service: local/ingress-istio\n  supported-features:\n  - HTTPRouteRequestTimeout\n",
         "local-gateways":"- class: istio\n  gateway: local/knative-local\n  service: local/knative-local-istio\n  supported-features:\n  - HTTPRouteRequestTimeout\n"}}
EOF
)"
# secure-pod-defaults — 사용자 컨테이너에 이 레포의 securityContext 관례(runAsNonRoot · drop ALL · RuntimeDefault ·
#   allowPrivilegeEscalation false)를 기본으로 채운다. 명시한 값은 그대로 둔다.
kubectl -n knative-serving patch cm config-features --type merge -p '{"data":{"secure-pod-defaults":"Enabled"}}'

# 되읽어 확인한다(Gotcha 86 — 조용히 빗나간 설정은 아무 일도 하지 않은 것과 같다)
[ "$(kubectl -n knative-serving get cm config-network -o jsonpath='{.data.ingress-class}')" = "gateway-api.ingress.networking.knative.dev" ] \
  || { echo "[knative] config-network 의 ingress-class 가 반영되지 않았다" >&2; exit 1; }
kubectl -n knative-serving get cm config-gateway -o jsonpath='{.data.external-gateways}' | grep -q 'gateway: local/ingress' \
  || { echo "[knative] config-gateway 가 반영되지 않았다" >&2; exit 1; }

[ "${SKIP_EVENTING:-0}" = 1 ] || eventing
check
log "완료"
