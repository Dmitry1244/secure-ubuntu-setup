#!/bin/bash
set -e

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Глобальные переменные ===
DRY_RUN=false
SECURE_SSH=false
FORCE_SSH_HARDEN=false
LOGFILE='setup.log'
ROLLBACK_DIR='rollback'
TOTAL_STEPS=0
FAILED_STEPS=0
FAILED_LIST=()

mkdir -p "$ROLLBACK_DIR"

# === Проверка прав ===
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Скрипт должен быть запущен от root (sudo).${NC}"
  exit 1
fi

# === Парсим аргументы ===
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --secure-ssh) SECURE_SSH=true ;; 
    --force-ssh-hardening) SECURE_SSH=true; FORCE_SSH_HARDEN=true ;; 
  esac
done

# === Логирование ===
log_step() { TOTAL_STEPS=$((TOTAL_STEPS+1)); echo -e "\n${BLUE}[STEP]${NC} $1" | tee -a "$LOGFILE"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOGFILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOGFILE"; }

# === Выполнение команд ===
run_cmd() {
  if $DRY_RUN; then
    log_info "DRY-RUN: $1"
  else
    log_info "EXEC: $1"
    bash -c "$1" 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    if [ $status -ne 0 ]; then
      log_error "Команда завершилась с ошибкой: $1"
      FAILED_STEPS=$((FAILED_STEPS+1))
      FAILED_LIST+=("$1")
    fi
  fi
}

# === Backup ===
backup_file() {
  if [ -f "$1" ]; then
    local backup="$ROLLBACK_DIR/$(basename $1).$(date +%s).bak"
    cp "$1" "$backup"
    log_info "Backup $1 -> $backup"
  fi
}

# === Модули ===
update_system() {
  log_step "Обновление системы и компонентов"
  run_cmd "apt-get update -y"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade"
  run_cmd "apt-get -y autoremove"
  run_cmd "apt-get -y autoclean"
}

ufw_setup() {
  log_step "Настройка UFW (разрешенные порты: 8443, 20022, 1985, 80)"
  # Сбросим текущие ��равила (с бэкапом)
  run_cmd "ufw --force reset"
  run_cmd "ufw default deny incoming"
  run_cmd "ufw default allow outgoing"

  # Обязательные порты
  run_cmd "ufw allow 80/tcp"
  run_cmd "ufw allow 8443/tcp"
  run_cmd "ufw allow 1985/tcp"
  # SSH: разрешаем 20022 (rate-limit) и явный allow
  run_cmd "ufw limit 20022/tcp || true"
  run_cmd "ufw allow 20022/tcp"

  run_cmd "ufw logging on"
  run_cmd "ufw --force enable"
}

ssh_port() {
  log_step "Смена SSH порта на 20022 (без отключения паролей по умолчанию)"
  backup_file /etc/ssh/sshd_config

  # Заменим любую существующую директиву Port или добавим, если её нет
  if grep -q -E '^\s*#?\s*Port\b' /etc/ssh/sshd_config; then
    run_cmd "sed -ri \"s/^\s*#?\s*Port\b.*$/Port 20022/\" /etc/ssh/sshd_config"
  else
    run_cmd "echo 'Port 20022' >> /etc/ssh/sshd_config"
  fi

  # Тест конфигурации и мягкая перезагрузка
  run_cmd "sshd -t || true"
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    run_cmd "systemctl reload ssh || systemctl restart ssh || true"
  else
    run_cmd "systemctl reload sshd || systemctl restart sshd || true"
  fi
}

ssh_hardening() {
  # Опциональная жёсткая настройка SSH: отключение root, отключение паролей и т.п.
  if ! $SECURE_SSH; then
    log_info "SSH hardening пропущен (не задан флаг --secure-ssh)"
    return 0
  fi

  log_step "Жёсткая настройка SSH (PermitRootLogin no, PasswordAuthentication no и т.д.)"

  # Определим пользователя, в чьём домашнем каталоге проверять authorized_keys
  TARGET_USER="root"
  if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  fi

  AUTH_KEYS_FILE="/root/.ssh/authorized_keys"
  if [ "$TARGET_USER" != "root" ]; then
    AUTH_KEYS_FILE="/home/${TARGET_USER}/.ssh/authorized_keys"
  fi

  if [ ! -f "$AUTH_KEYS_FILE" ] && ! $FORCE_SSH_HARDEN; then
    log_error "Не найден $AUTH_KEYS_FILE — отключение паролей НЕ будет выполнено, чтобы не потерять доступ."
    log_info "Если вы уверены, используйте --force-ssh-hardening для принудительного применения."
  else
    backup_file /etc/ssh/sshd_config
    # Устанавливаем безопасные директивы
    run_cmd "sed -ri \"s/^\s*#?\s*PermitRootLogin\b.*$/PermitRootLogin no/\" /etc/ssh/sshd_config || echo 'PermitRootLogin no' >> /etc/ssh/sshd_config"
    run_cmd "sed -ri \"s/^\s*#?\s*PasswordAuthentication\b.*$/PasswordAuthentication no/\" /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config"
    run_cmd "sed -ri \"s/^\s*#?\s*PubkeyAuthentication\b.*$/PubkeyAuthentication yes/\" /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config"
    run_cmd "sed -ri \"s/^\s*#?\s*ChallengeResponseAuthentication\b.*$/ChallengeResponseAuthentication no/\" /etc/ssh/sshd_config || echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config"
    run_cmd "sed -ri \"s/^\s*#?\s*PermitEmptyPasswords\b.*$/PermitEmptyPasswords no/\" /etc/ssh/sshd_config || echo 'PermitEmptyPasswords no' >> /etc/ssh/sshd_config"

    # Дополнительно: ограничим KeepAlive/ClientAlive для разрыва неактивных сессий
    run_cmd "grep -q '^ClientAliveInterval' /etc/ssh/sshd_config || echo 'ClientAliveInterval 300' >> /etc/ssh/sshd_config"
    run_cmd "grep -q '^ClientAliveCountMax' /etc/ssh/sshd_config || echo 'ClientAliveCountMax 2' >> /etc/ssh/sshd_config"

    # Тест и мягкая перезагрузка
    run_cmd "sshd -t || true"
    if systemctl list-unit-files | grep -q '^ssh\.service'; then
      run_cmd "systemctl reload ssh || systemctl restart ssh || true"
    else
      run_cmd "systemctl reload sshd || systemctl restart sshd || true"
    fi
    log_info "SSH жёсткая настройка применена. Убедитесь, что у вас есть доступ по ключу."
  fi
}

disable_ping() {
  log_step "Запрет ICMP ping (через sysctl.d)"
  backup_file /etc/sysctl.d/99-no-icmp.conf
  cat <<EOF > /etc/sysctl.d/99-no-icmp.conf
# Отключаем ответы на ICMP echo (ping)
net.ipv4.icmp_echo_ignore_all = 1
EOF
  run_cmd "sysctl --system"
}

sysctl_hardening() {
  log_step "Применение системных hardening настроек (sysctl)"
  backup_file /etc/sysctl.d/99-hardening.conf
  cat <<EOF > /etc/sysctl.d/99-hardening.conf
# Network hardening
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
# Protect against time-wait assassination
net.ipv4.tcp_rfc1337 = 1
# Reduce timeout for FIN-WAIT-2 sockets
net.ipv4.tcp_fin_timeout = 30
EOF
  run_cmd "sysctl --system"
}

fail2ban_setup() {
  log_step "Установка и настройка Fail2ban для защиты портов (SSH и общая защита)"
  run_cmd "apt-get install -y fail2ban"
  backup_file /etc/fail2ban/jail.local

  cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
banaction = ufw
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
# Поддерживаем стандартный ssh и кастомный 20022
port    = ssh,20022
logpath = /var/log/auth.log
maxretry = 5

[ssh-ddos]
enabled = true

[recidive]
enabled = true
logpath  = /var/log/fail2ban.log
action = ufw
bantime  = 86400
findtime = 86400
maxretry = 5
EOF

  run_cmd "systemctl enable fail2ban"
  run_cmd "systemctl restart fail2ban"
  run_cmd "ufw reload || true"
}

apparmor_setup() {
  log_step "Установка и включение AppArmor"
  run_cmd "apt-get install -y apparmor apparmor-utils || true"
  run_cmd "systemctl enable apparmor || true"
  run_cmd "systemctl start apparmor || true"
  run_cmd "aa-status || true"
}

sqlite_install() {
  log_step "Установка sqlite3"
  run_cmd "apt-get install -y sqlite3"
}

ntp_setup() {
  log_step "Установка и настройка NTP/Timesync"
  run_cmd "apt-get install -y ntp || true"

  if systemctl list-unit-files | grep -q '^ntp\.service'; then
    run_cmd "systemctl restart ntp"
  elif systemctl list-unit-files | grep -q '^systemd-timesyncd\.service'; then
    run_cmd "systemctl enable systemd-timesyncd.service"
    run_cmd "systemctl start systemd-timesyncd.service"
  elif systemctl list-unit-files | grep -q '^chrony\.service'; then
    run_cmd "systemctl enable chrony.service"
    run_cmd "systemctl start chrony.service"
  else
    log_error "Не найден ни ntp, ни systemd-timesyncd, ни chrony"
  fi
}

ntp_status() {
  log_step "Проверка состояния NTP"
  run_cmd "ntpq -p || timedatectl show-timesync --all || chronyc tracking || true"
}

ssl_selfsigned() {
  log_step "Выпуск самоподписанного SSL сертификата"
  mkdir -p /etc/ssl/selfsigned
  run_cmd "openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/selfsigned/server.key \
    -out /etc/ssl/selfsigned/server.crt \
    -subj '/CN=$(hostname)'"
}

auto_updates() {
  log_step "Включение автоматических обновлений безопасности"
  run_cmd "apt-get install -y unattended-upgrades"
  run_cmd "dpkg-reconfigure -f noninteractive unattended-upgrades || true"
}

monitoring_tools() {
  log_step "Установка инструментов мониторинга"
  run_cmd "apt-get install -y htop iotop iftop || true"
}

enable_bbr() {
  log_step "Включение TCP BBR"
  backup_file /etc/sysctl.d/99-bbr.conf
  cat <<EOF > /etc/sysctl.d/99-bbr.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  run_cmd "sysctl --system || true"
  run_cmd "sysctl net.ipv4.tcp_congestion_control || true"
  run_cmd "lsmod | grep bbr || true"
}

install_3xui() {
  log_step "Установка панели 3X-UI (опционально). Запускается с таймаутом 300s — если требуется ввод, установку можно завершить вручную позже."
  # Запускаем инсталлятор с таймаутом, чтобы он не блокировал вывод итоговой сводки
  # Если инсталлятор требует интерактивный ввод, он может не завершиться — после таймаута скрипт продолжит работу.
  run_cmd "timeout 300 bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) || true"
  log_info "Если 3X-UI не установилась полностью (интерактивный ввод), запустите установку вручную после проверки: \n  bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"
}

# === Итоговая сводка ===
summary() {
  echo -e "\n${YELLOW}========== ИТОГОВАЯ СВОДКА ==========${NC}"
  echo -e "Всего шагов: $TOTAL_STEPS"
  if [ $FAILED_STEPS -eq 0 ]; then
    echo -e "${GREEN}Все шаги выполнены успешно ✅${NC}"
  else
    echo -e "${RED}Ошибок: $FAILED_STEPS ❌${NC}"
    echo "Проблемные команды:"
    for cmd in "${FAILED_LIST[@]}"; do
      echo -e "  - $cmd"
    done
    echo -e "Подробности см. в ${YELLOW}setup.log${NC}"
  fi
  echo -e "${YELLOW}=====================================${NC}\n"
}

# === Main ===
if $DRY_RUN; then
  log_info "Запуск в режиме dry-run"
fi

update_system
ufw_setup
ssh_port
# Если нужен жёсткий SSH — вызов опциональной функции
ssh_hardening
disable_ping
sysctl_hardening
fail2ban_setup
apparmor_setup
sqlite_install
ntp_setup
ntp_status
ssl_selfsigned
auto_updates
monitoring_tools
enable_bbr
# 3X-UI запускаем ПОСЛЕДНИМ, чтобы предыдущие правки (порт SSH/UFW и т.д.) были применены
install_3xui

summary
