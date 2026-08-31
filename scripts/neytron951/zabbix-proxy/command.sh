#!/bin/bash
# tags: debian11,debian12,ubuntu2004,ubuntu2204,ubuntu2404,alma8,alma9,centos9,oracle8,oracle9,rocky8,rocky9

lock_check() {
  MAX_WAIT=600
  SLEEP_INTERVAL=10
  WAITED=0
  while lsof /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock | grep .; do
      echo "Waiting to unlock dpkg/apt..."
      sleep $SLEEP_INTERVAL
      WAITED=`expr $WAITED + $SLEEP_INTERVAL`

      if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "The waiting time has been exceeded."
        exit 1
      fi
  done
  echo -e "Done! No locks."
}

init() {
  set -x
  LOG_PIPE=/tmp/log.pipe.$$
  mkfifo ${LOG_PIPE}

  LOG_FILE=/root/zabbix.log
  touch ${LOG_FILE}
  chmod 600 ${LOG_FILE}
  tee < ${LOG_PIPE} ${LOG_FILE} &
  exec > ${LOG_PIPE}
  exec 2> ${LOG_PIPE}

  if [ -e '/etc/redhat-release' ]; then
    while ps uxaww | egrep '^yum|^dnf'; do echo 'waiting...'; sleep 3; done

    yum -y update --exclude=qemu-guest-agent && yum install -y epel-release
    [ -e '/etc/yum.repos.d/epel.repo' ] && sed -i '/[epel]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
  else
    while ps uxaww | egrep '^apt|^apt-get|^dpkg'; do echo 'waiting...'; sleep 3; done

    export DEBIAN_FRONTEND='noninteractive'
    apt-mark hold qemu-guest-agent || :
    apt-get update
    apt-get -y upgrade
    apt-get -y install wget
    apt-mark unhold qemu-guest-agent || :
  fi

  OS_NAME=$(cat /etc/os-release    | egrep '^NAME'       | awk '{ sub(/.*NAME="/,"");sub(/".*/,"");print tolower($1)}')
  OS_VERSION=$(cat /etc/os-release | egrep '^VERSION_ID' | awk '{ sub(/.*VERSION_ID="/,"");sub(/".*/,"");print}')

  if [ "$TEST_CI" = "TRUE" ]; then
      ZABBIX_VERSION="$ZABBIX_VERSION_CI"
      ZABBIX_SERVER="$ZABBIX_SERVER_CI"
  else
      ZABBIX_VERSION="{{ZABBIX_VERSION}}"
      ZABBIX_SERVER="{{ZABBIX_SERVER}}"
  fi

  ZABBIX_PORT=10051
  LINUX_PKGS='pwgen mariadb-server'
  ZABBIX_PKGS='zabbix-proxy-mysql'
  REPO_URL='https://repo.zabbix.com/zabbix'
}

installZabbix() {
  if [ -e '/etc/redhat-release' ]; then
    for _ in 1 2 3; do
      yum install -y ${REPO_URL} && break
      sleep 5
    done
    yum clean all
    for _ in 1 2 3; do
      yum install -y ${LINUX_PKGS} ${ZABBIX_PKGS} && break
      sleep 5
      yum clean all
    done

    systemctl enable mariadb && systemctl restart mariadb
  else
    wget ${REPO_URL} -O /tmp/repo.deb
    lock_check
    dpkg -i /tmp/repo.deb
    [ -e '/tmp/repo.deb' ] && rm -f /tmp/repo.deb
    apt-get update
    lock_check
    apt-get install -y ${LINUX_PKGS} ${ZABBIX_PKGS}
  fi
}

