#!/bin/bash
set -e

echo "=== Установка x-ui v2.3.12 с Xray 1.8.23 и VLESS Reality ==="

if [ "$EUID" -ne 0 ]; then
    echo "Пожалуйста, запустите скрипт от имени root"
    exit 1
fi

RANDOM_PORT=$((RANDOM % 55001 + 10000))
RANDOM_PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
RANDOM_PATH="$(openssl rand -hex 8)"

echo "[1/9] Включение BBR..."
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    modprobe tcp_bbr 2>/dev/null || true
    echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    grep -q "net.core.default_qdisc" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1 || true
fi
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control)

echo "[2/9] Обновление системы и установка зависимостей..."
apt-get update -qq
apt-get install -y curl wget sqlite3 ufw unzip

echo "[3/9] Установка x-ui v2.3.12 (без автоматического SSL)..."
yes n | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) v2.3.12 || true

echo "[4/9] Остановка панели..."
systemctl stop x-ui
sleep 1

echo "[5/9] Установка порта, логина, пароля, пути..."
/usr/local/x-ui/x-ui setting -port "$RANDOM_PORT" -username admin -password "$RANDOM_PASSWORD" -webBasePath "$RANDOM_PATH"

sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key IN ('webCertFile','webKeyFile');" 2>/dev/null || true

echo "[6/9] Замена ядра Xray на версию 1.8.23 (linux-64)..."
cd /usr/local/x-ui/bin
rm -f xray-linux-amd64 Xray-linux-64.zip
wget -q https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip
unzip -o Xray-linux-64.zip xray
mv xray xray-linux-amd64
rm -f Xray-linux-64.zip
chmod +x xray-linux-amd64

echo "[7/9] Проверка порта 443 и создание inbound VLESS Reality..."
if ss -tlnp | grep -q ":443 "; then
    echo "⚠️  ВНИМАНИЕ: порт 443 уже занят другим процессом:"
    ss -tlnp | grep ":443 "
fi

REALITY_KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

SETTINGS_JSON=$(printf '{"clients":[{"id":"%s","flow":"xtls-rprx-vision-udp443","email":"user1"}],"decryption":"none"}' "$UUID")
STREAM_JSON=$(printf '{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"dl.google.com:443","xver":0,"serverNames":["www.google.com","google.com","android.com"],"privateKey":"%s","shortIds":["%s"],"settings":{"publicKey":"%s","fingerprint":"chrome"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}' "$PRIVATE_KEY" "$SHORT_ID" "$PUBLIC_KEY")

# Routing с правилом direct для geoip:ru И .ru доменов (как на рабочем сервере)
ROUTING_JSON='{"domainStrategy":"AsIs","rules":[{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","outboundTag":"direct","ip":["geoip:ru"]},{"type":"field","outboundTag":"direct","domain":["geosite:category-gov-ru","regexp:.*\\.ru$"]},{"type":"field","outboundTag":"blocked","ip":["geoip:private"]},{"type":"field","outboundTag":"blocked","protocol":["bittorrent"]}]}'

cat > /tmp/xui_insert.sql << EOF
DELETE FROM inbounds WHERE port = 443;
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
VALUES (1, 0, 0, 0, 'VLESS Reality', 1, 0, '', 443, 'vless', '$SETTINGS_JSON', '$STREAM_JSON', 'inbound-443', '{"enabled":true,"destOverride":["http","tls","quic"]}');
EOF

sqlite3 /etc/x-ui/x-ui.db < /tmp/xui_insert.sql
rm -f /tmp/xui_insert.sql
rm -f /usr/local/x-ui/bin/config.json

# Применяем routing из JSON
sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('routing', '$ROUTING_JSON');"

echo "[8/9] Настройка брандмауэра и запуск..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow "$RANDOM_PORT"/tcp
ufw --force enable
ufw reload

systemctl restart x-ui
sleep 5

echo "[9/9] Получение настроек панели..."
PANEL_INFO=$(/usr/local/x-ui/x-ui setting -show true)
echo "$PANEL_INFO"

ACTUAL_PORT=$(echo "$PANEL_INFO" | grep -Eo 'port: .+' | awk '{print $2}')
ACTUAL_PATH=$(echo "$PANEL_INFO" | grep -Eo 'webBasePath: .+' | awk '{print $2}')

if [ -z "$ACTUAL_PORT" ]; then
    ACTUAL_PORT=$(ss -tlnp 2>/dev/null | grep '"x-ui"' | grep -oP ':\K[0-9]+' | head -1)
fi
[ -z "$ACTUAL_PORT" ] && ACTUAL_PORT="$RANDOM_PORT"
[ -z "$ACTUAL_PATH" ] && ACTUAL_PATH="/$RANDOM_PATH/"

SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "========================================"
echo "=== УСТАНОВКА ЗАВЕРШЕНА ==="
echo "========================================"
echo ""
echo "🌐 URL панели: http://${SERVER_IP}:${ACTUAL_PORT}${ACTUAL_PATH}"
echo "👤 Логин: admin"
echo "🔑 Пароль: $RANDOM_PASSWORD"
echo ""
echo "⚙️ Конфигурация VLESS Reality:"
echo "  Адрес: $SERVER_IP"
echo "  Порт: 443"
echo "  UUID: $UUID"
echo "  Flow: xtls-rprx-vision-udp443"
echo "  Security: reality"
echo "  SNI: www.google.com"
echo "  Fingerprint: chrome"
echo "  Public Key: $PUBLIC_KEY"
echo "  Short ID: $SHORT_ID"
echo ""
echo "🌍 Routing:"
echo "   • geoip:ru → direct (IP РФ без прокси)"
echo "   • *.ru + gov-ru → direct (домены РФ без прокси)"
echo "   • geoip:private → blocked"
echo "   • bittorrent → blocked"
echo ""
echo "🚀 BBR: $BBR_STATUS"
echo ""
echo "📦 Версия Xray:"
/usr/local/x-ui/bin/xray-linux-amd64 version | head -1
echo ""
echo "📊 Статус:"
systemctl status x-ui | grep -E "Active:" 
ps -ef | grep "xray-linux" | grep -v grep > /dev/null && echo "xray state: Running" || echo "xray state: Not Running"
echo "========================================"
