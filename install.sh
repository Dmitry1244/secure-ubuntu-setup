#!/bin/bash
# Усиленная автоматическая настройка Ubuntu-сервера с 3X-UI и безопасностью
# Автор: Дмитрий & Copilot 🚀

set -euo pipefail
trap 'echo "⚠️ Ошибка на строке $LINENO. Прерываем..." >&2; exit 1' ERR

LOG_FILE="/var/log/setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "📜 Логирование включено: $LOG_FILE"

if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт от root"
  exit 1
fi

# === Вспомогательные функции ===
ensure_line() {
  local line="$1" file="$2"
  grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

# === 1. Обновление системы ===
echo "[1/13] Обновляем систему..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt -y upgrade
apt install -y curl wget sudo ufw fail2ban tzdata chrony sqlite3 openssl netcat-openbsd jq

# === 2. Проверка наличия openssl ===
command -v openssl >/dev/null || { echo "❌ OpenSSL не установлен"; exit 1; }

# === 3. Смена порта SSH на 20022 ===
echo "[3/13] Меняем порт SSH..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

if grep -qE '^[#\s]*Port\s+22' /etc/ssh/sshd_config; then
  sed -i 's/^[#\s]*Port\s\+22/Port 20022/' /etc/ssh/sshd_config
elif grep -qE '^Port\s+[0-9]+' /etc/ssh/sshd_config; then
  sed -i 's/^Port\s\+[0-9]\+/Port 20022/' /etc/ssh/sshd_config
else
  echo 'Port 20022' >> /etc/ssh/sshd_config
fi

systemctl restart ssh

# === 4. Настройка UFW ===
echo "[4/13] Настраиваем UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp
ufw allow 8443/tcp
# ⚠️ Порт 1985 НЕ открываем наружу

ufw --force enable
ufw reload

# === 5. Запрет ICMP ===
echo "[5/13] Запрещаем ICMP..."
ensure_line "net.ipv4.icmp_echo_ignore_all=1" /etc/sysctl.conf
sysctl -p

# === 6. Настройка Fail2ban ===
echo "[6/13] Настраиваем Fail2ban..."
cat >/etc/fail2ban/jail.local <<EOL
[sshd]
enabled = true
port    = 20022
logpath = %(sshd_log)s
maxretry = 5
bantime = 3600
ignoreip = 127.0.0.1
EOL
systemctl enable fail2ban
systemctl restart fail2ban

# === 7. Часовой пояс и NTP ===
echo "[7/13] Устанавливаем часовой пояс Europe/Moscow..."
timedatectl set-timezone Europe/Moscow
systemctl enable chrony
systemctl restart chrony
timedatectl set-ntp true

# === 8. Проверка времени ===
echo "[8/13] Проверяем синхронизацию времени..."
timedatectl status
chronyc tracking || true

# === 9. Установка 3X-UI ===
echo "[9/13] Устанавливаем 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# === 10. Проверка наличия x-ui CLI ===
command -v x-ui >/dev/null || { echo "❌ Команда x-ui не найдена"; exit 1; }

# === 11. Генерация SSL ===
echo "[11/13] Генерируем самоподписанный SSL..."
mkdir -p /etc/x-ui/ssl
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout /etc/x-ui/ssl/selfsigned.key \
  -out /etc/x-ui/ssl/selfsigned.crt \
  -subj "/C=RU/ST=Moscow/L=Moscow/O=3X-UI/CN=localhost"

# === 12. Прямая правка config.json через jq ===
CONFIG_FILE="/usr/local/x-ui/bin/config.json"
if [ -f "$CONFIG_FILE" ]; then
  echo "[12/13] Настраиваем config.json..."
  jq '.webListenIP="127.0.0.1" 
      | .port=1985 
      | .ssl=true 
      | .certFile="/etc/x-ui/ssl/selfsigned.crt" 
      | .keyFile="/etc/x-ui/ssl/selfsigned.key"' \
      "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
else
  echo "⚠️ config.json не найден, проверь путь вручную"
fi

# === 13. Перезапуск панели ===
echo "[13/13] Перезапускаем x-ui..."
systemctl restart x-ui

# Проверка
if ss -tulpn | grep -q '127.0.0.1:1985'; then
  echo "✅ Панель слушает на localhost:1985"
else
  echo "⚠️ Панель не слушает на 1985, проверь config.json"
fi

# === Финал ===
echo "✅ Готово!"
echo "🔑 Подключение по SSH: ssh -p 20022 user@IP"
echo "🌐 Панель 3X-UI доступна только через localhost:1985 (используй SSH-туннель)"
