#!/bin/bash -x

# TODO: for now supports only one insecure registry
# try to avoid embeded python snippets

my_file="$(readlink -e "$0")"
my_dir="$(dirname "$my_file")"

mkdir -p /etc/docker
docker_config=/etc/docker/daemon.json
touch $docker_config

default_iface=`ip route get 1 | grep -o "dev.*" | awk '{print $2}'`
default_iface_mtu=`ip link show $default_iface | grep -o "mtu.*" | awk '{print $2}'`
echo MTU $default_iface_mtu detected
export DOCKER_MTU=$default_iface_mtu 

export DOCKER_INSECURE_REGISTRIES=$(python -c "import json; f=open('$docker_config'); r=json.load(f).get('insecure-registries', []); print('\n'.join(r))" 2>/dev/null)
if [[ -n "$CONTAINER_REGISTRY" ]] ; then
  registry=`echo $CONTAINER_REGISTRY | sed 's|^.*://||' | cut -d '/' -f 1`
  if  curl -s -I --connect-timeout 60 http://$registry/v2/ ; then
    DOCKER_INSECURE_REGISTRIES=$(echo -e "${DOCKER_INSECURE_REGISTRIES}\n${registry}" | grep '.\+' | sort | uniq)
  fi
fi

${my_dir}/jinja2_render.py <"${my_dir}/files/docker_daemon.json.j2" > $docker_config
