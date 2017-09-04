#!/bin/bash
#Author: ZhenNan.luo(Jenner)
#
set -e

this_dir=$(dirname $BASH_SOURCE)

add_local_repo(){
    local repo_name=${1:-localrepo}
    local baseurl=${2:-file://$(pwd)/docker_rpm}
    cat > /etc/yum.repos.d/${repo_name}.repo<<EOF
[$repo_name]
name=$repo_name repo
baseurl=$baseurl
enabled=1
gpgcheck=0
EOF
}

yum_local_install(){
    local pkg_name=$1
    local enablerepo=${2:-localrepo}
    yum install -y $pkg_name --disablerepo=* --enablerepo=$enablerepo
}

append_mountflags(){
    local kolla_conf=$1
    tee $kolla_conf <<-'EOF'
[Service]
MountFlags=shared
EOF
}

set_docker_mountflags(){
    local docker_service_d=/etc/systemd/system/docker.service.d
    mkdir -p $docker_service_d
    local kolla_conf=${docker_service_d}/kolla.conf
    if [[ ! -f $kolla_conf ]]; then
        append_mountflags $kolla_conf
    fi
}

restart_docker(){
    systemctl daemon-reload
    systemctl restart docker
}

install_docker(){
    local repo_name=${1:-docker-local}
    local baseurl=${2:-file://$(pwd)/docker_ce_rpm}
    local pkg_name=${3:-docker-ce}
    add_local_repo $repo_name $baseurl
    yum_local_install $pkg_name $repo_name
    set_docker_mountflags
    restart_docker
}


docker_load_registry(){
    local reg_image=${1:-$this_dir/registry-2.3.tar.gz}
    if [[ -f $reg_image ]]; then
        docker load -i $reg_image
    fi
}

get_local_ip(){
    local eth=${1:-eth0}
    local localIp=$(ifconfig $eth | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p')
    echo $localIp
}

cat_insecure_registry(){
    local ip=${1:?Please Input Ip}
cat > /etc/docker/daemon.json <<EOF
{ "insecure-registries":["$ip:4000"]}
EOF
}

add_insecure_registry(){
    local eth=${1:-eth0}
    cat_insecure_registry $(get_local_ip $eth)
}

docker_run_registry(){
    local host_dir=${1:-/opt/registry}
    local container_dir=${2:-/var/lib/registry}
    local container_name=${3:-registry}
    docker rm -f $container_name || echo "No $container_name exist"
    docker run -d -v ${host_dir}:${container_dir} -p 4000:5000 --restart=always --name $container_name registry:2.3
    tar zxf centos-binary-registry-ocata.tar.gz -C ${host_dir}
}

set_virt_type(){
    local kolla_nova=/etc/kolla/config/nova
    mkdir -p $kolla_nova
cat << EOF > $kolla_nova/nova-compute.conf
[libvirt]
virt_type=qemu
EOF
}

check_vm(){
    local run_in_vm=$1
    local vm_count=$(egrep -c '(vmx|svm)' /proc/cpuinfo)
    if [[ "$run_in_vm" == 'true' ]]; then
        set_virt_type
    elif  [[ $vm_count == 0 ]]; then
        set_virt_type
    fi
}

pip_u_install(){
   local args=($@)
   local envPip=pip
   local tar_pkgs_dirs=$(pwd)/py_pkgs
   for i in "${!args[@]}"
   do
        local pkg_name="${args[$i]}"
        $envPip install -U $pkg_name --no-index --find-links file://$tar_pkgs_dirs
   done
}


sed_kolla_globals(){
    local vip_address=$1
    local network_interface=${2:-eth0}
    local neutron_external_interface=${3:-eth1}
    local docker_namespace=${4:-lokolla}    
    local openstack_release=${5:-4.0.3}

    local globals_yml=/etc/kolla/globals.yml
    sed -i "s#kolla_internal_vip_address:.*#kolla_internal_vip_address: \"${vip_address}\"#g" $globals_yml
    sed -i "s|^#*docker_registry:.*|docker_registry: \"${vip_address}:4000\"|g" $globals_yml
    sed -i "s|^#*docker_namespace:.*|docker_namespace: \"${docker_namespace}\"|g" $globals_yml
    sed -i "s|^#*network_interface:.*|network_interface: \"${network_interface}\"|g" $globals_yml
    sed -i "s|^#*neutron_external_interface:.*|neutron_external_interface: \"${neutron_external_interface}\"|g" $globals_yml
    sed -i "s|^#*openstack_release:.*|openstack_release: \"${openstack_release}\"|g" $globals_yml
}

kolla_globals_enable_cinder(){
    local dev_path=${1:?Please Input Available Device}
    local globals_yml=/etc/kolla/globals.yml
    pvcreate $dev_path
    vgcreate cinder-volumes $dev_path
    sed -i "s|^#*enable_cinder:.*|enable_cinder: \"yes\"|g" $globals_yml
    sed -i "s|^#*enable_cinder_backend_lvm:.*|enable_cinder_backend_lvm: \"yes\"|g" $globals_yml
}

sed_all_yml(){
    local all_yml=/usr/share/kolla-ansible/ansible/group_vars/all.yml
    sed -i "s|^#*enable_haproxy:.*|enable_haproxy: \"no\"|g" $all_yml
}

set_host_name(){
    local host_name=${1:-all-in-one}
    hostnamectl set-hostname --static $host_name
}

install_kolla_ansible(){
    pip_u_install kolla-ansible
    cp -r /usr/share/kolla-ansible/etc_examples/kolla /etc/
    cp /usr/share/kolla-ansible/ansible/inventory/* .
}


main(){
    local run_in_vm=true
    local eth_name=eth0
    local repo_name=local-rpms
    local baseurl=file://$(pwd)/yum_pkgs
    local dev_path=/dev/vdb

    local local_ip=$(get_local_ip $eth_name)

    install_docker
    docker_load_registry
    docker_run_registry
    add_insecure_registry $eth_name
    restart_docker
    check_vm $run_in_vm
    

    add_local_repo $repo_name $baseurl
    yum_local_install python-pip $repo_name

    pip_u_install pip

    yum_local_install python-devel $repo_name
    yum_local_install libffi-devel $repo_name
    yum_local_install gcc $repo_name
    yum_local_install openssl-devel $repo_name
    yum_local_install libselinux-python $repo_name
    yum_local_install ansible $repo_name

    pip_u_install docker
    pip_u_install Jinja2

    yum_local_install ntp $repo_name
    systemctl enable ntpd.service
    systemctl start ntpd.service

    systemctl stop libvirtd.service || echo "Not libvirtd.service"
    systemctl disable libvirtd.service || echo "Not libvirtd.service"

    install_kolla_ansible
    sed_kolla_globals $local_ip
    sed_all_yml

    ##kolla_globals_enable_cinder $dev_path

    set_host_name

    kolla-genpwd

    kolla-ansible prechecks -i  all-in-one

    kolla-ansible deploy -i all-in-one
    
    # kolla-ansible post-deploy
    # source /etc/kolla/admin-openrc.sh
    # cd /usr/share/kolla-ansible
    # ./init-runonce
}

main