myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.postgresql_password=env(myenv)' postgresql-configmap.yaml
sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/postgresql-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f postgresql-configmap.yaml -f postgresql-headless.yaml -f postgresql-statefulset.yaml -f postgresql-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/postgresql-nodeport 15432:15432 > /dev/null 2>&1 &

# 설정파일 경로
# /opt/bitnami/postgresql/conf
# postgresql.conf
# pg_hba.conf