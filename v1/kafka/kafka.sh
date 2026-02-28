uuid=$(uuidgen) yq -i '.data.KAFKA_CLUSTER_ID=env(uuid)' kafka-configmap.yaml
sudo kubectl apply -f kafka-configmap.yaml -n dev

kubectl rollout status statefulset/kafka-br -n dev --timeout=600s
kubectl apply -f kafka-job.yaml -n dev

/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list