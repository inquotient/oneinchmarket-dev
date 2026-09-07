#!/bin/bash

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 출처: apache/ranger @ release-ranger-2.9.0
#         dev-support/ranger-docker/scripts/usersync/ranger-usersync.sh
# 원본 그대로다. Kerberos 분기는 KERBEROS_ENABLED 가 설정되지 않으면
# 실행되지 않으므로 남겨 두었다(upstream 과의 차이를 만들지 않는다).

if [ ! -e ${RANGER_HOME}/.setupDone ]
then
  SETUP_RANGER=true
else
  SETUP_RANGER=false
fi

if [ "${SETUP_RANGER}" == "true" ]
then
  if [ "${KERBEROS_ENABLED}" == "true" ]
  then
    ${RANGER_SCRIPTS}/wait_for_keytab.sh rangerusersync.keytab
    ${RANGER_SCRIPTS}/wait_for_testusers_keytab.sh
  fi

  cd "${RANGER_HOME}"/usersync || exit
  if ./setup.sh;
  then
    if [ "${KERBEROS_ENABLED}" == "true" ]
    then
      cp ${RANGER_SCRIPTS}/core-site.xml ${RANGER_HOME}/usersync/conf/core-site.xml
    fi

    touch "${RANGER_HOME}"/.setupDone
  else
    echo "Ranger UserSync Setup Script didn't complete proper execution."
  fi
fi

# ★★ 힙을 컨테이너 limit 안으로 내린다 — upstream 이 limit 을 넘기는 값을
#   하드코딩해 둔다. ranger-usersync-services.sh 에:
#       48행  ranger_usersync_max_heap_size=1g
#       82행  JAVA_OPTS=" ${JAVA_OPTS} ... -Xmx${...} -Xms1g "
#   즉 -Xmx 1g 이 **limit(768Mi)보다 크다.** 그러면 JVM 은 1 GiB 까지
#   늘려도 된다고 믿어 full GC 를 서둘지 않고, 힙이 차기 전에
#   커널이 먼저 OOMKill 한다. 실사용은 71Mi 다(§8-94).
#
# ★ 환경변수로는 못 고친다 — 48행이 조건 없이 대입하고, 82행은
#   우리 ${JAVA_OPTS} 를 **앞에** 두고 자기 -Xmx 를 뒤에 붙인다.
#   java 는 마지막 -Xmx 를 취하므로 상류 스크립트가 이긴다.
#   그래서 스크립트 자체를 고친다.
#
# ★ 값을 바꾸면 매니페스트의 limit 과 함께 움직여야 한다
#   (ranger-usersync-deployment.yaml 의 limits.memory).
#
# ★★ 고쳐졌는지 **반드시 확인한다.** 조용히 실패하면 이 수정은
#   없는 것과 같고, 힙이 limit 을 넘기는 상태로 돌아간다 — 그러면
#   파드는 1/1 Running 이면서 언젠가 커널이 죽인다(§8-94).
#   상류가 변수명을 바꾸면 sed 가 아무 일도 하지 않으므로
#   **기동을 거부한다** — 조용한 오설정보다 CrashLoop 가 낫다.
USERSYNC_HEAP="${USERSYNC_HEAP:-384m}"
USERSYNC_MIN_HEAP="${USERSYNC_MIN_HEAP:-128m}"
USERSYNC_SVC="${RANGER_HOME}/usersync/ranger-usersync-services.sh"
if [ ! -f "${USERSYNC_SVC}" ]; then
  echo "[usersync] ★★ ${USERSYNC_SVC} 가 없다 — 힙을 고칠 수 없다. 중단." >&2
  exit 1
fi
sed -i   -e "s/^ranger_usersync_max_heap_size=.*/ranger_usersync_max_heap_size=${USERSYNC_HEAP}/"   -e "s/-Xms1g/-Xms${USERSYNC_MIN_HEAP}/"   "${USERSYNC_SVC}"
if ! grep -q "^ranger_usersync_max_heap_size=${USERSYNC_HEAP}$" "${USERSYNC_SVC}"; then
  echo "[usersync] ★★ 힙 수정이 먹지 않았다 — 상류 스크립트가 바뀌었을 수 있다." >&2
  echo "[usersync]   대상: ${USERSYNC_SVC}" >&2
  grep -n 'heap_size\|Xm' "${USERSYNC_SVC}" >&2 || true
  exit 1
fi
echo "[usersync] heap: -Xmx${USERSYNC_HEAP} -Xms${USERSYNC_MIN_HEAP} (limit 768Mi)"

cd ${RANGER_HOME}/usersync && ./start.sh

RANGER_USERSYNC_PID=`ps -ef  | grep -v grep | grep -i "org.apache.ranger.authentication.UnixAuthenticationService" | awk '{print $2}'`

# prevent the container from exiting
if [ -z "$RANGER_USERSYNC_PID" ]
then
  echo "The UserSync process probably exited, no process id found!"
else
  tail --pid=$RANGER_USERSYNC_PID -f /dev/null
fi
