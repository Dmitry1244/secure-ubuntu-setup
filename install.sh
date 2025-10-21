#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/server_setup.log"
DRY_RUN=false

# === Аргументы ===
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "🔍 DRY-RUN режим: изменения НЕ будут применены"
fi

# === Логирование ===
log() {
  local level="$1"; shift
  echo "[$level] $*" | tee -a "$LOGFILE"
}

run() {
  if $DRY_RUN; then
    log "INFO" "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

# === Модуль 1: Обновление системы ===
update_system() {
  log "INFO" "[1] Обновление системы..."
  run "export DEBIAN_FRONTEND=noninteractive"
  run "apt-get update -y"
  run "apt-get upgrade -y"
  run "apt-get dist-upgrade -y"
}

# === Модуль 2: Настройка SSH-порта с rollback ===
configure_ssh_port() {
  local sshd_config="/etc/ssh/sshd_config"
  local rollback_needed=false

  log "INFO" "[2] Настройка SSH на порты 22 и 20022..."
  run "ufw allow 22/tcp"
  run "ufw allow 20022/tcp"

  grep -q 'Port 20022' "$sshd_config" || run "echo 'Port 20022' >> $sshd_config"
  grep -q 'Port 22' "$sshd_config" || run "echo 'Port 22' >> $sshd_config"

  restart_ssh

  sleep 2
  if ! ss -tln | grep -q ':20022'; then
    log "ERROR" "Порт 20022 не слушается — откат..."
    run "sed -i '/Port 20022/d' $sshd_config"
    run "ufw delete allow 20022/tcp"
    restart_ssh
    rollback_needed=true
  fi

  if ! nc -z localhost 20022; then
    log "ERROR" "Не удалось подключиться к порту 20022 — откат..."
    run "sed -i '/Port 20022/d' $sshd_config"
    run "ufw delete allow 20022/tcp"
    restart_ssh
    rollback_needed=true
  fi

  if $rollback_needed; then
    log "WARN" "Откат выполнен. SSH остался на порту 22."
  else
    log "INFO" "✅ SSH успешно настроен на порты 22 и 20022."
  fi
}

restart_ssh() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    run "systemctl reload ssh || systemctl restart ssh"
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    run "systemctl reload sshd || systemctl restart sshd"
  elif systemctl list-unit-files | grep -q '^ssh\.socket'; then
    run "systemctl restart ssh.socket"
  else
    log "ERROR" "Не удалось найти SSH юнит для перезапуска."
  fi
}

# === Модуль 3: Настройка UFW ===
configure_firewall() {
  log "INFO" "[3] Настройка UFW..."
  run "ufw allow 8443/tcp"
  run "ufw allow 1985/tcp"
  run "ufw --force enable"
}

# === Модуль 4: Запрет ICMP (ping) ===
disable_ping() {
  log "INFO" "[4] Запрет ICMP (ping)..."
  grep -q "net.ipv4.icmp_echo_ignore_all" /etc/sysctl.conf || run "echo 'net.ipv4.icmp_echo_ignore_all=1' >> /etc/sysctl.conf"
  run "sysctl -w net.ipv4.icmp_echo_ignore_all=1"
}

# === Модуль 5: Установка Fail2ban ===
install_fail2ban() {
  log "INFO" "[5] Установка Fail2ban..."
  run "apt-get install -y fail2ban"
  run "systemctl enable --now fail2ban"
}

# === Модуль 6: Установка sqlite3 ===
install_sqlite() {
  log "INFO" "[6] Установка sqlite3..."
  run "apt-get install -y sqlite3"
}

# === Модуль 7: Установка и запуск chrony ===
setup_ntp() {
  log "INFO" "[7] Установка chrony..."
  run "apt-get install -y chrony"
  run "systemctl enable --now chrony"
}

# === Модуль 8: Проверка NTP ===
verify_ntp() {
  log "INFO" "[8] Проверка NTP..."
  run "chronyc tracking || true"
}

# === Модуль 9: Генерация SSL сертификата ===
generate_ssl_cert() {
  local dir="/etc/ssl/selfsigned"
  local crt="$dir/server.crt"
  local key="$dir/server.key"

  log "INFO" "[9] Генерация SSL сертификата..."
  run "mkdir -p $dir"

  if [ ! -f "$crt" ]; then
    run "openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout $key -out $crt \
      -subj '/C=RU/ST=MSK/L=Moscow/O=MyOrg/OU=IT/CN=$(hostname)'"
    log "INFO" "✅ Сертификат создан."
  else
    log "INFO" "🔄 Сертификат уже существует, пропускаем."
  fi

  local end_date
  end_date=$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)
  log "INFO" "Пути сертификатов:"
  log "INFO" "  Сертификат: $crt"
  log "INFO" "  Ключ:       $key"
  log "INFO" "  Действителен до: $end_date"
}

# === Модуль 10: Установка панели 3X-UI ===
install_3xui() {
  log "INFO" "[10] Установка панели 3X-UI..."
  if [ ! -d "/usr/local/x-ui" ]; then
    run "bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
  else
    log "INFO" "🔄 3X-UI уже установлена, пропускаем."
  fi
}

# === Главная функция ===
main() {
  log "INFO" "=== Начало настройки: $(date) ==="
  update_system
  configure_ssh_port
  configure_firewall
  disable_ping
  install_fail2ban
  install_sqlite
  setup_ntp
  verify_ntp
  generate_ssl_cert
  install_3xui
  log "INFO" "=== Настройка завершена: $(date) ==="
}

main
