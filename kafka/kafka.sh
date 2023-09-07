sudo kubectl apply -f kafka-headless.yaml -f kafka-statefulset.yaml -f kafka-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/kafka-nodeport 19094:19094 > /dev/null 2>&1 &

/opt/bitnami/kafka/bin/kafka-topics.sh --create --bootstrap-server localhost:9092 replication-factor 1 partition 1 --topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --delete --bootstrap-server localhost:9092 -topic topic-test

/opt/bitnami/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

/opt/bitnami/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic --from-beginning
sudo kubectl -n dev exec -it kafka-0 -- bash