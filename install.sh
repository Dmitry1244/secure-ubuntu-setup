#!/bin/bash
# Автоматическая настройка Ubuntu-сервера с 3X-UI и безопасностью
# Автор: Дмитрий & Copilot 🚀

# === Прелюдия ===
set -e
trap 'echo "⚠️ Ошибка на строке $LINENO. Прерываем..."' ERR

exec > >(tee -a /var/log/setup.log) 2>&1
echo "📜 Логирование включено: /var/log/setup.log"

if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт от root"
  exit 1
fi

# === 1. Обновление системы ===
echo "[1/13] Обновляем систему..."
apt update && apt upgrade -y
apt install -y curl wget sudo ufw fail2ban tzdata chrony sqlite3 openssl

# === 2. Проверка наличия openssl ===
echo "[2/13] Проверяем наличие openssl..."
if ! command -v openssl &>/dev/null; then
  echo "❌ OpenSSL не установлен. Прерываем."
  exit 1
fi

# === 3. Смена порта SSH на 20022 ===
echo "[3/13] Меняем порт SSH на 20022..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)
sed -i 's/^#Port 22/Port 20022/' /etc/ssh/sshd_config
sed -i 's/^Port 22/Port 20022/' /etc/ssh/sshd_config
systemctl restart ssh

# === 4. Настройка UFW ===
echo "[4/13] Настраиваем UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 20022/tcp   # SSH
ufw allow 8443/tcp    # HTTPS
ufw allow 1985/tcp    # панель 3X-UI
ufw --force enable

# === 5. Запрет пинга (ICMP) ===
echo "[5/13] Запрещаем ICMP (ping)..."
echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf
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
EOL

systemctl enable fail2ban
systemctl restart fail2ban

# === 7. Часовой пояс и NTP ===
echo "[7/13] Устанавливаем часовой пояс GMT+3 (Europe/Moscow)..."
timedatectl set-timezone Europe/Moscow
systemctl enable chrony
systemctl restart chrony
timedatectl set-ntp true

# === 8. Проверка времени ===
echo "[8/13] Проверяем синхронизацию времени..."
timedatectl status
chronyc tracking

# === 9. Установка 3X-UI ===
echo "[9/13] Устанавливаем 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)

# === 10. Проверка наличия x-ui CLI ===
echo "[10/13] Проверяем наличие команды x-ui..."
if ! command -v x-ui &>/dev/null; then
  echo "❌ Команда x-ui не найдена. Прерываем."
  exit 1
fi

# === 11. Настройка панели 3X-UI ===
echo "[11/13] Меняем порт панели и ограничиваем доступ на localhost..."
x-ui setting -webListenIP 127.0.0.1
x-ui setting -port 1985

# === 12. Генерация самоподписанного SSL-сертификата ===
echo "[12/13] Генерируем самоподписанный SSL-сертификат..."
mkdir -p /etc/x-ui/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/x-ui/ssl/selfsigned.key \
  -out /etc/x-ui/ssl/selfsigned.crt \
  -subj "/C=RU/ST=Moscow/L=Moscow/O=3X-UI/CN=localhost"

# === 13. Добавление SSL в конфигурацию панели ===
echo "[13/13] Добавляем SSL в конфигурацию 3X-UI..."
x-ui setting -ssl true
x-ui setting -certFile /etc/x-ui/ssl/selfsigned.crt
x-ui setting -keyFile /etc/x-ui/ssl/selfsigned.key
systemctl restart x-ui

# === Финал ===
echo "✅ Готово!"
echo "🔑 Подключение по SSH: ssh -p 20022 user@IP"
echo "🌐 Панель 3X-UI доступна только через localhost:1985 (используй SSH-туннель)"
echo "🔒 SSL включён: самоподписанный сертификат"
echo "🕒 Проверка времени:"
timedatectl
