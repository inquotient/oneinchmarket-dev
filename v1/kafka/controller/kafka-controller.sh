replace=$(seq 0 $(yq '.spec.replicas - 1' kafka-controller-statefulset.yaml) | awk '{ printf("%s%s%s%s%s%s", sep, $1+1, "@", "kafka-ctrl-", $1, ".kafka-ctrl-headless.dev.svc.cluster.local:9093"); sep="," } END { print "" }') yq -i '.spec.template.spec.containers.[] | select(.name == "kafka-ctrl") | .env.[] | select(.name == "KAFKA_CONTROLLER_QUORUM_VOTERS") | .value=env(replace) | parent | parent | parent | parent | parent | parent | parent' kafka-controller-statefulset.yaml
replace=$(seq 0 $(yq '.spec.replicas - 1' kafka-controller-statefulset.yaml) | awk '{cmd = "openssl rand -base64 16 | tr '+/' '-_' | tr -d '='"; cmd | getline u; close(cmd); printf "%s%s@kafka-ctrl-%s.kafka-ctrlheadless.dev.svc.cluster.local:9093:%s", (NR>1?",":""), $1+1, $1, u} END { print "" }') yq -i '.spec.template.spec.containers.[] | select(.name == "kafka-ctrl") | .env.[] | select(.name == "KAFKA_INITIAL_CONTROLLERS") | .value=env(replace) | parent | parent | parent | parent | parent | parent | parent' kafka-controller-statefulset.yaml
sudo kubectl apply -f kafka-controller-headless.yaml -f kafka-controller-statefulset.yaml -f kafka-controller-nodeport.yaml -f kafka-controller-configmap.yaml -n dev
sudo kubectl -n dev port-forward svc/kafka-controller-nodeport 29094:29094 > /dev/null 2>&1 &

/opt/bitnami/kafka/bin/kafka-topics.sh --create --bootstrap-server localhost:9092 replication-factor 1 partition 1 --topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --delete --bootstrap-server localhost:9092 -topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

/opt/bitnami/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic --from-beginning
sudo kubectl -n dev exec -it kafka-0 -- bash