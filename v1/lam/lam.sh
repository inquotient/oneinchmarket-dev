sudo kubectl apply -f lam-configmap.yaml -f lam-statefulset.yaml -f lam-headless.yaml -f lam-nodeport.yaml -n dev

sudo kubectl -n dev port-forward svc/lam-nodeport 50080:50080 > /dev/null 2>&1 &