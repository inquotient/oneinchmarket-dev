sudo kubectl apply -f kibana.yaml -n dev

sudo kubectl -n dev port-forward svc/kibana-kb-http 5601:5601 > /dev/null 2>&1 &