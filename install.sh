#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/server_setup.log"
DRY_RUN=false
TEST_MODE=false
AUTO_SSH=false

case "${1:-}" in
  --dry-run) DRY_RUN=true ;;
  --test) TEST_MODE=true ;;
  --auto-ssh) AUTO_SSH=true ;;
esac

log() { echo "[$1] $2" | tee -a "$LOGFILE"; }
run() { $DRY_RUN && log "INFO" "DRY-RUN: $*" || eval "$@"; }

restart_ssh() {
  systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || \
  systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || \
  systemctl restart ssh.socket 2>/dev/null || log ERROR "Не удалось перезапустить SSH"
}

step_update_system() {
  log INFO "[1] Обновление системы..."
  run "export DEBIAN_FRONTEND=noninteractive"
  run "apt-get update -y && apt-get upgrade -y && apt-get dist-upgrade -y"
}

step_firewall() {
  log INFO "[2] Настройка UFW..."
  run "ufw allow 22/tcp"
  run "ufw allow 20022/tcp"
  run "ufw allow 8443/tcp"
  run "ufw allow 1985/tcp"
  run "ufw --force enable"
  if $TEST_MODE || ! ufw status | grep -q '20022'; then
    log ERROR "❌ UFW не применил правило — откат..."
    run "ufw delete allow 20022/tcp || true"
  else
    log INFO "✅ UFW настроен. Порт 20022 открыт."
  fi
}

step_configure_ssh() {
  log INFO "[3] Смена порта SSH..."
  local cfg="/etc/ssh/sshd_config"
  local port=20022

  if ! $AUTO_SSH; then
    read -p "❓ Перейти к смене порта SSH на $port? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log INFO "Пропущено по запросу пользователя."; return; }
  else
    log INFO "Автоматически применяем смену порта SSH на $port..."
  fi

  if ss -tln | grep -q ":$port"; then
    log ERROR "Порт $port уже занят другим процессом. Откат невозможен."
    return
  fi

  if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    log WARN "SSH-ключи отсутствуют. Генерируем..."
    run "ssh-keygen -A"
  fi

  if ! sshd -t; then
    log ERROR "Конфигурация SSH содержит ошибки. Откат невозможен."
    return
  fi

  grep -q "Port $port" "$cfg" || run "echo 'Port $port' >> $cfg"
  grep -q "Port 22" "$cfg" || run "echo 'Port 22' >> $cfg"
  run "sshd -T | grep port"

  restart_ssh
  sleep 2

  if $TEST_MODE || ! ss -tln | grep -q ":$port" || ! nc -z localhost $port; then
    log ERROR "❌ Порт $port недоступен — откат..."
    run "sed -i '/Port $port/d' $cfg"
    run "ufw delete allow $port/tcp || true"
    restart_ssh
    log WARN "Откат SSH выполнен. Остался порт 22."
  else
    log INFO "✅ SSH слушает на портах 22 и $port."
  fi
}

step_disable_ping() {
  log INFO "[4] Запрет ICMP..."
  grep -q "icmp_echo_ignore_all" /etc/sysctl.conf || run "echo 'net.ipv4.icmp_echo_ignore_all=1' >> /etc/sysctl.conf"
  run "sysctl -w net.ipv4.icmp_echo_ignore_all=1"
  if $TEST_MODE || [[ "$(sysctl -n net.ipv4.icmp_echo_ignore_all)" != "1" ]]; then
    log ERROR "❌ ICMP не отключён — откат..."
    run "sysctl -w net.ipv4.icmp_echo_ignore_all=0"
  else
    log INFO "✅ ICMP отключён."
  fi
}

step_fail2ban() {
  log INFO "[5] Установка Fail2ban..."
  run "apt-get install -y fail2ban"
  run "systemctl enable --now fail2ban"
  if $TEST_MODE || ! systemctl is-active --quiet fail2ban; then
    log ERROR "❌ Fail2ban не активен — откат..."
    run "systemctl stop fail2ban"
    run "apt-get remove -y fail2ban"
  else
    log INFO "✅ Fail2ban работает."
  fi
}

step_sqlite() {
  log INFO "[6] Установка sqlite3..."
  run "apt-get install -y sqlite3"
  if $TEST_MODE || ! command -v sqlite3 >/dev/null; then
    log ERROR "❌ sqlite3 не найден — откат..."
    run "apt-get remove -y sqlite3"
  else
    log INFO "✅ sqlite3 установлен."
  fi
}

step_ntp() {
  log INFO "[7] Установка chrony..."
  run "apt-get install -y chrony"
  run "systemctl enable --now chrony"
  if $TEST_MODE || ! chronyc tracking | grep -q 'Leap status'; then
    log ERROR "❌ NTP не синхронизирован — откат..."
    run "systemctl stop chrony"
    run "apt-get remove -y chrony"
  else
    log INFO "✅ NTP синхронизирован."
  fi
}

step_ssl() {
  log INFO "[8] Генерация SSL..."
  local dir="/etc/ssl/selfsigned"
  run "mkdir -p $dir"
  run "openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout $dir/server.key -out $dir/server.crt \
    -subj '/C=RU/ST=MSK/L=Moscow/O=MyOrg/OU=IT/CN=$(hostname)'"
  if $TEST_MODE || ! openssl x509 -checkend 86400 -in "$dir/server.crt" >/dev/null; then
    log ERROR "❌ Сертификат недействителен — откат..."
    run "rm -f $dir/server.crt $dir/server.key"
  else
    log INFO "✅ Сертификат создан."
    run "openssl x509 -in $dir/server.crt -noout -enddate"
  fi
}

step_3xui() {
  log INFO "[9] Установка 3X-UI..."
  run "bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
  if $TEST_MODE || [ ! -d "/usr/local/x-ui" ]; then
    log ERROR "❌ 3X-UI не установлена — откат..."
    run "rm -rf /usr/local/x-ui"
  else
    log INFO "✅ 3X-UI установлена."
  fi
}

main() {
  log INFO "=== Начало настройки: $(date) ==="
  step_update_system
  step_firewall
  step_configure_ssh
  step_disable_ping
  step_fail2ban
  step_sqlite
  step_ntp
  step_ssl
  step_3xui
  log INFO "=== Завершено: $(date) ==="
}

main
