#!/bin/sh

# ZOO_SERVERS env var generated
# env ZOO_SERVERS=$(seq 1 3 | awk -v HOSTNAME="$(echo $ZOOKEEPER_HOSTNAME | awk -F '-' '{print $1}')" '{print "server." $1 "=" HOSTNAME "-" $1":2888:3888;2181"}' | xargs echo)
# seq 1 $(yq '.spec.replicas' zookeeper-statefulset.yaml) | awk -v HOSTNAME="$(echo $ZOOKEEPER_HOSTNAME | awk -F '-' '{print $1}')" '{print "server." $1 "=" HOSTNAME "-" $1":2888:3888;2181"}' | xargs echo

# Replacing zookeeper-statefulset.yaml according to replica number
replace=$(seq 1 $(yq '.spec.replicas' zookeeper-statefulset.yaml) | awk -v HOSTNAME="$(yq '.metadata.name' zookeeper-statefulset.yaml)" -v SERVICENAME="$(yq '.metadata.name' zookeeper-headless.yaml)" '{print "server." $1 "=" HOSTNAME "-" $1-1 "." SERVICENAME ".dev.svc.cluster.local:2888:3888;2181"}' | xargs echo) yq -i '.spec.template.spec.containers.[] | select(.name == "zookeeper") | .env.[] | select(.name == "ZOO_SERVERS") | .value=env(replace) | parent | parent | parent | parent | parent | parent | parent | parent' zookeeper-statefulset.yaml
sudo kubectl create -f zookeeper-statefulset.yaml -f zookeeper-headless.yaml -n dev