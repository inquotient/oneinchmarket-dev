sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/mongodb-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f mongodb-configmap.yaml -f mongodb-statefulset.yaml -f mongodb-nodeport.yaml -f mongodb-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/mongodb-nodeport 28017:28017 > /dev/null 2>&1 &