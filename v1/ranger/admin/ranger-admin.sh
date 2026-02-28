sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/ranger-admin-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.DB_PASSWORD=env(myenv)' ranger-admin-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.RANGERADMIN_PASSWORD=env(myenv)' ranger-admin-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.RANGERTAGSYNC_PASSWORD=env(myenv)' ranger-admin-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.RANGERUSERSYNC_PASSWORD=env(myenv)' ranger-admin-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.KEYADMIN_PASSWORD=env(myenv)' ranger-admin-configmap.yaml
myenv=$(sudo kubectl get secret -n dev elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}{{"\n"}}') yq e --inplace '.data.AUDIT_ELASTICSEARCH_PASSWORD=env(myenv)' ranger-admin-configmap.yaml

sudo kubectl get secret -n dev elasticsearch-es-http-ca-internal -o jsonpath='{.data.tls\.crt}' | base64 -d > elasticsearch-http-ca.crt


sudo kubectl -n dev exec -it elasticsearch-es-all-0 -- cat /usr/share/elasticsearch/config/http-certs/tls.crt >> tls.crt
keytool -importcert -noprompt -alias eck-es-http-ca -file tls.crt -keystore ranger-admin-truststore.jks -storepass changeit -storetype JKS
keytool -list -keystore ranger-admin-truststore.jks -storepass changeit
kubectl create secret generic ranger-admin-truststore -n dev --from-file=ranger-admin-truststore.jks

sudo kubectl apply -f ranger-admin-configmap.yaml -f ranger-admin-headless.yaml -f ranger-admin-statefulset.yaml -f ranger-admin-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/ranger-admin-nodeport 16080:16080 > /dev/null 2>&1 &

# 설정파일 경로
# /opt/bitnami/ranger/conf
# ranger.conf
# pg_hba.conf