#!/usr/bin/env bash
# 이 레포를 GitLab 에 올린다 — ArgoCD 가 읽을 git 원천을 만든다
#
# ★ 왜 필요한가 — ArgoCD 는 git 을 읽어야 동작한다. 그런데 이 GitLab 에는
#   **코드 저장소가 0개**였다(§8-79 에서 만든 9개는 레지스트리 전용이라
#   커밋이 없다). 그래서 ArgoCD 도입의 선행 조건이다.
#   Backstage 카탈로그(§ WSO2-OSS-MAPPING Phase 4)의 전제이기도 하다.
#
# ★ 경로를 `infra/oneinchmarket-infra` 로 둔다 — `argocd/applications/*.yaml`
#   과 `.gitlab-ci.yml` 이 이미 그 경로를 전제한다. 나중에 실제 GitLab 으로
#   옮길 때 URL 의 호스트만 바뀌게 하려는 것이다.
#
# ★★ 토큰을 프로세스 인자에 두지 않는다. GIT_ASKPASS 로 파일에서 읽는다 —
#   `git remote -v` 나 `.git/config` 에도 남기지 않는다(원격을 영구 등록하지 않는다).
#
# 사용
#   local/gitlab-repo-bootstrap.sh          # 프로젝트 생성 + push + ArgoCD 읽기 토큰
set -Eeuo pipefail
trap 'echo "[gl-repo][ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR

NS="${NS:-local}"
GROUP="${GROUP:-infra}"
PROJECT="${PROJECT:-oneinchmarket-infra}"
HOST="${HOST:-gitlab-registry.local.svc.cluster.local}"
BRANCH="${BRANCH:-local}"
log() { echo "[gl-repo] $*"; }

glrun() { kubectl -n "$NS" exec -i gitlab-0 -- env "$@" gitlab-rails runner - ; }

log "GitLab 준비 확인"
kubectl -n "$NS" exec gitlab-0 -- curl -sf -o /dev/null http://127.0.0.1/-/readiness

log "그룹·프로젝트 생성 (${GROUP}/${PROJECT})"
glrun OIM_GROUP="$GROUP" OIM_PROJECT="$PROJECT" <<'RUBY'
  root = User.find_by(username: "root") or abort("root 사용자가 없다")
  org  = Organizations::Organization.find_by(path: "default") ||
         Organizations::Organization.first
  gname = ENV.fetch("OIM_GROUP")
  pname = ENV.fetch("OIM_PROJECT")

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

  if group.projects.find_by(path: pname)
    puts "  프로젝트 있음: #{gname}/#{pname}"
  else
    p = Projects::CreateService.new(
      root, name: pname, path: pname, namespace_id: group.id,
      organization_id: org.id,
      visibility_level: Gitlab::VisibilityLevel::PRIVATE,
      initialize_with_readme: false).execute
    abort("프로젝트 생성 실패: #{p.errors.full_messages.join(', ')}") unless p.persisted?
    puts "  프로젝트 생성: #{gname}/#{pname}"
  end
RUBY

# 배포 토큰으로는 push 할 수 없다. GitLab 의 DeployToken 스코프에
#   **write_repository 가 없다**(실측: read_repository · read_registry ·
#   write_registry · read/write_package_registry · read/write_virtual_registry).
#   즉 배포 토큰은 git 에 대해 읽기 전용이다 — 시도하면
#   "unknown attribute write_repository for DeployToken" 으로 죽는다.
#   push 는 root 자격(HTTP basic)으로 한다. 읽기 전용 토큰은 그대로 쓴다.
log "push (${BRANCH} -> ${GROUP}/${PROJECT}) — root 자격"
kubectl -n "$NS" get secret gitlab-secret -o json > /tmp/gl-sec.json
python3 -c 'import base64,json,sys;d=json.load(open("/tmp/gl-sec.json"))["data"];sys.stdout.write(base64.b64decode(d["root-password"]).decode())' > /tmp/gl-push.txt
cat > /tmp/gl-askpass.sh <<'ASK'
#!/bin/sh
cat /tmp/gl-push.txt
ASK
chmod 700 /tmp/gl-askpass.sh
GIT_ASKPASS=/tmp/gl-askpass.sh GIT_TERMINAL_PROMPT=0 \
  git push "http://root@${HOST}/${GROUP}/${PROJECT}.git" "${BRANCH}:${BRANCH}" 2>&1 | tail -5
shred -u /tmp/gl-sec.json /tmp/gl-push.txt /tmp/gl-askpass.sh 2>/dev/null || rm -f /tmp/gl-sec.json /tmp/gl-push.txt /tmp/gl-askpass.sh

log "ArgoCD 용 읽기 전용 토큰 발급"
glrun OIM_GROUP="$GROUP" OIM_PROJECT="$PROJECT" <<'RUBY' | tr -d '\r' > /tmp/gl-read.txt
  group = Group.find_by(path: ENV.fetch("OIM_GROUP"))
  proj  = group.projects.find_by(path: ENV.fetch("OIM_PROJECT"))
  root  = User.find_by(username: "root")
  proj.deploy_tokens.where(name: "argocd-read").destroy_all
  r = Projects::DeployTokens::CreateService.new(proj, root,
        name: "argocd-read", username: "argocd-read",
        read_repository: true,
        expires_at: 1.year.from_now.iso8601).execute
  t = r[:deploy_token]
  abort("토큰 발급 실패: #{r[:message]}") if t.nil? || !t.persisted?
  print t.token
RUBY
[ -s /tmp/gl-read.txt ] || { echo "[gl-repo] read 토큰이 비었다" >&2; exit 1; }

kubectl create ns argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# ★ ArgoCD 는 라벨 argocd.argoproj.io/secret-type=repository 가 붙은 Secret 을
#   저장소 자격으로 읽는다. 라벨이 없으면 **조용히 무시된다.**
kubectl -n argocd create secret generic gitlab-infra-repo \
  --from-literal=type=git \
  --from-literal=url="http://${HOST}/${GROUP}/${PROJECT}.git" \
  --from-literal=username=argocd-read \
  --from-file=password=/tmp/gl-read.txt \
  --dry-run=client -o yaml \
  | kubectl label -f - --local -o yaml argocd.argoproj.io/secret-type=repository \
  | kubectl apply -f - >/dev/null
shred -u /tmp/gl-read.txt 2>/dev/null || rm -f /tmp/gl-read.txt
log "  Secret argocd/gitlab-infra-repo 생성 (값은 출력하지 않는다)"

log "확인"
glrun OIM_GROUP="$GROUP" OIM_PROJECT="$PROJECT" <<'RUBY'
  g = Group.find_by(path: ENV.fetch("OIM_GROUP"))
  p = g.projects.find_by(path: ENV.fetch("OIM_PROJECT"))
  puts "  #{p.full_path} · 커밋 있음=#{p.repository.exists? && !p.repository.empty?} · 기본브랜치=#{p.default_branch.inspect}"
RUBY
