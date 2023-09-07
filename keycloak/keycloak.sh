myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.admin_password=env(myenv)' keycloak-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.keycloakdb_password=env(myenv)' keycloak-configmap.yaml
sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/keycloak-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f keycloak-secret.yaml -f keycloak-statefulset.yaml -f keycloak-nodeport.yaml -f keycloak-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/keycloak-nodeport 18083:18083 > /dev/null 2>&1 &