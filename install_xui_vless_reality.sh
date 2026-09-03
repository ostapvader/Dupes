#!/bin/bash
set -e

echo "=== Установка x-ui v2.3.12 с Xray 1.8.23 и VLESS Reality ==="

if [ "$EUID" -ne 0 ]; then 
    echo "Пожалуйста, запустите скрипт от имени root"
    exit 1
fi

RANDOM_PORT=$((RANDOM % 55001 + 10000))
RANDOM_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)

echo "Случайный порт панели: $RANDOM_PORT"
echo "Случайный пароль: $RANDOM_PASSWORD"

echo "[1/7] Обновление системы и установка зависимостей..."
apt-get update -qq
apt-get install -y curl wget sqlite3 ufw unzip

echo "[2/7] Установка x-ui v2.3.12..."
bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) v2.3.12

echo "[3/7] Настройка панели (порт, логин/пароль)..."
x-ui stop
x-ui setting -port $RANDOM_PORT -username admin -password "$RANDOM_PASSWORD" -webBasePath / > /dev/null 2>&1

echo "[4/7] Замена ядра Xray на версию 1.8.23 (linux-64)..."
cd /usr/local/x-ui/bin
rm -f xray-linux-amd64 Xray-linux-64.zip
wget -q https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip
unzip -o Xray-linux-64.zip xray
mv xray xray-linux-amd64
rm -f Xray-linux-64.zip
chmod +x xray-linux-amd64

echo "[5/7] Генерация ключей Reality и создание inbound..."
REALITY_KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 443;"
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (
1, 0, 0, 0, 'VLESS Reality', 1, 0, '', 443, 'vless',
'{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"xtls-rprx-vision:443\",\"email\":\"user1\"}],\"decryption\":\"none\"}',
'{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"dl.google.com:443\",\"xver\":0,\"serverNames\":[\"google.com\",\"www.google.com\",\"android.com\"],\"privateKey\":\"$PRIVATE_KEY\",\"shortIds\":[\"$SHORT_ID\"]},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}',
'inbound-443', '{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\"]}');"

echo "[6/7] Удаление старого конфига и перезапуск..."
# ВАЖНО: удаляем конфиг чтобы панель создала новый под 1.8.23
rm -f /usr/local/x-ui/bin/config.json
x-ui restart

echo "[7/7] Настройка брандмауэра (UFW)..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow $RANDOM_PORT/tcp
ufw --force enable

sleep 5

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "========================================"
echo "=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА! ==="
echo "========================================"
echo ""
echo "🌐 URL панели: http://$SERVER_IP:$RANDOM_PORT/"
echo "👤 Логин: admin"
echo "🔑 Пароль: $RANDOM_PASSWORD"
echo ""
echo "⚙️ Конфигурация VLESS Reality:"
echo "  Адрес: $SERVER_IP"
echo "  Порт: 443"
echo "  UUID: $UUID"
echo "  Flow: xtls-rprx-vision:443"
echo "  Security: reality"
echo "  SNI: google.com"
echo "  Fingerprint: chrome"
echo "  Public Key: $PUBLIC_KEY"
echo "  Short ID: $SHORT_ID"
echo ""
echo "📦 Версия Xray:"
/usr/local/x-ui/bin/xray-linux-amd64 version | head -1
echo ""
echo "📊 Статус:"
x-ui status | grep -E "Active:|xray state"
echo "========================================"
