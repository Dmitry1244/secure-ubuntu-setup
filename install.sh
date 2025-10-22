#!/bin/bash
set -e

# === Цвета ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# === Глобальные переменные ===
DRY_RUN=false
LOGFILE="setup.log"
ROLLBACK_DIR="rollback"
TOTAL_STEPS=0
FAILED_STEPS=0
FAILED_LIST=()

mkdir -p "$ROLLBACK_DIR"

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
update_system() { log_step "Обновление системы"; run_cmd "apt-get update -y"; run_cmd "apt-get upgrade -y"; }
ufw_setup() { log_step "Настройка UFW"; run_cmd "ufw allow 8443/tcp"; run_cmd "ufw allow 20022/tcp"; run_cmd "ufw allow 1985/tcp"; run_cmd "ufw --force enable"; }

ssh_port() {
  log_step "Смена SSH порта на 20022"
  backup_file /etc/ssh/sshd_config
  run_cmd "sed -i 's/^#Port 22/Port 20022/' /etc/ssh/sshd_config"
  systemctl list-unit-files | grep -q '^ssh\.service' && run_cmd "systemctl restart ssh" || run_cmd "systemctl restart sshd"
}

ssh_keys_generate() {
  log_step "Генерация SSH-ключа (парольный вход пока включён)"
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [ ! -f /root/.ssh/id_rsa ]; then
    run_cmd "ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ''"
  fi
  run_cmd "cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys"
  run_cmd "chmod 600 /root/.ssh/authorized_keys"
  log_info "SSH-ключ сгенерирован. Скачайте /root/.ssh/id_rsa через MobaXterm перед отключением пароля!"
}

ssh_disable_password() {
  log_step "Отключение входа по паролю (только по ключу)"
  backup_file /etc/ssh/sshd_config
  run_cmd "sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
  run_cmd "sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
  run_cmd "sed -i 's/^#PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config"
  systemctl list-unit-files | grep -q '^ssh\.service' && run_cmd "systemctl restart ssh" || run_cmd "systemctl restart sshd"
}

disable_ping() { log_step "Запрет ICMP ping"; run_cmd "echo 'net.ipv4.icmp_echo_ignore_all=1' >> /etc/sysctl.conf"; run_cmd "sysctl -p"; }
fail2ban_setup() { log_step "Установка Fail2ban"; run_cmd "apt-get install -y fail2ban"; backup_file /etc/fail2ban/jail.local"; echo -e "[sshd]\nenabled=true\nport=20022\nlogpath=/var/log/auth.log\nmaxretry=5" > /etc/fail2ban/jail.local; run_cmd "systemctl enable fail2ban"; run_cmd "systemctl restart fail2ban"; }
sqlite_install() { log_step "Установка sqlite3"; run_cmd "apt-get install -y sqlite3"; }
ntp_setup() { log_step "Установка и настройка NTP/Timesync"; run_cmd "apt-get install -y ntp || true"; systemctl list-unit-files | grep -q '^ntp\.service' && run_cmd "systemctl restart ntp" || (systemctl list-unit-files | grep -q '^systemd-timesyncd\.service' && run_cmd "systemctl enable systemd-timesyncd.service" && run_cmd "systemctl start systemd-timesyncd.service") || (systemctl list-unit-files | grep -q '^chrony\.service' && run_cmd "systemctl enable chrony.service" && run_cmd "systemctl start chrony.service") || log_error "Не найден ни ntp, ни systemd-timesyncd, ни chrony"; }
ntp_status() { log_step "Проверка состояния NTP"; run_cmd "ntpq -p || timedatectl show-timesync --all || chronyc tracking"; }
ssl_selfsigned() { log_step "Выпуск самоподписанного SSL"; mkdir -p /etc/ssl/selfsigned; run_cmd "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/selfsigned/server.key -out /etc/ssl/selfsigned/server.crt -subj '/CN=$(hostname)'"; }
auto_updates() { log_step "Автообновления безопасности"; run_cmd "apt-get install -y unattended-upgrades"; run_cmd "dpkg-reconfigure -f noninteractive unattended-upgrades"; }
monitoring_tools() { log_step "Установка инструментов мониторинга"; run_cmd "apt-get install -y htop iotop iftop"; }
enable_bbr() { log_step "Включение TCP BBR"; run_cmd "echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf"; run_cmd "echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf"; run_cmd "sysctl -p"; run_cmd "sysctl net.ipv4.tcp_congestion_control"; run_cmd "lsmod | grep bbr || true"; }
install_3xui() { log_step "Установка панели 3X-UI"; run_cmd "bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)"; }

# === Итоговая сводка ===
summary() {
  echo -e "\n${YELLOW}========== ИТОГОВАЯ СВОДКА ==========${NC}"
  echo -e "Всего шагов: $TOTAL_STEPS"
  if [ $FAILED_STEPS -eq 0 ]; then
    echo -e "${GREEN}Все шаги выполнены успешно ✅${NC}"
  else
    echo -e "${RED}Ошибок: $FAILED_STEPS ❌${NC}"
    for cmd in "${FAILED_LIST[@]}"; do echo "  - $cmd"; done
    echo -e "Подробности см. в ${YELLOW}setup.log${NC}"
  fi
  echo -e "${YELLOW}=====================================${NC}\n"
}

# === Main ===
if [[ "$1" == "--dry-run" ]]; then DRY_RUN=true; log_info "Запуск в режиме dry-run"; fi

update_system
ufw_setup
ssh_port
ssh_keys_generate     # 🔑 Генерация ключа (пароль пока работает)
disable_ping
fail2ban_setup
sqlite_install
ntp_setup
ntp_status
ssl_selfsigned
auto_updates
monitoring_tools
enable_bbr
install_3xui
# ssh_disable_password # 🔒 Включите вручную после скачивания ключа!

summary
