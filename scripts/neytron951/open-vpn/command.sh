#!/bin/sh
#
# Metadata extracted to metadata.json
#
RNAME=Openvpn

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

Service() {
    # $1 - name
    # $2 - command

    if [ -n "$(which systemctl 2>/dev/null)" ]; then
        systemctl ${2} ${1}.service
    else
        if [ "${2}" = "enable" ]; then
            if [ "${OSNAME}" = "debian" ]; then
                update-rc.d ${1} enable
            else
                chkconfig ${1} on
            fi
        else
            service ${1} ${2}
        fi
    fi
}

if [ "${OSNAME}" = "debian" ]; then
    export DEBIAN_FRONTEND="noninteractive"

    # Wait firstrun script
    while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done
    apt-get update --allow-releaseinfo-change || :
    apt-get update
    test -f /usr/bin/which || apt-get -y install which
    which lsb_release 2>/dev/null || apt-get -y install lsb-release
    which logger 2>/dev/null || apt-get -y install bsdutils
    OSREL=$(lsb_release -s -c)
    pkglist="openvpn openssl easy-rsa"
    easyrsa_path=/usr/share/easy-rsa
    # Installing packages
    apt-get -y install ${pkglist}
    vpnservice=openvpn
else
    OSREL=$(rpm -qf --qf '%{version}' /etc/redhat-release | cut -d . -f 1)
    vpnservice=openvpn@server
    yum -y update

    if [ "$OSREL" = "8" ]; then
        yum -y install epel-release || yum -y install oracle-epel-release-el8
    else
        yum -y install epel-release || yum -y install oracle-epel-release-el9
    fi

    # Setting proxy
    if [ ! "({{HTTP_PROXY}})" = "()" ]; then
        PR="({{HTTP_PROXY}})"
        PR=$(echo ${PR} | sed "s/''//g" | sed 's/""//g')
        if [ -n "${PR}" ]; then
            echo "proxy=${PR}" >> /etc/yum.conf
        fi
    fi

    pkglist="openvpn easy-rsa openssl which policycoreutils iptables-services"
    vpnservice=openvpn-server@server

    yum -y install ${pkglist} || yum -y install ${pkglist} || yum -y install ${pkglist}

    # Removing proxy
    sed -r -i "/proxy=/d" /etc/yum.conf

    easyrsa_path=/usr/share/easy-rsa/3
fi

cd /etc/openvpn || return
cp -aL ${easyrsa_path} easy-rsa

cd easy-rsa || exit
if [ "${OSNAME}" = "debian" ]; then
    cp vars.example vars
else
    cp /usr/share/doc/easy-rsa/vars.example vars
fi

./easyrsa init-pki
dd if=/dev/urandom of=pki/.rnd bs=256 count=1
# CA
./easyrsa --batch build-ca nopass
CAPATH=pki/ca.crt
# server
./easyrsa --req-cn=server --batch gen-req server nopass
./easyrsa --req-cn=server --batch sign-req server server
SERVERKEYPATH=pki/private/server.key
SERVERCRTPATH=pki/issued/server.crt

# client1
./easyrsa --req-cn=client1 --batch gen-req client1 nopass
./easyrsa --req-cn=client1 --batch sign-req client client1

# dh
KEY_SIZE=$(awk '$2 ~ /KEY_SIZE/ {print $3}' vars)
if [ -z "${KEY_SIZE}" ]; then
    KEY_SIZE=2048
fi
mkdir -p /etc/openvpn/easy-rsa/keys
cp pki/private/client1.key /etc/openvpn/easy-rsa/keys
cp pki/issued/client1.crt /etc/openvpn/easy-rsa/keys
openssl dhparam -out /etc/openvpn/easy-rsa/keys/dh${KEY_SIZE}.pem ${KEY_SIZE}

SERVERCONF=/etc/openvpn/server/server.conf

cat > ${SERVERCONF} << EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/easy-rsa/${CAPATH}
cert /etc/openvpn/easy-rsa/${SERVERCRTPATH}
key /etc/openvpn/easy-rsa/${SERVERKEYPATH}
dh /etc/openvpn/easy-rsa/keys/dh${KEY_SIZE}.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 120
comp-lzo
cipher AES-256-GCM
persist-key
persist-tun
verb 3
push "redirect-gateway def1"
push "dhcp-option DNS 8.8.8.8"
EOF

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
# Detect default interface name
ifname=$(ip route get 1 | grep -Po '(?<=dev )[^ ]+')
if [ -n "$(which nft)" ] && [ -z "$(which iptables)" ]; then
    USE_NFT=yes
fi
if [ -z "${USE_NFT}" ]; then
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE
fi
if [ "${OSNAME}" = "debian" ]; then
    if [ -n "${USE_NFT}" ]; then
        nft flush ruleset
        nft add table nat
        nft add chain nat postrouting '{ type nat hook postrouting priority srcnat ; }'
        nft add rule nat postrouting ip saddr 10.8.0.0/24 oif ${ifname} masquerade
        nft -s list ruleset > /etc/nftables.rules
        if [ ! -s /etc/rc.local ]; then
            echo "#!/bin/sh" >> /etc/rc.local
        fi
        echo "nft -f /etc/nftables.rules" >> /etc/rc.local
        nft -f /etc/nftables.rules
        chmod +x /etc/rc.local
    else
        if grep -q exit /etc/rc.local ; then
            sed -i --follow-symlinks "/exit 0/i iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE" /etc/rc.local
        else
            if [ ! -s /etc/rc.local ]; then
                echo "#!/bin/sh" >> /etc/rc.local
            fi
            echo "iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${ifname} -j MASQUERADE" >> /etc/rc.local
        fi
        chmod +x /etc/rc.local
    fi
else
    firewall-cmd --permanent --zone=public --add-port=1194/udp
    firewall-cmd --permanent --zone=public --add-masquerade
    firewall-cmd --reload
    service iptables save || :
fi

Service ${vpnservice} stop || :
Service ${vpnservice} enable
Service ${vpnservice} start

cat << EOF > /etc/openvpn/client/client.ovpn
client
cipher AES-256-GCM
tls-client
dev tun
proto udp
remote $(ip r get 1 | grep -Po '(?<=src )[^ ]+') 1194
remote-cert-tls server
nobind
persist-key
persist-tun
float
keepalive 10 120
verb 3
auth-nocache
reneg-sec 43200
comp-lzo no
<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(openssl x509 -in /etc/openvpn/easy-rsa/keys/client1.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/keys/client1.key)
</key>
EOF
