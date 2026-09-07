#!/usr/bin/env bash
# GitLab 컨테이너 레지스트리 부트스트랩 — 그룹·프로젝트·배포 토큰
#
# ★ 왜 필요한가
#   `docker/` 9종은 로컬에서만 빌드되어 어느 레지스트리에도 없었다. 그래서
#   Trivy Operator 가 **한 번도 스캔하지 못했다** — 스캔 Job 은 파드라
#   노드의 containerd 소켓에 닿지 못하고, `oneinch/...` 는 docker.io 로
#   해석되어 401 이 된다. 공급망 통제에 9종짜리 구멍이었다(§8-79).
#
# ★ GitLab 레지스트리는 아무 경로에나 push 할 수 없다 — 이미지 경로가
#   **실재하는 프로젝트**와 짝이 맞아야 한다(`<host>/<group>/<project>`).
#   그래서 그룹 `oneinch` 아래에 이미지 이름과 **같은 이름의 프로젝트**를
#   만든다. 그러면 경로가 지금과 똑같은 `oneinch/<name>` 이 되어
#   매니페스트에는 호스트 접두만 붙는다(디프가 최소가 된다).
#
# ★ 로그인 폼을 두드리지 않는다 — `gitlab-rails runner` 로 한다.
#   Ranger 에서 로그인 자동화가 관리자를 잠근 전례가 있다(Gotcha 11).
#   Ruby 는 **stdin 으로 넘긴다** — 셸 따옴표 안에 넣으면 이스케이프가
#   얽히고, 이름에 따옴표가 섞이면 코드 자체가 바뀐다.
#
# ★ 여러 번 돌려도 안전하다. 다만 배포 토큰은 **생성 시점에만** 값을 볼 수
#   있어, 돌릴 때마다 지우고 새로 만든다 — Secret 도 같이 갱신할 것.
#
# 사용
#   local/gitlab-registry-bootstrap.sh            # 그룹·프로젝트·토큰
#   local/gitlab-registry-bootstrap.sh --secret   # + k8s Secret 까지
set -Eeuo pipefail
trap 'echo "[gl-reg][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
GROUP="${GROUP:-oneinch}"
TOKEN_NAME="${TOKEN_NAME:-k8s-image-pull}"
REGISTRY_HOST="${REGISTRY_HOST:-gitlab-registry.local.svc.cluster.local:5050}"
SECRET_NAME="${SECRET_NAME:-gitlab-registry-secret}"

# ★ 매니페스트가 참조하는 이미지 이름과 **같아야 한다.**
#   build-images.sh 의 목록과 어긋나면 push 가 404 로 거부된다.
IMAGES="spark-iceberg livy ranger-usersync hbase jenkins proxysql ranger-hdfs-plugin ranger-hbase-plugin ranger-hive-plugin"

K() { kubectl -n "$NS" "$@"; }
log() { echo "[gl-reg] $*"; }

# Ruby 를 stdin 으로 넘기는 실행기. 인자는 컨테이너에 넘길 환경변수다.
glrun() { K exec -i gitlab-0 -- env "$@" gitlab-rails runner - ; }

log "GitLab 준비 확인"
K exec gitlab-0 -- curl -sf -o /dev/null http://127.0.0.1/-/readiness

log "레지스트리 활성 확인"
echo 'abort("레지스트리가 꺼져 있다 — gitlab-configmap.yaml 을 볼 것") unless Gitlab.config.registry.enabled' | glrun

