sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/schema-reg-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f schema-reg-headless.yaml -f schema-reg-statefulset.yaml -f schema-reg-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/schema-reg-nodeport 18081:18081 > /dev/null 2>&1 &