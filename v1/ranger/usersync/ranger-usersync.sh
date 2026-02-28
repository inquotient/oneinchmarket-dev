sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/ranger-usersync-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')

sudo kubectl apply -f ranger-usersync-configmap.yaml -f ranger-usersync-headless.yaml -f ranger-usersync-statefulset.yaml -n dev
sudo kubectl -n dev port-forward svc/ranger-usersync-nodeport 16080:16080 > /dev/null 2>&1 &

# 설정파일 경로
# /opt/bitnami/ranger/conf
# ranger.conf
# pg_hba.conf