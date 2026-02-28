docker build -t freeipa-systemd:latest .
kind load docker-image freeipa-systemd:latest --name dev

myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.IPA_ADMIN_PASSWORD=env(myenv)' freeipa-configmap.yaml
myenv=$(head -c 24 /dev/random | base64) yq e --inplace '.data.IPA_DM_PASSWORD=env(myenv)' freeipa-configmap.yaml

sudo kubectl apply -f freeipa-configmap.yaml -f freeipa-statefulset.yaml -f freeipa-nodeport.yaml -f freeipa-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/freeipa-nodeport 18083:18083 > /dev/null 2>&1 &