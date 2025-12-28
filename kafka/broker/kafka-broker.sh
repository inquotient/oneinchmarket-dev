replace=$(seq 0 $(yq '.spec.replicas - 1' ../controller/kafka-controller-statefulset.yaml) | awk '{ printf("%s%s%s%s%s%s", sep, $1+1, "@", "kafka-ctrl-", $1, ".kafka-ctrl-headless.dev.svc.cluster.local:9093"); sep="," } END { print "" }') yq -i '.spec.template.spec.containers.[] | select(.name == "kafka-br") | .env.[] | select(.name == "KAFKA_CONTROLLER_QUORUM_VOTERS") | .value=env(replace) | parent | parent | parent | parent | parent | parent | parent' kafka-broker-statefulset.yaml

sudo kubectl apply -f kafka-broker-headless.yaml -f kafka-broker-statefulset.yaml -f kafka-broker-nodeport.yaml -f kafka-broker-configmap.yaml -n dev
sudo kubectl -n dev port-forward svc/kafka-broker-nodeport 19094:19094 > /dev/null 2>&1 &

/opt/bitnami/kafka/bin/kafka-topics.sh --create --bootstrap-server localhost:9092 replication-factor 1 partition 1 --topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --delete --bootstrap-server localhost:9092 -topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

/opt/bitnami/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic --from-beginning
sudo kubectl -n dev exec -it kafka-0 -- bash