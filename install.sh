#!/usr/bin/env bash
set -euo pipefail

LOGFILE="/var/log/server_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "=== Начало настройки сервера: $(date) ==="

# 1. Обновление системы
echo "[1] Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y && apt-get dist-upgrade -y

# 3. Настройка UFW (вынесено раньше перезапуска SSH для безопасности)
echo "[3] Настройка UFW..."
ufw allow 8443/tcp || true
ufw allow 20022/tcp || true
ufw allow 1985/tcp || true
ufw --force enable

# 2. Смена SSH порта на 20022 и корректный перезапуск
echo "[2] Настройка SSH на порт 20022..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# Идемпотентно обновляем Port
if grep -qE '^\s*Port\s+[0-9]+' "$SSHD_CONFIG"; then
    sed -i 's/^\s*Port\s\+[0-9]\+/Port 20022/' "$SSHD_CONFIG"
else
    echo "Port 20022" >> "$SSHD_CONFIG"
fi

restart_ssh() {
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh || systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd || systemctl restart sshd
  else
    if systemctl list-unit-files | grep -q '^ssh\.socket'; then
      systemctl restart ssh.socket
    else
      echo "Не удалось найти SSH юнит для перезапуска. Проверьте systemctl status ssh."
      return 1
    fi
  fi
}
restart_ssh

# 4. Запрет пинга
echo "[4] Запрет ICMP (ping)..."
if ! grep -q "net.ipv4.icmp_echo_ignore_all" /etc/sysctl.conf; then
    echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
    sysctl -p
else
    sysctl -w net.ipv4.icmp_echo_ignore_all=1
fi

# 5. Установка и настройка Fail2ban
echo "[5] Установка Fail2ban..."
apt-get install -y fail2ban
systemctl enable --now fail2ban

# 6. Установка sqlite3
echo "[6] Установка sqlite3..."
apt-get install -y sqlite3

# 7. Синхронизация времени через NTP (chrony)
echo "[7] Установка chrony для NTP..."
apt-get install -y chrony
systemctl enable --now chrony

# 8. Проверка состояния NTP
echo "[8] Проверка NTP..."
chronyc tracking || true

# 9. Самоподписанный SSL сертификат (10 лет) + вывод путей и срока
echo "[9] Генерация самоподписанного SSL..."
SSL_DIR="/etc/ssl/selfsigned"
mkdir -p "$SSL_DIR"
CRT_FILE="$SSL_DIR/server.crt"
KEY_FILE="$SSL_DIR/server.key"

if [ ! -f "$CRT_FILE" ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CRT_FILE" \
        -subj "/C=RU/ST=MSK/L=Moscow/O=MyOrg/OU=IT/CN=$(hostname)"
    echo "SSL сертификат создан (срок действия: 10 лет)."
else
    echo "SSL сертификат уже существует, пропускаем генерацию."
fi

echo "Пути сертификатов:"
echo "  Сертификат: $CRT_FILE"
echo "  Ключ:       $KEY_FILE"
if [ -f "$CRT_FILE" ]; then
    END_DATE=$(openssl x509 -in "$CRT_FILE" -noout -enddate | cut -d= -f2)
    echo "  Действителен до: $END_DATE"
fi

# 10. Установка панели 3X-UI
echo "[10] Установка 3X-UI..."
if [ ! -d "/usr/local/x-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
fi

echo "=== Настройка завершена: $(date) ==="
