sudo kubectl apply -f akhq-configmap.yaml -f akhq-statefulset.yaml -f akhq-nodeport.yaml -f akhq-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/akhq-nodeport 58080:58080 > /dev/null 2>&1 &