log "그룹·프로젝트 생성 (그룹=${GROUP})"
glrun OIM_GROUP="$GROUP" OIM_IMAGES="$IMAGES" <<'RUBY'
  root  = User.find_by(username: "root") or abort("root 사용자가 없다")
  gname = ENV.fetch("OIM_GROUP")
  # ★ GitLab 17+ 는 Organization 이 필수다 — 빼면 조용히 실패하지 않고
  #   ServiceResponse(success=false, "Organization can't be blank") 를
  #   돌려준다. 그리고 execute 의 반환은 Group 이 아니라 ServiceResponse 라
  #   `persisted?` 를 부르면 NoMethodError 다(실측). payload[:group] 을 볼 것.
  org = Organizations::Organization.find_by(path: "default") ||
        Organizations::Organization.first
  abort("Organization 이 없다") if org.nil?

  group = Group.find_by(path: gname)
  if group.nil?
    r = Groups::CreateService.new(
      root, name: gname, path: gname, organization_id: org.id,
      visibility_level: Gitlab::VisibilityLevel::PRIVATE).execute
    group = r.payload[:group]
    abort("그룹 생성 실패: #{group.errors.full_messages.join(', ')}") unless group&.persisted?
    puts "  그룹 생성: #{gname}"
  else
    puts "  그룹 있음: #{gname}"
  end

  ENV.fetch("OIM_IMAGES").split.each do |img|
    if group.projects.find_by(path: img)
      puts "  프로젝트 있음: #{gname}/#{img}"
      next
    end
    # container_registry 는 새 프로젝트에서 기본으로 켜진다 —
    # container_registry_enabled 는 deprecated 라 넘기지 않는다.
    # ★ Projects::CreateService 는 (그룹과 달리) Project 를 그대로 돌려준다.
    p = Projects::CreateService.new(
      root, name: img, path: img, namespace_id: group.id,
      organization_id: org.id,
      visibility_level: Gitlab::VisibilityLevel::PRIVATE,
      initialize_with_readme: false).execute
    abort("프로젝트 생성 실패 #{img}: #{p.errors.full_messages.join(', ')}") unless p.persisted?
    puts "  프로젝트 생성: #{gname}/#{img}"
  end
RUBY

log "배포 토큰 발급 (그룹 범위 — 9개를 따로 만들면 회전을 9번 해야 한다)"
TOKEN="$(glrun OIM_GROUP="$GROUP" OIM_TOKEN_NAME="$TOKEN_NAME" <<'RUBY' | tr -d '\r'
  group = Group.find_by(path: ENV.fetch("OIM_GROUP")) or abort("그룹이 없다")
  root  = User.find_by(username: "root")
  name  = ENV.fetch("OIM_TOKEN_NAME")
  # 값은 생성 시점에만 보인다 — 같은 이름이 있으면 지우고 새로 만든다.
  group.deploy_tokens.where(name: name).destroy_all
  # ★ `scopes:` 로는 못 넘긴다 — DeployToken 에 그런 컬럼이 없어
  #   ActiveModel::UnknownAttributeError 로 예외가 난다. 개별 불리언이다.
  # ★ expires_at 은 Time 이 아니라 **ISO 8601 문자열**이어야 한다
  #   ("Expires at must be in ISO 8601 format" — 조용히 실패하지 않고
  #    status=:error 로 돌아오므로 반드시 확인할 것).
  r = Groups::DeployTokens::CreateService.new(group, root,
        name: name, username: name,
        read_registry: true, write_registry: true,
        expires_at: 1.year.from_now.iso8601).execute
  t = r[:deploy_token]
  abort("토큰 발급 실패: #{r[:message]} #{t && t.errors.full_messages.join(', ')}") if t.nil? || !t.persisted? || t.token.blank?
  print t.token
RUBY
)"

[ -n "$TOKEN" ] || { echo "[gl-reg] 토큰이 비었다" >&2; exit 1; }
log "토큰 발급 완료 (길이 ${#TOKEN})"

if [ "${1:-}" = "--secret" ]; then
  log "Secret 생성: ${SECRET_NAME} (kubernetes.io/dockerconfigjson)"
  # ★ Trivy Operator 는 스캔 대상 워크로드의 imagePullSecrets 를
  #   자기 네임스페이스로 복사해 쓴다. 워크로드 쪽에만 붙이면 되고
  #   trivy-system 에 따로 둘 필요가 없다.
  K create secret docker-registry "$SECRET_NAME" \
      --docker-server="$REGISTRY_HOST" \
      --docker-username="$TOKEN_NAME" \
      --docker-password="$TOKEN" \
      --dry-run=client -o yaml | K apply -f - >/dev/null
  log "완료 — 워크로드의 imagePullSecrets 가 이 이름을 참조한다"
else
  log "Secret 까지 만들려면 --secret 을 붙일 것 (사용자명: ${TOKEN_NAME})"
fi

log "레지스트리 응답 확인 (401 이면 정상 — 토큰 인증을 요구한다)"
K exec gitlab-0 -- curl -s -o /dev/null -w '  /v2/ -> %{http_code}\n' \
    http://127.0.0.1:5050/v2/
