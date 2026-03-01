sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/gitlab-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f gitlab-configmap.yaml -f gitlab-statefulset.yaml -f gitlab-nodeport.yaml -f gitlab-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/gitlab-nodeport 20080:20080 > /dev/null 2>&1 &