sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/admin-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f admin-configmap.yaml -f admin-statefulset.yaml -f admin-nodeport.yaml -f admin-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/admin-nodeport 3000:3000 > /dev/null 2>&1 &