# Ranger UserSync
#
# 공식 이미지가 없다 — Docker Hub 의 `apache/ranger` 는 admin 배포물만
# 담고 있고 `apache/ranger-usersync` 저장소는 존재하지 않는다.
# 다만 **Dockerfile 은 upstream 에 있다**:
#   apache/ranger @ release-ranger-2.9.0
#     dev-support/ranger-docker/Dockerfile.ranger-usersync
# 이 파일은 그것을 옮긴 것이다. 달라진 점은 하나뿐 —
#   upstream 은 소스 빌드 산출물(./dist/...)을 COPY 하지만,
#   여기서는 정식 릴리스 tarball 을 빌드 시점에 받는다.
#   (런타임이 아니라 빌드 시점이다. v1 이 파드 기동마다 받던 것과 다르다.)
#
# 베이스는 Apache 가 배포하는 공식 이미지다. admin 이미지와 같은 계열이다.
# ★ podman 은 short-name 을 해석하지 않는다(unqualified-search registries 미정의).
#   레지스트리를 명시해야 한다.
ARG RANGER_BASE_IMAGE=docker.io/apache/ranger-base
ARG RANGER_BASE_VERSION=20260123-2-8
FROM ${RANGER_BASE_IMAGE}:${RANGER_BASE_VERSION}

ARG USERSYNC_VERSION=2.9.0
ARG USERSYNC_URL=https://downloads.apache.org/ranger/2.9.0/services/usersync/ranger-2.9.0-usersync.tar.gz

USER root

ADD  ${USERSYNC_URL} /home/ranger/dist/ranger-${USERSYNC_VERSION}-usersync.tar.gz
COPY ranger-usersync.sh ${RANGER_SCRIPTS}/

RUN tar xfz /home/ranger/dist/ranger-${USERSYNC_VERSION}-usersync.tar.gz --directory=${RANGER_HOME} && \
    ln -s ${RANGER_HOME}/ranger-${USERSYNC_VERSION}-usersync ${RANGER_HOME}/usersync && \
    rm -f /home/ranger/dist/ranger-${USERSYNC_VERSION}-usersync.tar.gz && \
    rm -f ${RANGER_HOME}/usersync/install.properties && \
    mkdir -p /var/run/ranger /var/log/ranger/usersync /etc/ranger && \
    ln -s ${RANGER_HOME}/usersync/ranger-usersync-services.sh /usr/bin/ranger-usersync && \
    chown -R ranger:ranger ${RANGER_HOME}/usersync/ ${RANGER_SCRIPTS}/ \
                           /var/run/ranger/ /var/log/ranger/ /etc/ranger && \
    chmod 744 ${RANGER_SCRIPTS}/ranger-usersync.sh

# upstream 의 /etc/init.d·rc2.d·rc3.d 심링크는 만들지 않는다.
# SysV init 이 없는 컨테이너에서 쓰이지 않고, 매니페스트가 엔트리포인트를
# 직접 실행한다.

USER ranger

ENTRYPOINT [ "/home/ranger/scripts/ranger-usersync.sh" ]
