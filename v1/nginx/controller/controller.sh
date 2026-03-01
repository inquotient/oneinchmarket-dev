# kind cluster는 아래의 내용으로 생성(https://kind.sigs.k8s.io/docs/user/ingress/#ingress-nginx)
# aws와 같은 다른 provider는 아래를 참고
# https://kubernetes.github.io/ingress-nginx/deploy/
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

sudo kubectl apply -f controller-configmap.yaml