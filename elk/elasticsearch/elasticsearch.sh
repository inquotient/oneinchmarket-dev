kubectl create -f https://download.elastic.co/downloads/eck/3.2.0/crds.yaml
kubectl apply -f https://download.elastic.co/downloads/eck/3.2.0/operator.yaml

# sudo kubectl apply -f elasticsearch-issuer.yaml -f elasticsearch-certificate.yaml -n dev

openssl req -x509 -sha256 -nodes -newkey rsa:4096 -days 365  -keyout tls.key -out tls.crt -config openssl.cnf -extensions req_ext
kubectl -n dev create secret tls es-custom-cert --cert=tls.crt --key=tls.key

sudo kubectl apply -f elasticsearch.yaml -n dev

sudo kubectl get secret -n dev elasticsearch-es-elastic-user -o go-template='{{.data.elastic | base64decode}}{{"\n"}}'

sudo kubectl -n dev port-forward svc/elasticsearch-es-http 9200:9200 > /dev/null 2>&1 &