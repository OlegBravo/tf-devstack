#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

function ensure_root() {
  local me=$(whoami)
  if [ "$me" != 'root' ] ; then
    echo "ERROR: this script requires root, run it like this:"
    echo "       sudo -E $0"
    exit 1;
  fi
}

function ensure_kube_api_ready() {
  if ! wait_cmd_success "kubectl get nodes" 3 40 ; then
    echo "ERROR: kubernetes is not ready. Exiting..."
    exit 1
  fi
}

function fetch_deployer() {
  sudo rm -rf "$WORKSPACE/$DEPLOYER_DIR"
  local image="$CONTAINER_REGISTRY/$DEPLOYER_IMAGE"
  [ -n "$CONTRAIL_CONTAINER_TAG" ] && image+=":$CONTRAIL_CONTAINER_TAG"
  sudo docker create --name $DEPLOYER_IMAGE --entrypoint /bin/true $image
  sudo docker cp $DEPLOYER_IMAGE:$DEPLOYER_DIR - | tar -x -C $WORKSPACE
  sudo docker rm -fv $DEPLOYER_IMAGE
}

function wait_cmd_success() {
  # silent mode = don't print output of input cmd for each attempt.
  local cmd=$1
  local interval=${2:-3}
  local max=${3:-300}
  local silent_cmd=${4:-1}

  local xtrace_save=$(set +o | grep 'xtrace')
  set +o xtrace
  local pipefail_save=$(set +o | grep 'pipefail')
  set -o pipefail
  local i=0
  if [[ "$silent_cmd" != "0" ]]; then
    local to_dev_null="&>/dev/null"
  else
    local to_dev_null=""
  fi
  while ! eval "$cmd" "$to_dev_null"; do
    printf "."
    i=$((i + 1))
    if (( i > max )) ; then
      echo ""
      echo "ERROR: wait failed in $((i*10))s"
      eval "$cmd"
      $xtrace_save
      return 1
    fi
    sleep $interval
  done
  echo ""
  echo "INFO: done in $((i*10))s"
  $xtrace_save
  $pipefail_save
}

function wait_nic_up() {
  local nic=$1
  printf "INFO: wait for $nic is up"
  if ! wait_cmd_success "nic_has_ip $nic" 10 60; then
    echo "ERROR: $nic is not up"
    return 1
  fi
  echo "INFO: $nic is up"
}

function nic_has_ip() {
  local nic=$1
  if nic_ip=$(ip addr show $nic | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*"); then
    printf "\n$nic has IP $nic_ip"
    return 0
  else
    return 1
  fi
}

function set_ssh_keys() {
  [ ! -d ~/.ssh ] && mkdir ~/.ssh && chmod 0700 ~/.ssh
  [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ''
  [ ! -f ~/.ssh/authorized_keys ] && touch ~/.ssh/authorized_keys && chmod 0600 ~/.ssh/authorized_keys
  grep "$(<~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys -q || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
}

function label_nodes_by_ip() {
  local label=$1
  shift
  local node_ips=$(echo $* | tr ' ' '\n')
  wait_cmd_success "kubectl get nodes --no-headers" 5 2
  for node in $(kubectl get nodes --no-headers | cut -d ' ' -f 1) ; do
    local nodeip=$(kubectl get node $node -o=jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    if echo $node_ips | grep -F $nodeip; then
      kubectl label node --overwrite $node $label
    fi
  done
}

function check_pods_active() {
  declare -a pods
  readarray -t pods < <(kubectl get pods --all-namespaces --no-headers)

  if [[ ${#pods[@]} == '0' ]]; then
    return 1
  fi

  #check if all pods are running
  for pod in "${pods[@]}" ; do
    local status="$(echo $pod | awk '{print $4}')"
    if [[ "$status" == 'Completed' ]]; then
      continue
    elif [[ "$status" != "Running" ]] ; then
      return 1
    else
      local containers_running=$(echo $pod  | awk '{print $3}' | cut  -f1 -d/ )
      local containers_total=$(echo $pod  | awk '{print $3}' | cut  -f2 -d/ )
      if [ "$containers_running" != "$containers_total" ] ; then
        return 1
      fi
    fi
  done
  return 0
}

function check_tf_active() {
  if ! command -v contrail-status ; then
    return 1
  fi
  local line=
  for line in $(sudo contrail-status | egrep ": " | grep -v "WARNING" | awk '{print $2}'); do
    if [ "$line" != "active" ] && [ "$line" != "backup" ] ; then
      return 1
    fi
  done
  return 0
}

#TODO time sync restart needed when startup from snapshot
function setup_timeserver() {
  # install timeserver
  if [ "$DISTRO" == "centos" ]; then
    sudo yum install -y ntp
    sudo systemctl enable ntpd
    sudo systemctl start ntpd
  elif [ "$DISTRO" == "ubuntu" ]; then
    DEBIAN_FRONTEND=noninteractive
    # Check for Ubuntu 18
    sudo apt update -y

    local ubuntu_release=`lsb_release -r | awk '{split($2,a,"."); print a[1]}'`
    if [ 16 -eq $ubuntu_release ]; then
      sudo apt install -y ntp
    else # Ubuntu 18 or more
      sudo apt install -y chrony
    fi
  else
    echo "Unsupported OS version"
    exit 1
  fi
}
