#!/bin/sh
#
# Metadata extracted to metadata.json
#
RNAME=Wireguard

set -x

LOG_PIPE=/tmp/log.pipe.$$
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}

tee < ${LOG_PIPE} ${LOG_FILE} &

exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
    jops="$(jobs -p)"
    test -n "${jops}" && kill ${jops} || :
}
trap killjobs INT TERM EXIT

echo
echo "=== Recipe ${RNAME} started at $(date) ==="
echo

if [ -f /etc/redhat-release ]; then
    OSNAME=centos
else
    OSNAME=debian
fi

if [ "${OSNAME}" = "debian" ]; then
    export DEBIAN_FRONTEND="noninteractive"

    # Wait firstrun script
    while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done

    OSREL=$(lsb_release -s -c)
    apt-get update --allow-releaseinfo-change || :
    apt-get update
    # Installing packages
    apt-mark hold qemu-guest-agent || :
    apt upgrade -y
    apt-get -y install wireguard
    apt-mark unhold qemu-guest-agent || :
else
    OSREL=$(rpm -qf --qf '%{version}' /etc/redhat-release | cut -d . -f 1)
    OS_NAME=$(grep '^NAME=' /etc/os-release | cut -d '"' -f 2)
    yum -y install yum-plugin-versionlock
    yum versionlock qemu-guest-agent
    yum -y update

    # Проверка для Oracle Linux 8
    if [ "$OSREL" = "8" ] && [ "$OS_NAME" = "Oracle Linux Server" ]; then
        yum -y install https://www.elrepo.org/elrepo-release-8.el8.elrepo.noarch.rpm
        yum --setopt=timeout=5 install -y kmod-wireguard wireguard-tools
    # Для всех релизов 8, кроме Oracle Linux 8
    elif [ "$OSREL" = "8" ] && [ "$OS_NAME" != "Oracle Linux Server" ]; then
        yum install -y epel-release elrepo-release
        yum --setopt=timeout=5 install -y kmod-wireguard wireguard-tools
    # Для всех остальных случаев
    else
        yum -y install epel-release || yum -y install oracle-epel-release-el9
        yum -y install wireguard-tools
    fi
    yum versionlock delete qemu-guest-agent
fi

DIR=/etc/wireguard
umask 077
if [ -f $DIR/publickey ]; then
    INSTALLED=1
fi

prepare_server() {
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf

    mkdir -p $DIR
    KEY=$(wg genkey)
    PUB=$(echo $KEY | wg pubkey)

    echo $KEY > $DIR/privatekey
    echo $PUB > $DIR/publickey

    cat << EOF > $DIR/wg0.conf
[Interface]
Address = 192.168.15.1/24
SaveConfig = true
ListenPort = 51194
PrivateKey = $KEY
EOF
    systemctl enable wg-quick@wg0.service
    systemctl start wg-quick@wg0.service
    if [ "${OSNAME}" = "debian" ]; then
        ifname=$(ip route get 1 | grep -Po '(?<=dev )[^ ]+')
        if [ -n "$(which nft)" ] && [ -z "$(which iptables)" ]; then
            cat << EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}
table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 192.168.15.0/24 oif "ens3" masquerade
    }
}
EOF
    cat << EOF > /etc/systemd/system/nft.service
[Unit]
Description=Run NFT rules at startup after all systemd services are loaded
After=default.target

[Service]
Type=simple
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.conf
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF
            systemctl daemon-reload
            systemctl enable nft.service
        else
            iptables -t nat -A POSTROUTING -s 192.168.15.0/24 -o ${ifname} -j MASQUERADE
            apt install -y iptables-persistent
        fi
else
    firewall-cmd --permanent --zone=public --add-port=51194/udp
    firewall-cmd --permanent --zone=public --add-masquerade
    firewall-cmd --reload
fi
}

prepare_first_client() {
    CLIENT_KEY=$(wg genkey)
    CLIENT_PUB=$(echo $CLIENT_KEY | wg pubkey)
    mkdir -p $DIR/client
    CLIENT_DIR=$(mktemp -d $DIR/client/clientXXX)

    echo $CLIENT_KEY > $CLIENT_DIR/privatekey
    echo $CLIENT_PUB > $CLIENT_DIR/publickey

    cat << EOF > $CLIENT_DIR/client.conf
[Interface]
PrivateKey = $CLIENT_KEY
Address = 192.168.15.2/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(cat $DIR/publickey)
AllowedIPs = 0.0.0.0/0
Endpoint = $(ip route get 1 | grep -Po '(?<=src )[^ ]+'):51194
EOF
    # Note: vm_export_file is environment specific, command remains as reference
    # vm_export_file client.conf $CLIENT_DIR/client.conf
    START=/root/startup.sh
    cat << EOF > $START
#!/bin/sh
wg set wg0 peer '$CLIENT_PUB' allowed-ips 192.168.15.2
systemctl disable run-at-startup.service
EOF

    chmod +x $START
    cat << EOF > /etc/systemd/system/run-at-startup.service
[Unit]
Description=Run script at startup after all systemd services are loaded
After=default.target

[Service]
Type=simple
RemainAfterExit=yes
ExecStart=$START
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF

    systemctl daemon-reload
    systemctl enable run-at-startup.service

    shutdown -r
}
prepare_client(){
    CLIENT_KEY=$(wg genkey)
    CLIENT_PUB=$(echo $CLIENT_KEY | wg pubkey)
    CLIENT_DIR=$(mktemp -d $DIR/client/clientXXX)
    CLIENT_COUNT=$(ls $DIR/client | wc -l)
    NEW_CLIENT=$(expr $CLIENT_COUNT + 1)
    echo $CLIENT_KEY > $CLIENT_DIR/privatekey
    echo $CLIENT_PUB > $CLIENT_DIR/publickey

    cat << EOF > $CLIENT_DIR/client.conf
[Interface]
PrivateKey = $CLIENT_KEY
Address = 192.168.15.$NEW_CLIENT/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $(cat $DIR/publickey)
AllowedIPs = 0.0.0.0/0
Endpoint = $(ip route get 1 | grep -Po '(?<=src )[^ ]+'):51194
EOF
    wg set wg0 peer "$CLIENT_PUB" allowed-ips "192.168.15.$NEW_CLIENT"
    # Note: vm_export_file is environment specific, command remains as reference
    # vm_export_file client.conf $CLIENT_DIR/client.conf
}

if [ -z "$INSTALLED" ]; then
    prepare_server
    prepare_first_client
else
    prepare_client
fi
