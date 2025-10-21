#!/bin/bash

# Этот скрипт настраивает сервер Ubuntu согласно указанным требованиям.
# Запускайте его от root (sudo -i) или с sudo.
# Внимание: Скрипт изменит SSH порт на 20022 — убедитесь, что вы подключены не по старому порту, или добавьте правило в UFW заранее.
# Для установки 3X-UI скрипт запустит официальный инсталлятор, который является интерактивным (спросит username, password, port).
# Рекомендуется установить порт панели на 8443, так как он разрешен в UFW.
# Самоподписанный SSL генерируется в /root/cert — это может быть использовано для 3X-UI (в панели настройте сертификаты).

# Цвета для вывода
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"

# Функция для вывода успеха
success() {
    echo -e "${GREEN}[УСПЕХ] $1${RESET}"
}

# Функция для вывода ошибки и выхода
error() {
    echo -e "${RED}[ОШИБКА] $1${RESET}"
    exit 1
}

# Функция для вывода предупреждения
warning() {
    echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ] $1${RESET}"
}

# Проверка на root
if [ "$EUID" -ne 0 ]; then
    error "Скрипт должен запускаться от root. Используйте sudo."
fi

# Интерактивный режим: спросить подтверждение перед запуском
read -p "Вы уверены, что хотите запустить настройку? Это изменит конфигурацию сервера (y/n): " confirm
if [[ ! $confirm =~ ^[Yy]$ ]]; then
    error "Настройка отменена."
fi

# 1. Обновление системы и всех компонентов
success "Шаг 1: Обновление системы..."
apt update -y && apt upgrade -y && apt dist-upgrade -y && apt autoremove -y || error "Не удалось обновить систему."

# 2. Смена стандартного SSH порта на 20022
success "Шаг 2: Смена SSH порта на 20022..."
if grep -q "^Port 20022" /etc/ssh/sshd_config; then
    warning "SSH порт уже 20022. Пропуск."
else
    sed -i 's/#Port 22/Port 20022/g' /etc/ssh/sshd_config || error "Не удалось изменить SSH конфиг."
    sed -i 's/Port 22/Port 20022/g' /etc/ssh/sshd_config || error "Не удалось изменить SSH конфиг."
fi
systemctl restart ssh || error "Не удалось перезапустить SSH."
warning "SSH теперь на порту 20022. Убедитесь, что ваш клиент обновлен!"

# 3. Настройка Firewall UFW с разрешенными портами: 8443/tcp, 20022/tcp, 1985/tcp
success "Шаг 3: Настройка UFW..."
apt install ufw -y || error "Не удалось установить UFW."
ufw allow 8443/tcp || error "Не удалось разрешить 8443/tcp."
ufw allow 20022/tcp || error "Не удалось разрешить 20022/tcp."
ufw allow 1985/tcp || error "Не удалось разрешить 1985/tcp."
ufw --force enable || error "Не удалось включить UFW."
ufw reload || error "Не удалось перезагрузить UFW."
ufw status || error "Не удалось проверить статус UFW."

# 4. Запрет пинга сервера
success "Шаг 4: Запрет пинга..."
if grep -q "net.ipv4.icmp_echo_ignore_all = 1" /etc/sysctl.conf; then
    warning "Пинг уже запрещен. Пропуск."
else
    echo "net.ipv4.icmp_echo_ignore_all = 1" >> /etc/sysctl.conf || error "Не удалось добавить правило в sysctl.conf."
fi
sysctl -p || error "Не удалось применить sysctl."
success "Пинг запрещен. Проверьте: ping localhost (должен игнорировать)."

# 5. Установка и настройка Fail2ban (с jail для SSH на новом порту)
success "Шаг 5: Установка и настройка Fail2ban..."
apt install fail2ban -y || error "Не удалось установить Fail2ban."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local || error "Не удалось скопировать jail.conf."
if ! grep -q "\[sshd\]" /etc/fail2ban/jail.local; then
    echo "[sshd]" >> /etc/fail2ban/jail.local
    echo "enabled = true" >> /etc/fail2ban/jail.local
    echo "port = 20022" >> /etc/fail2ban/jail.local
else
    sed -i '/\[sshd\]/,/^\[/ s/enabled = false/enabled = true/' /etc/fail2ban/jail.local
    sed -i '/\[sshd\]/,/^\[/ s/port     = ssh/port     = 20022/' /etc/fail2ban/jail.local
fi
systemctl enable fail2ban --now || error "Не удалось включить Fail2ban."
systemctl restart fail2ban || error "Не удалось перезапустить Fail2ban."
fail2ban-client status sshd || warning "Jail sshd не активен — проверьте конфиг."

# 6. Установка sqlite3
success "Шаг 6: Установка sqlite3..."
apt install sqlite3 -y || error "Не удалось установить sqlite3."
sqlite3 --version || error "Не удалось проверить версию sqlite3."

# 7. Синхронизация времени через NTP (используем chrony для полнофункционального NTP)
success "Шаг 7: Синхронизация времени через NTP (chrony)..."
apt install chrony -y || error "Не удалось установить chrony."
systemctl enable chronyd --now || error "Не удалось включить chronyd."
success "Время синхронизировано с NTP серверами."

# 8. Проверка состояния NTP
success "Шаг 8: Проверка состояния NTP..."
echo "Статус chrony:"
chronyc sources || error "Не удалось проверить chronyc sources."
chronyc tracking || error "Не удалось проверить chronyc tracking."

# 9. Установка панели 3X-UI (используем официальный скрипт — он интерактивный)
success "Шаг 9: Установка 3X-UI..."
warning "Запускается интерактивный инсталлятор 3X-UI. Укажите порт 8443 (разрешен в UFW), username и password."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || error "Не удалось установить 3X-UI."
warning "3X-UI установлен. Доступ: http://<your-ip>:8443 (или ваш порт). Логин/пароль указаны в выводе инсталлера."

# 10. Выпуск самоподписанного SSL сертификата (в /root/cert для использования в 3X-UI)
success "Шаг 10: Генерация самоподписанного SSL сертификата..."
mkdir -p /root/cert || error "Не удалось создать директорию /root/cert."
openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
    -keyout /root/cert/server.key -out /root/cert/server.crt \
    -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=example.com" || error "Не удалось сгенерировать SSL сертификат."
success "Сертификат сгенерирован в /root/cert. В 3X-UI настройте SSL в панели (Panel Settings > SSL)."

success "Все шаги завершены успешно! Проверьте логи и конфигурацию."
