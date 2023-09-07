sudo kind create cluster --name dev --config cluster-config.yaml
sudo kubectl create namespace dev
sudo kubectl config view --raw=true > ~/.kube/config