configMySQL() {
  if [ ! -e '/root/.my.cnf' ]; then
    ROOT_PASS=$(pwgen -s 12 1)

    [ -e '/usr/bin/mysqladmin' ] && /usr/bin/mysqladmin -u root password ${ROOT_PASS}

    touch /root/.my.cnf
    chmod 600 /root/.my.cnf
    echo '[client]' > /root/.my.cnf
    echo "password=${ROOT_PASS}" >> /root/.my.cnf
  fi

  [ -e '/etc/zabbix/zabbix_proxy.conf' ]  && ZABBIX_PASS=$(grep 'DBPassword=' /etc/zabbix/zabbix_proxy.conf | awk -F '=' '{ print $2 }')
  [ -e '/etc/zabbix/zabbix_server.conf' ] && ZABBIX_PASS=$(grep 'DBPassword=' /etc/zabbix/zabbix_server.conf | awk -F '=' '{ print $2 }')
  [ -z "${ZABBIX_PASS}" ]                 && ZABBIX_PASS=$(pwgen -s 12 1)

  if [ "${ZABBIX_VERSION}" = "5.0" ]; then
    echo "create database if not exists zabbix_proxy character set utf8 collate utf8_bin;" | mysql --defaults-file=/root/.my.cnf
  else
    echo "create database if not exists zabbix_proxy character set utf8mb4 collate utf8mb4_bin;" | mysql --defaults-file=/root/.my.cnf
  fi

  [ -z "$(echo "select * from mysql.user where User='zabbix';" | mysql --defaults-file=/root/.my.cnf -N)" ] && echo "create user zabbix@localhost identified by '${ZABBIX_PASS}';" | mysql --defaults-file=/root/.my.cnf
  [ -n "$(echo "show databases like 'zabbix_proxy';" | mysql --defaults-file=/root/.my.cnf -N)" ] && echo "grant all privileges on zabbix_proxy.* to zabbix@localhost;" | mysql --defaults-file=/root/.my.cnf

  echo "set global log_bin_trust_function_creators = 1;" | mysql --defaults-file=/root/.my.cnf

  if [ "$ZABBIX_VERSION" = "7.2" ]; then
    if [ -e '/usr/share/zabbix/sql-scripts/mysql/proxy.sql' ]; then
        [ -z "$(echo 'show tables' | mysql --defaults-file=/root/.my.cnf -N zabbix_proxy)" ] && cat /usr/share/zabbix/sql-scripts/mysql/proxy.sql | mysql --default-character-set=utf8mb4 -uzabbix -p${ZABBIX_PASS} zabbix_proxy
    fi
  else
    if [ -e '/usr/share/zabbix-sql-scripts/mysql/proxy.sql' ]; then
      [ -z "$(echo 'show tables' | mysql --defaults-file=/root/.my.cnf -N zabbix_proxy)" ] && cat /usr/share/zabbix-sql-scripts/mysql/proxy.sql | mysql --default-character-set=utf8mb4 -uzabbix -p${ZABBIX_PASS} zabbix_proxy
    fi
  fi

  if [ -e "$(find /usr/share/doc/ -name 'zabbix-proxy-mysql*')/schema.sql.gz" ]; then
    [ -z "$(echo 'show tables' | mysql --defaults-file=/root/.my.cnf -N zabbix_proxy)" ] && zcat /usr/share/doc/zabbix-proxy-mysql*/schema.sql.gz | mysql -uzabbix -p${ZABBIX_PASS} zabbix_proxy
  fi

  echo 'set global log_bin_trust_function_creators = 0;' | mysql --defaults-file=/root/.my.cnf
}

configZabbix() {
  sed -i '/ProxyMode=0/cProxyMode=1' /etc/zabbix/zabbix_proxy.conf
  sed -i '/DBHost/cDBHost=localhost' /etc/zabbix/zabbix_proxy.conf
  sed -i '/AllowUnsupportedDBVersions/cAllowUnsupportedDBVersions=1' /etc/zabbix/zabbix_proxy.conf

  [ -n "${ZABBIX_PASS}" ]   && sed -i "/DBPassword=/cDBPassword=${ZABBIX_PASS}" /etc/zabbix/zabbix_proxy.conf
  [ -n "${ZABBIX_SERVER}" ] && sed -i "s/^Server=127.0.0.1/Server=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_proxy.conf

  while [ -n "$(ss -tupln | grep ${ZABBIX_PORT})" ]; do ZABBIX_PORT=$((ZABBIX_PORT+1));done

  sed -i "/^#\s*ListenPort=10051/a ListenPort=${ZABBIX_PORT}" /etc/zabbix/zabbix_proxy.conf
}

main() {
  init

  case "${OS_NAME}${OS_VERSION}" in
    debian11)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian11_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian11_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+debian11_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-2+debian11_all.deb"
          ;;
      esac
      ;;
    debian12)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"

      case "${ZABBIX_VERSION}" in
        7.2)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian12_all.deb"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian12_all.deb"
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-5+debian12_all.deb"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for Debian12'
          return 0
          ;;
      esac
      ;;
    ubuntu20.04)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu20.04_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu20.04_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+ubuntu20.04_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+focal_all.deb"
          ;;
      esac
      ;;
    ubuntu22.04)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"

      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb"
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+ubuntu22.04_all.deb"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for Ubuntu22.04'
          return 0
          ;;
      esac
     ;;
    ubuntu24.04)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu24.04_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu24.04_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-6+ubuntu24.04_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-2+ubuntu24.04_all.deb"
          ;;
      esac
      ;;
    almalinux9*)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"

      case "${ZABBIX_VERSION}" in
        7.2)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/alma/9/noarch/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for AlmaLinux9'
          return 0
          ;;
      esac
      ;;
    almalinux8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/alma/8/noarch/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
    centos9)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"

      case "${ZABBIX_VERSION}" in
        7.2)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/centos/9/noarch/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for CentOS9'
          return 0
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
      esac
      ;;
    oracle9*)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"

      case "${ZABBIX_VERSION}" in
        7.2)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/oracle/9/noarch//zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for Oracle9'
          return 0
          ;;
      esac
      ;;
    oracle8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/oracle/8/noarch//zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
    rocky9*)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"

      case "${ZABBIX_VERSION}" in
        7.2)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/rocky/9/noarch//zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          echo 'Zabbix-proxy version 5.0 missing for Rocky9'
          return 0
          ;;
      esac
      ;;
    rocky8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/rocky/8/noarch//zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-sql-scripts zabbix-selinux-policy"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
  esac

  [ -n "$(echo ${REPO_URL} | egrep '\.deb$|\.rpm$')" ] && installZabbix
  [ -n "$(ps aux | grep '^mysql')" ]                   && configMySQL
  [ -e '/etc/zabbix/zabbix_proxy.conf' ]               && configZabbix
  [ -e '/usr/bin/firewall-cmd' ]                       && firewall-cmd --permanent --zone=public --add-port=${ZABBIX_PORT}/tcp && firewall-cmd --reload

  systemctl restart zabbix-proxy
  systemctl enable zabbix-proxy
}

main
