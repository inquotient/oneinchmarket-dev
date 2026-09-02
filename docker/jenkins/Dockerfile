# ─────────────────────────────────────────────────────────────────────────
# oneinch/jenkins — 공식 이미지 + JCasC 플러그인.
#
# 왜 커스텀 이미지인가:
#   공식 `jenkins/jenkins` 에는 플러그인이 하나도 없다. 그대로 띄우면
#   설치 마법사가 뜨고, 마법사를 `runSetupWizard=false` 로 끄기만 하면
#   **보안 영역이 없는 = 인증 없는 Jenkins** 가 된다. 도달 가능한 누구나
#   스크립트 콘솔로 임의 코드를 실행한다.
#   관리자 계정을 선언으로 넣으려면 configuration-as-code 플러그인이
#   필요하고, 그것을 런타임에 받으면 SEC-512(런타임 외부 의존)가 된다.
#   → 빌드 시점에 굽는다. TODO-50 이 여기서 해소된다.
#
# 베이스 태그는 `lts` 다. `latest` 는 주간 릴리스라 파괴적 변경이 예고 없이
# 들어온다. (docker/ 의 다른 이미지와 마찬가지로 podman `--network host` 로
# 빌드한다 — 빌드 컨테이너가 cilium 네트워크를 잡으면 밖으로 못 나간다.)
# ─────────────────────────────────────────────────────────────────────────
FROM docker.io/jenkins/jenkins:lts

# jenkins-plugin-cli 는 이미지에 이미 있다. `--latest false` 로 코어와
# 호환되는 안정 버전을 고르게 한다(무조건 최신을 받지 않는다).
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --latest false

# JCasC 설정 파일 위치. 실제 파일은 ConfigMap 으로 여기에 마운트된다.
# JENKINS_HOME 바깥에 둔다 — PVC 안에는 ConfigMap 을 겹쳐 마운트할 수 없다.
ENV CASC_JENKINS_CONFIG=/var/jenkins_casc/jenkins.yaml

USER jenkins
