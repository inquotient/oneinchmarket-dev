DB_USERNAME=cmmn-api;DB_HOST=jdbc:mariadb://cmmn-mariadb-0.cmmn-mariadb.dev.svc.cluster.local/cmmn;DB_PASSWORD=8HFWh9dz1H3Gv2JgtvGfV4hQlJC68yRpO2-pZX7E6jY=

sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/cmmn-api-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')

sudo kubectl apply -f cmmn-api-configmap.yaml -f cmmn-api-statefulset.yaml -f cmmn-api-nodeport.yaml -f cmmn-api-headless.yaml -n dev

sudo kubectl -n dev port-forward svc/cmmn-api-nodeport 18080:18080 > /dev/null 2>&1 &