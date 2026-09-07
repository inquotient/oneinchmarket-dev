#!/usr/bin/env bash
# GitLab CI 러너를 등록하고 인증 토큰을 Secret 으로 만든다
#
# ★ 왜 필요한가 — 이 GitLab 에는 **러너가 0개**였다. 그래서 파이프라인 10건이
#   만들어지고도 **한 번도 실행되지 않았다**(잡 24건 canceled · 5건 failed ·
#   8건 skipped). `.gitlab-ci.yml` 에 무엇을 넣든 켠 것처럼 보이고 아무것도
#   돌지 않는다 — 이 레포가 반복해서 경계하는 부류다(Gotcha 12).
#   Secret Detection 도 CI 잡이므로 러너가 선행 조건이다.
#
# ★★ GitLab 19 에는 **등록 토큰(registration token) 흐름이 없다.**
#   러너 객체를 먼저 만들고 그 **인증 토큰**(glrt- 접두)을 받아 쓴다.
#   Ci::Runners::CreateRunnerService 가 그 일을 한다.
#
# ★ 토큰은 난수가 아니라 GitLab 이 발급하는 값이라 create-secrets.sh 가
#   만들 수 없다 — §8-79 의 레지스트리 배포 토큰과 같은 이유다.
#
# ★ 값을 출력하지 않는다. 임시 파일을 거쳐 shred 한다.
#
# 멱등하다 — 같은 description 의 러너가 있으면 그 토큰을 다시 쓴다.
#
# 사용
#   local/gitlab-runner-bootstrap.sh
set -Eeuo pipefail
trap 'echo "[gl-runner][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
DESC="${DESC:-oim-local-k8s}"
# ★ 러너는 클러스터 안에서 GitLab 에 붙는다. gitlab-headless 가 80 을 연다.
CI_SERVER_URL="${CI_SERVER_URL:-http://gitlab-headless.local.svc.cluster.local/}"
SECRET_NAME="${SECRET_NAME:-gitlab-runner-token}"

log() { echo "[gl-runner] $*"; }

log "GitLab 준비 확인"
kubectl -n "$NS" exec gitlab-0 -- curl -sf -o /dev/null http://127.0.0.1/-/readiness

log "러너 등록 (description=${DESC})"
# 토큰만 stdout 으로 내보낸다 — 진단 문구는 stderr 로 보낸다.
kubectl -n "$NS" exec -i gitlab-0 -- env OIM_DESC="$DESC" gitlab-rails runner - \
  > /tmp/gl-runner-token.txt <<'RUBY'
  desc = ENV.fetch("OIM_DESC")
  runner = Ci::Runner.find_by(description: desc)
  if runner.nil?
    root = User.find_by(username: "root") or abort("root 사용자가 없다")
    r = ::Ci::Runners::CreateRunnerService.new(user: root, params: {
      runner_type: "instance_type",
      description: desc,
      # ★ run_untagged 를 켠다. 끄면 태그를 단 잡만 받아서, 태그를 잊은
      #   파이프라인이 영원히 pending 에 머문다(러너가 있는데 안 도는 상태).
      run_untagged: true,
      tag_list: %w[k8s local],
    }).execute
    abort("러너 생성 실패: #{r.message}") unless r.success?
    runner = r.payload[:runner]
    warn "  러너 생성: id=#{runner.id} type=#{runner.runner_type}"
  else
    warn "  러너 있음: id=#{runner.id} type=#{runner.runner_type}"
  end
  # ★ 토큰만 출력한다(개행 없이).
  print runner.token
RUBY

tr -d '\r' < /tmp/gl-runner-token.txt > /tmp/gl-runner-token.clean
mv /tmp/gl-runner-token.clean /tmp/gl-runner-token.txt
[ -s /tmp/gl-runner-token.txt ] || { echo "[gl-runner] 토큰이 비었다" >&2; exit 1; }
log "  토큰 수신 (길이 $(wc -c < /tmp/gl-runner-token.txt)자 — 값은 출력하지 않는다)"

log "Secret ${NS}/${SECRET_NAME} 생성"
kubectl -n "$NS" create secret generic "$SECRET_NAME" \
  --from-file=runner-token=/tmp/gl-runner-token.txt \
  --from-literal=ci-server-url="$CI_SERVER_URL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
shred -u /tmp/gl-runner-token.txt 2>/dev/null || rm -f /tmp/gl-runner-token.txt

log "확인 (키 이름만 — 값은 출력하지 않는다)"
kubectl -n "$NS" get secret "$SECRET_NAME" -o json \
  | python3 -c 'import json,sys; print("  키:", sorted(json.load(sys.stdin)["data"].keys()))'

log "완료 — 러너 워크로드는 kubernetes/overlays/local/gitlab-runner/ 에 있다"
log "        ArgoCD 가 자동 동기화하거나 kubectl apply -k 로 올린다"
