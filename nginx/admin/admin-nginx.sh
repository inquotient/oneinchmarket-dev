sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/admin-nginx-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f admin-nginx-configmap.yaml -f admin-nginx-deployment.yaml -f admin-nginx-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/admin-nginx-nodeport 30080:30080 > /dev/null 2>&1 &
sudo kubectl -n dev port-forward svc/admin-nginx-nodeport 30443:30443 > /dev/null 2>&1 &