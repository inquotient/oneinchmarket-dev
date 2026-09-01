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

cd ${RANGER_HOME}/usersync && ./start.sh

RANGER_USERSYNC_PID=`ps -ef  | grep -v grep | grep -i "org.apache.ranger.authentication.UnixAuthenticationService" | awk '{print $2}'`

# prevent the container from exiting
if [ -z "$RANGER_USERSYNC_PID" ]
then
  echo "The UserSync process probably exited, no process id found!"
else
  tail --pid=$RANGER_USERSYNC_PID -f /dev/null
fi
