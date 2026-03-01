myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.solr_password=env(myenv)' solr-configmap.yaml
sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/solr-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f solr-configmap.yaml -f solr-headless.yaml -f solr-statefulset.yaml -f solr-nodeport.yaml -n dev
sudo kubectl -n dev port-forward svc/solr-nodeport 18983:18983 > /dev/null 2>&1 &

# 설정파일 경로
# /opt/bitnami/solr/conf
# solr.conf
# pg_hba.conf