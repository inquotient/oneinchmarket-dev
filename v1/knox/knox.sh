curl -L -C - -O https://dlcdn.apache.org/knox/2.1.0/knox-2.1.0-src.zip
unzip knox-2.1.0-src.zip
gpg --import KEYS
gpg --verify knox-2.1.0.zip.asc
mvn -Ppackage,release,docker clean package

curl -L -C - -O https://dlcdn.apache.org/knox/2.1.0/knox-2.1.0.zip
unzip knox-2.1.0.zip
gpg --import KEYS
gpg --verify knox-2.1.0.zip.asc
mvn -Ppackage,release,docker clean packages

myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.alias_passphrase=env(myenv)' knox-configmap.yaml
kind load docker-image knox-gateway:2.1.0 --name dev
kubectl cp dev/kerberos-0:/tmp/knox.service.keytab ./knox.service.keytab
kubectl cp dev/kerberos-0:/tmp/hive.service.keytab ./hive.service.keytab
kubectl create secret generic knox-keytab -n dev --from-file=knox.service.keytab=./knox.service.keytab
kubectl create secret generic hive-keytab -n dev --from-file=hive.service.keytab=./hive.service.keytab
sudo kubectl apply -f knox-configmap.yaml -f knox-statefulset.yaml -f knox-nodeport.yaml -f knox-headless.yaml -n dev

sudo kubectl -n dev port-forward svc/knox-nodeport 58443:58443 > /dev/null 2>&1 &


mvn -T 1C -Ppackage,release,docker \
  clean package \
  -Dmaven.test.skip=true \
  -Dsurefire.skip=true \
  -Dfailsafe.skip=true \
  -DskipITs=true \
  -Dinvoker.skip=true \
  -DfailIfNoTests=false



# 접속 주소
https://knox-0.knox-headless.dev.svc.cluster.local:8443/gateway/homepage/homepage

# pem 추출
echo | openssl s_client   -connect knox-0.knox-headless.dev.svc.cluster.local:8443   -servername knox-0.knox-headless.dev.svc.cluster.local   2>/dev/null | openssl x509 -outform PEM > knox-server.pem

keytool -importcert -noprompt   -alias knox   -file knox-server.pem   -keystore knox-truststore.p12   -storetype PKCS12   -storepass j80pahzQ9sNoqNPN94LPCVs3lXtHQo7h

# truststore 복사
kubectl cp ./knox-truststore.p12 dev/hive-server-0:/opt/hive/knox-truststore.p12

keytool -importcert -alias knox-dev -file knox-server.pem -keystore truststore.jks -storetype JKS -storepass j80pahzQ9sNoqNPN94LPCVs3lXtHQo7h -noprompt

kubectl cp ./knox-truststore.p12 dev/hive-server-0:/opt/hive/truststore.jks
kubectl cp dev/knox-0:/home/knox/knox-2.1.0/data/security/keystores/truststore.jks ./truststore.jks

beeline -u "jdbc:hive2://knox.oneinchmarket.co.kr:443/default;ssl=true;transportMode=http;httpPath=gateway/sandbox/hive" -n jahn -p 'wltn313091!@'

jdbc:hive2://knox.oneinchmarket.co.kr:443/default;ssl=true;transportMode=http;httpPath=gateway/sandbox/hive;sslTrustStore=C:\Users\darka\Desktop\oneInchMarket-infra\infra\dev\knox\truststore.jks;trustStorePassword=j80pahzQ9sNoqNPN94LPCVs3lXtHQo7h

jdbc:hive2://knox.oneinchmarket.co.kr:443/default;ssl=true;transportMode=http;httpPath=gateway/sandbox/hive;sslTrustStore=C:/Users/darka/Desktop/oneInchMarket-infra/infra/dev/knox/truststore.jks;trustStorePassword=j80pahzQ9sNoqNPN94LPCVs3lXtHQo7h

/mnt/c/Users/darka/Desktop/oneinchmarket-infra/infra/dev/knox