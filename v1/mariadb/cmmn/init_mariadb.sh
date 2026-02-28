#!/bin/sh

if [ -n $(ps -ef | grep "kubectl port-forward" | sed -n '2p' | gawk '{ print $2 }') ]
then
    sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/cmmn-mariadb-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
    sudo kubectl delete -f mariadb-configmap.yaml -f mariadb-headless.yaml -f mariadb-statefulset.yaml -f mariadb-nodeport.yaml -n dev
    sudo rm -rf ./tde_master
    sudo mkdir tde
    sudo chmod 777 tde
    (echo -n "1;" ; openssl rand -hex 32 ) | sudo tee -a ~/mariadb/cmmn/tde/tde_master
    openssl rand -hex 128 > ~/mariadb/cmmn/tde/tde_master.key
    openssl enc -aes-256-cbc -md sha1 -pass file:/home/darka/mariadb/cmmn/tde/tde_master.key -in /home/darka/mariadb/cmmn/tde/tde_master -out /home/darka/mariadb/cmmn/tde/tde_master.enc
    sudo kubectl apply -f mariadb-configmap.yaml -f mariadb-headless.yaml -f mariadb-statefulset.yaml -f mariadb-nodeport.yaml -n dev
    sudo kubectl -n dev port-forward svc/cmmn-mariadb-nodeport 10306:10306 > /dev/null 2>&1 &
else
    myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.mysql_root_password=env(myenv)' mariadb-configmap.yaml
    sudo kubectl create -f mariadb-configmap.yaml -f mariadb-statefulset.yaml -f mariadb-nodeport.yaml -n dev
    sudo kubectl -n dev port-forward svc/cmmn-mariadb-nodeport 10306:10306 > /dev/null 2>&1 &
fi