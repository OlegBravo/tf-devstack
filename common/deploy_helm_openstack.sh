#!/bin/bash -xe

set -o errexit

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/common.sh"

# parameters

HELM_OPENSTACK_URL=${HELM_OPENSTACK_URL:-https://review.opendev.org/changes/663390/revisions/d10af4be2beae9ed23154e708729dbb6eebd6526/archive?format=tgz}
HELM_OPENSTACK_INFRA_URL=https://github.com/openstack/openstack-helm-infra/archive/24c1cd4514384fe22f3a882d41cf927588b03f2b.tar.gz
export OPENSTACK_RELEASE=${OPENSTACK_VERSION:-queens}
export OSH_OPENSTACK_RELEASE=${OPENSTACK_RELEASE}

[ "$(whoami)" == "root" ] && echo Please run script as non-root user && exit

# label nodes
for node in $(kubectl get nodes --no-headers | cut -d' ' -f1 | head -1); do
  kubectl label node $node --overwrite openstack-control-plane=enabled
done
for node in $(kubectl get nodes --no-headers | cut -d' ' -f1); do
  kubectl label node $node --overwrite openstack-compute-node=enabled
done

# fetch helm-openstack
wget $HELM_OPENSTACK_URL -O helm-openstack.tgz
wget $HELM_OPENSTACK_INFRA_URL -O helm-openstack-infra.tgz
mkdir -p openstack-helm openstack-helm-infra
tar xzf helm-openstack.tgz -C openstack-helm
tar xzf helm-openstack-infra.tgz --strip-components=1 -C openstack-helm-infra

# add TF overrides
cp $my_dir/../helm/files/libvirt-tf.yaml openstack-helm-infra/libvirt/values_overrides/tf.yaml
cp $my_dir/../helm/files/nova-tf.yaml openstack-helm/nova/values_overrides/tf.yaml
cp $my_dir/../helm/files/neutron-tf.yaml openstack-helm/neutron/values_overrides/tf.yaml
sed -i "s/openstack_version:.*$/openstack_version: $OSH_OPENSTACK_RELEASE/" openstack-helm/neutron/values_overrides/tf.yaml
# install and remove deps and other prereqs
if [ "$DISTRO" == "centos" ]; then
    sudo yum remove -y pyparsing
    sudo service firewalld stop
    sudo yum install -y jq nmap bc python-pip python-devel git gcc
elif [ "$DISTRO" == "ubuntu" ]; then
  sudo apt-get install --no-install-recommends -y \
        ca-certificates \
        git \
        make \
        jq \
        nmap \
        curl \
        uuid-runtime \
        bc \
        python-pip \
        python-dev
fi
sudo -H pip install -U pip wheel
sudo -H pip install --user wheel yq

# build infra charts
helm init -c
cd openstack-helm-infra
pgrep -f "helm serve" | xargs -n1 -r kill
helm serve &
sleep 5
helm repo add local http://localhost:8879/charts
make helm-toolkit

export FEATURE_GATES=tf

# TODO: set coredns replicas=1 if one node
cd ../openstack-helm-infra
make helm-toolkit
make nfs-provisioner

cd ../openstack-helm
./tools/deployment/developer/common/020-setup-client.sh
./tools/deployment/developer/common/030-ingress.sh
./tools/deployment/developer/nfs/040-nfs-provisioner.sh
./tools/deployment/developer/nfs/050-mariadb.sh
./tools/deployment/developer/nfs/060-rabbitmq.sh
./tools/deployment/developer/nfs/070-memcached.sh
./tools/deployment/developer/nfs/080-keystone.sh
./tools/deployment/developer/nfs/090-heat.sh
./tools/deployment/developer/nfs/120-glance.sh
./tools/deployment/developer/nfs/150-libvirt.sh
echo "Running nova/neutron deploy in the background"
./tools/deployment/developer/nfs/160-compute-kit.sh &

cd ../..