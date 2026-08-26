#!/bin/bash
set -e

echo "=== Installing x-ui v2.3.12 with Xray 1.8.23 and VLESS Reality ==="

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# Update system
echo "Updating system..."
apt-get update -qq

# Install dependencies
echo "Installing dependencies..."
apt-get install -y curl wget sqlite3 ufw unzip

# Download and install x-ui v2.3.12
echo "Installing x-ui v2.3.12..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.3.12

# Wait for installation to complete
sleep 3

# Stop x-ui service
systemctl stop x-ui

# Download Xray 1.8.23
echo "Installing Xray 1.8.23..."
cd /usr/local/x-ui/bin
rm -f xray-linux-amd64
wget -q https://github.com/XTLS/Xray-core/releases/download/v1.8.23/Xray-linux-64.zip
unzip -o Xray-linux-64.zip xray-linux-amd64
rm -f Xray-linux-64.zip
chmod +x xray-linux-amd64

# Generate Reality keys
echo "Generating Reality keys..."
REALITY_KEYS=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(cat /proc/sys/kernel/random/uuid)

echo ""
echo "=== Generated Keys ==="
echo "Private Key: $PRIVATE_KEY"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "UUID: $UUID"
echo ""

# Set admin credentials in database
echo "Setting admin credentials (admin/admin)..."
sqlite3 /etc/x-ui/x-ui.db "UPDATE users SET username='admin', password='admin' WHERE id=1"

# Create VLESS Reality inbound
echo "Creating VLESS Reality inbound on port 443..."
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds"
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) VALUES (
1, 0, 0, 0, 'VLESS Reality', 1, 0, '', 443, 'vless',
'{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"xtls-rprx-vision\",\"email\":\"user1\",\"enable\":true,\"expiryTime\":0,\"totalGB\":0,\"reset\":0,\"limitIp\":0}],\"decryption\":\"none\"}',
'{\"network\":\"tcp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"dest\":\"dl.google.com:443\",\"xver\":0,\"serverNames\":[\"google.com\",\"www.google.com\",\"android.com\"],\"privateKey\":\"$PRIVATE_KEY\",\"shortIds\":[\"$SHORT_ID\"],\"settings\":{\"publicKey\":\"$PUBLIC_KEY\",\"fingerprint\":\"chrome\"}},\"tcpSettings\":{\"acceptProxyProtocol\":false,\"header\":{\"type\":\"none\"}}}',
'inbound-443', '{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"]}')"

# Configure firewall
echo "Configuring firewall..."
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow 2053/tcp
ufw --force enable

# Start x-ui
echo "Starting x-ui..."
systemctl start x-ui
systemctl enable x-ui

sleep 3

# Get server IP
SERVER_IP=$(curl -s ifconfig.me)

echo ""
echo "========================================"
echo "=== Installation Complete! ==="
echo "========================================"
echo ""
echo "Panel URL: http://$SERVER_IP:2053/"
echo "Username: admin"
echo "Password: admin"
echo ""
echo "VLESS Reality Config:"
echo "  Address: $SERVER_IP"
echo "  Port: 443"
echo "  UUID: $UUID"
echo "  Flow: xtls-rprx-vision"
echo "  Security: reality"
echo "  SNI: google.com"
echo "  Fingerprint: chrome"
echo "  Public Key: $PUBLIC_KEY"
echo "  Short ID: $SHORT_ID"
echo ""
echo "Xray version:"
/usr/local/x-ui/bin/xray-linux-amd64 version | head -1
echo ""
echo "x-ui version: v2.3.12"
echo ""
echo "Service status:"
systemctl status x-ui --no-pager | grep Active
echo ""
echo "========================================"
