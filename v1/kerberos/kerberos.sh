sudo kubectl apply -f kerberos-configmap.yaml -f kerberos-statefulset.yaml -f kerberos-headless.yaml -n dev

kadmin.local
addprinc -randkey knox/knox-0.knox-headless.dev.svc.cluster.local@ONEINCHMARKET.CO.KR
ktadd -k /tmp/knox.service.keytab knox/knox-0.knox-headless.dev.svc.cluster.local@ONEINCHMARKET.CO.KR
addprinc -randkey hive/hive-server-headless.dev.svc.cluster.local@ONEINCHMARKET.CO.KR
ktadd -k /tmp/hive.service.keytab hive/hive-server-headless.dev.svc.cluster.local@ONEINCHMARKET.CO.KR