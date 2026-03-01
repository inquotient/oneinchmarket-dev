myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.apicurio_registry_db_password=env(myenv)' apicurio-registry-ui-configmap.yaml
sudo kubectl apply -f apicurio-registry-ui-configmap.yaml -f apicurio-registry-ui-statefulset.yaml -f apicurio-registry-ui-nodeport.yaml -f apicurio-registry-ui-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/apicurio-registry-ui-nodeport 58888:58888 > /dev/null 2>&1 &
sudo kubectl -n dev port-forward svc/apicurio-registry-ui-nodeport 58081:58081 > /dev/null 2>&1 &