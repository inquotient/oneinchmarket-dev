sudo kill -9 $(ps -ef | grep "kubectl -n dev port-forward svc/jenkins-nodeport" | sed -n '2p' | gawk '{ print $2"\t"$3 }')
sudo kubectl apply -f jenkins-statefulset.yaml -f jenkins-nodeport.yaml -f jenkins-headless.yaml -n dev
sudo kubectl -n dev port-forward svc/jenkins-nodeport 20080:20080 > /dev/null 2>&1 &