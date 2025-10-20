#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOGFILE="/var/log/setup-3xui.log"
ROLLBACK_DIR="/var/log/setup-rollback-$(date +%s)"
SSH_PORT=20022
UFW_PORTS=(8443 20022 1985)

# Перенаправляем вывод в лог и создаём директорию для отката
exec > >(tee -a "$LOGFILE") 2>&1
mkdir -p "$ROLLBACK_DIR"

trap 'rollback' ERR

rollback() {
  echo "!!! Ошибка. Выполняется откат изменений..."
  cp "$ROLLBACK_DIR"/sshd_config    /etc/ssh/sshd_config    && systemctl reload sshd
  cp "$ROLLBACK_DIR"/ufw.conf        /etc/ufw/ufw.conf        && ufw reload
  cp "$ROLLBACK_DIR"/sysctl.conf     /etc/sysctl.conf         && sysctl -p
  cp "$ROLLBACK_DIR"/jail.local      /etc/fail2ban/jail.local && systemctl restart fail2ban
  cp "$ROLLBACK_DIR"/ntp.conf        /etc/ntp.conf            && systemctl restart ntp
  echo "Откат завершён."
  exit 1
}

backup_file() {
  local f="$1"
  [ -f "$f" ] && cp "$f" "$ROLLBACK_DIR"/
}

update_system() {
  apt-get update
  apt-get -y upgrade \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
}

configure_ssh() {
  backup_file /etc/ssh/sshd_config
  sed -i "/^#Port /d; s/^Port .*/Port $SSH_PORT/; t; \$aPort $SSH_PORT" /etc/ssh/sshd_config
  systemctl reload sshd
}

configure_ufw() {
  backup_file /etc/ufw/ufw.conf
  ufw default deny incoming
  ufw default allow outgoing
  for p in "${UFW_PORTS[@]}"; do ufw allow "$p"/tcp; done
  ufw --force enable
}

disable_ping() {
  backup_file /etc/sysctl.conf
  sysctl -w net.ipv4.icmp_echo_ignore_all=1
  sed -i "/icmp_echo_ignore_all/d" /etc/sysctl.conf
  echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
}

install_fail2ban() {
  backup_file /etc/fail2ban/jail.local
  apt-get install -y fail2ban
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = $SSH_PORT
EOF
  systemctl restart fail2ban
}

install_sqlite3() {
  apt-get install -y sqlite3
}

configure_ntp() {
  backup_file /etc/ntp.conf
  apt-get install -y ntp
  systemctl enable ntp
  systemctl restart ntp
}

check_ntp() {
  ntpq -p
}

generate_ssl() {
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout  /etc/ssl/private/3xui.key \
    -out     /etc/ssl/certs/3xui.crt \
    -subj    "/CN=$(hostname)"
}

install_3xui() {
  echo "Устанавливаем 3X-UI панель..."
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

main() {
  echo "=== Начало настройки: $(date) ==="
  update_system
  configure_ssh
  configure_ufw
  disable_ping
  install_fail2ban
  install_sqlite3
  configure_ntp
  check_ntp
  generate_ssl
  install_3xui
  echo "=== Настройка завершена: $(date) ==="
}

main "$@"
