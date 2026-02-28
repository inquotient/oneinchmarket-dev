sudo kind create cluster --name dev --config cluster-config.yaml
sudo kubectl create namespace dev
mkdir ~/.kube
sudo kubectl config view --raw=true > ~/.kube/config

sudo kind delete cluster --name dev

# kind cluster의 경우 kafka-rest Pod 생성 시에 failed to create fsnotify watcher: too many open files 발생 가능
sudo sysctl fs.inotify.max_user_watches
sudo sysctl fs.inotify.max_user_instances
sudo sysctl fs.inotify.max_queued_events
ulimit -n

# 위의 결과에 따라서 취사 선택
sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=1024
sudo sysctl -w fs.inotify.max_queued_events=65536
