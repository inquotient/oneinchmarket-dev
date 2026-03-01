sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/kafka-rest-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f kafka-rest-configmap.yaml -f kafka-rest-headless.yaml -f kafka-rest-statefulset.yaml -f kafka-rest-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/kafka-rest-nodeport 18082:18082 > /dev/null 2>&1 &