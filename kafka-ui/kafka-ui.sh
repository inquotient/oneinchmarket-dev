sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/kafka-ui-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f kafka-ui-statefulset.yaml -f kafka-ui-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/kafka-ui-nodeport 18082:18082 > /dev/null 2>&1 &