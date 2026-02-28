myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.hive-metastore-db-password=env(myenv)' hive-metastore-configmap.yaml
sudo kubectl apply -f hive-metastore-configmap.yaml -f hive-metastore-statefulset.yaml -f hive-metastore-nodeport.yaml -f hive-metastore-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/hive-metastore-nodeport 20000:10000 > /dev/null 2>&1 &

schematool -dbType postgres -validate -userName hive_metastore -passWord 'Hs5HSatTjTivgwPm9Kw8RylEZoVoRddE' -url jdbc:postgresql://postgresql-0.postgresql-headless.dev.svc.cluster.local:5432/hive_metastore