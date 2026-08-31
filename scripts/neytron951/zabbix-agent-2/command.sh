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

    yum -y update --exclude=qemu-guest-agent
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

  ZABBIX_PKGS='zabbix-agent2'
  REPO_URL='https://repo.zabbix.com/zabbix'
}

installZabbix() {
  if [ -e '/etc/redhat-release' ]; then
    yum install -y ${REPO_URL}
    yum clean all
    yum install -y ${ZABBIX_PKGS}
  else
    wget ${REPO_URL} -O /tmp/repo.deb
    lock_check
    dpkg -i /tmp/repo.deb
    [ -e '/tmp/repo.deb' ] && rm -f /tmp/repo.deb
    apt-get update
    lock_check
    apt-get install -y ${ZABBIX_PKGS}
  fi
}

configZabbix() {
  [ -e '/etc/zabbix/zabbix_agentd.conf' ] && sed -i "s/^Server=127.0.0.1/Server=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agentd.conf
  [ -e '/etc/zabbix/zabbix_agent2.conf' ] && sed -i "s/^Server=127.0.0.1/Server=${ZABBIX_SERVER}/" /etc/zabbix/zabbix_agent2.conf

  [ -e '/etc/zabbix/zabbix_agentd.conf' ] && sed -i 's/^ServerActive=127.0.0.1/#ServerActive=127.0.0.1/' /etc/zabbix/zabbix_agentd.conf
  [ -e '/etc/zabbix/zabbix_agent2.conf' ] && sed -i 's/^ServerActive=127.0.0.1/#ServerActive=127.0.0.1/' /etc/zabbix/zabbix_agent2.conf
}

main() {
  init

  case "${OS_NAME}${OS_VERSION}" in
    debian12)
      ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"

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
    debian11)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian11_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+debian11_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+debian11_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/debian/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-2+debian11_all.deb"
          ;;
      esac
      ;;
    ubuntu24.04)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu24.04_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu24.04_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-6+ubuntu24.04_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-2+ubuntu24.04_all.deb"
          ;;
      esac
      ;;
    ubuntu22.04)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu22.04_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+ubuntu22.04_all.deb"
          ;;
        5.0)
          ZABBIX_PKGS="zabbix-agent"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-2+ubuntu22.04_all.deb"
          ;;
      esac
      ;;
    ubuntu20.04)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu20.04_all.deb"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+ubuntu20.04_all.deb"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-4+ubuntu20.04_all.deb"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${ZABBIX_VERSION}-1+focal_all.deb"
          ;;
      esac
      ;;
    almalinux9*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/alma/9/noarch/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-3.el9.noarch.rpm"
          ;;
      esac
      ;;
    almalinux8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/alma/8/noarch/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
    centos9)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/centos/9/noarch/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-3.el9.noarch.rpm"
          ;;
      esac
      ;;
    oracle9*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/oracle/9/noarch//zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-3.el9.noarch.rpm"
          ;;
      esac
      ;;
    oracle8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/oracle/8/noarch//zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
    rocky9*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/rocky/9/noarch//zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el9.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el9.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/9/x86_64/zabbix-release-${ZABBIX_VERSION}-3.el9.noarch.rpm"
          ;;
      esac
      ;;
    rocky8*)
      case "${ZABBIX_VERSION}" in
        7.2)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/release/rocky/8/noarch//zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.4)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
        6.0)
          ZABBIX_PKGS="${ZABBIX_PKGS} zabbix-agent2-plugin-*"
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-4.el8.noarch.rpm"
          ;;
        5.0)
          REPO_URL="${REPO_URL}/${ZABBIX_VERSION}/rhel/8/x86_64/zabbix-release-${ZABBIX_VERSION}-1.el8.noarch.rpm"
          ;;
      esac
      ;;
  esac

  [ -n "$(echo ${REPO_URL} | egrep '\.deb$|\.rpm$')" ]   && installZabbix
  [ -n "$(find /etc/zabbix/ -name 'zabbix_agent?.conf')" ] && configZabbix
  [ -e '/usr/bin/firewall-cmd' ]                         && firewall-cmd --permanent --zone=public --add-port=10050/tcp && firewall-cmd --reload

  if [ "$ZABBIX_VERSION" = "7.2" ]; then
    if grep -q '^Plugins.NVIDIA.System.Path=' /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf; then
      sed -i 's|^Plugins.NVIDIA.System.Path=.*|#&|' /etc/zabbix/zabbix_agent2.d/plugins.d/nvidia.conf
    fi
  fi

  if [ "$OS_VERSION" = "22.04" ] && [ "$ZABBIX_VERSION" = "5.0" ]; then
    systemctl restart zabbix-agent
    systemctl enable zabbix-agent
  else
    systemctl restart zabbix-agent2
    systemctl enable zabbix-agent2
  fi
}

main
