#!/bin/bash
set -e

# Timing doesn't work on zsh currently (works on bash)
START_TIME=`date "+%s"`

# Put same user as in ssh key here
user=student

# Below ZONE and PROJECT variables are just in case You don't have those defaults set up in gcloud (you should).
ZONE="europe-west4-a"
PROJECT="default"
DEFAULT_PROJECT=`gcloud config list --format 'value(core.project)'`
DEFAULT_ZONE=`gcloud config list --format 'value(compute.zone)'`
ZONE="${DEFAULT_ZONE:-$ZONE}"
PROJECT="${DEFAULT_PROJECT:-$PROJECT}"

ACTION='create'
CLUSTER_NAME='' #'k3s'
PRIVATE_KEY='' #'~/.ssh/id_rsa'
IMAGE_NAME='' #'mohitsoni98/movielib'
PORT='' #'3000'

if [[ $# -lt 10 ]]
then
  echo "USAGE: ./deploy.sh -action <create|delete> -name <CLUSTER_NAME> -key <PRIVATE_KEY> -image <DOCKER_IMAGE_NAME> -port <OPEN_PORT_FOR_APP>"
  exit 0
fi
while test $# -gt 0; do
    case "$1" in
      -action)
        shift
        ACTION=$1
        shift
        ;;
      -name)
        shift
        CLUSTER_NAME=$1
        shift
        ;;
      -key)
        shift
        PRIVATE_KEY=$1
        shift
        ;;
      -image)
        shift
        IMAGE_NAME=$1
        shift
        ;;
      -port)
        shift
        PORT=$1
        shift
        ;;
      *)
        echo "USAGE: ./deploy.sh -action <create|delete> -name <CLUSTER_NAME> -key <PRIVATE_KEY> -image <DOCKER_IMAGE_NAME> -port <OPEN_PORT_FOR_APP>"
        exit 0
        ;;
  esac
done

# Setting up ssh keys
sudo mkdir -p ~/.ssh > /dev/null
sudo cp -f $PRIVATE_KEY ~/.ssh/id_rsa > /dev/null
sudo rm -f ~/.ssh/known_hosts > /dev/null

# For Delete Action
if [ "$ACTION" = "delete" ]
then
  gcloud compute instances delete $CLUSTER_NAME-master $CLUSTER_NAME-worker1 $CLUSTER_NAME-worker2 $CLUSTER_NAME-worker3
  echo "Cluster $CLUSTER_NAME deleted"
  exit 0
fi

# For Create Action
echo "----- K3S GO!!! -----"

# Creating Master VM on Google Cloud
gcloud compute --project=$PROJECT instances create $CLUSTER_NAME-master \
--zone=$ZONE \
--machine-type=n1-standard-2 \
--tags=k3smaster,k3s-$CLUSTER_NAME \
--subnet=default \
--network-tier=PREMIUM \
--maintenance-policy=MIGRATE \
--image=ubuntu-minimal-2004-focal-v20210511 \
--image-project=ubuntu-os-cloud \
--no-user-output-enabled > /dev/null &

# Creating Worker VMs on Google Cloud
gcloud compute --project=$PROJECT instances create $CLUSTER_NAME-worker1 $CLUSTER_NAME-worker2 $CLUSTER_NAME-worker3 \
--zone=$ZONE \
--machine-type=n1-standard-2 \
--tags=k3s-$CLUSTER_NAME \
--subnet=default \
--network-tier=PREMIUM \
--maintenance-policy=MIGRATE \
--image=ubuntu-minimal-2004-focal-v20210511  \
--image-project=ubuntu-os-cloud \
--no-user-output-enabled >/dev/null &

echo "-----Creating VMs... -----"
sleep 10

# Extracting IP address of Master VM
master_public=`gcloud compute instances describe --zone=$ZONE  --project=$PROJECT $CLUSTER_NAME-master --format='get(networkInterfaces[0].accessConfigs[0].natIP)'`
master_private=`gcloud compute instances describe --zone=$ZONE  --project=$PROJECT $CLUSTER_NAME-master --format='get(networkInterfaces[0].networkIP)'`

# Waiting for the nodes
until ssh  -q -o "StrictHostKeyChecking=no" -o "ConnectTimeout=3" $user@$master_public 'hostname' > /dev/null
do
  echo "----- Waiting for the nodes... -----"
  sleep 3
done

# Deploying K3S server on Master Node
echo "----- Nodes ready... deploying k3s on master... -----"
ssh -q -o "StrictHostKeyChecking=no" $user@$master_public 'sudo modprobe ip_vs'
ssh -q -o "StrictHostKeyChecking=no" -t $user@$master_public "curl -sfL https://get.k3s.io | sh -s - server --tls-san $master_public --node-external-ip=$master_public" > /dev/null

# Extracting Token from master K3S Server
token=`ssh -q -o "StrictHostKeyChecking=no" -t $user@$master_public 'sudo cat /var/lib/rancher/k3s/server/node-token'`

# Deploying K3S agents on Worker Nodes
echo "----- K3s master deployed... -----"
echo "----- Downloading kubectl config... -----"
ssh -q -o "StrictHostKeyChecking=no" -t $user@$master_public "sudo cp /etc/rancher/k3s/k3s.yaml /home/$user && sudo chown $user:$user /home/$user/k3s.yaml"

echo "----- Deploying worker nodes... -----"
for worker in $CLUSTER_NAME-worker1 $CLUSTER_NAME-worker2 $CLUSTER_NAME-worker3
do
  host=`gcloud compute instances describe --project=$PROJECT --zone=$ZONE $worker --format='get(networkInterfaces[0].accessConfigs[0].natIP)'`
  ssh -q -o "StrictHostKeyChecking=no" $user@$host 'sudo modprobe ip_vs'  
  ssh -q -o "StrictHostKeyChecking=no" $user@$host "curl -sfL https://get.k3s.io | K3S_URL=https://$master_public:6443 K3S_TOKEN=$token sh -s - --node-external-ip $host" &>/dev/null  &
done

# Waiting for the nodes to be ready
echo "----- Deployment finished... waiting for all the nodes to become k3s ready... -----"

nodes_check=`ssh -q -o "StrictHostKeyChecking=no" $user@$master_public "sudo kubectl get nodes | grep Ready | wc -l"`
  while [ "$nodes_check" != "4" ]
  do
    echo "----- Waiting... -----"
    nodes_check=`ssh -q -o "StrictHostKeyChecking=no" $user@$master_public "sudo kubectl get nodes | grep Ready | wc -l"`
    sleep 3
  done

# Deploying Application on K3S Nodes
echo '----- Deploying application on Kubernetes Containers ---'
CLUSTER_NAME=$CLUSTER_NAME IMAGE_NAME=$IMAGE_NAME PORT=$PORT envsubst < ./template.yaml | tee ./configuration.yaml &> /dev/null
scp -i Private.pem ./configuration.yaml $user@$master_public:/home/$user/configuration.yaml &> /dev/null
ssh -q -o "StrictHostKeyChecking=no" $user@$master_public 'sudo k3s kubectl apply -f ./configuration.yaml' &> /dev/null

# App deployed successfully
END_TIME=`date "+%s"`
echo "----- After $((${END_TIME} - ${START_TIME})) seconds - your cluster is ready :) -----"
echo "Your App has been hosted on http://$master_public" 
