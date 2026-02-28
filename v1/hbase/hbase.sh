sudo docker build -t hbase:2.6.3
sudo kind load docker-image hbase:2.6.3 --name dev
sudo kubectl create -f hbase-configmap.yaml -n dev