#!/bin/bash

set -e

CLIENT_NAME="client"
SERVER_IP=$(curl -s https://api.ipify.org)
PROFILE_DIR="/root/ovpn-profiles"

# Install dependencies
apt update && apt install -y openvpn easy-rsa curl ufw

# Set up Easy-RSA
make-cadir ~/openvpn-ca
cd ~/openvpn-ca
./easyrsa init-pki
echo -ne "\n" | ./easyrsa build-ca nopass
./easyrsa gen-req server nopass <<< "yes"
./easyrsa sign-req server server <<< "yes"
./easyrsa gen-dh
./easyrsa gen-req $CLIENT_NAME nopass <<< "yes"
./easyrsa sign-req client $CLIENT_NAME <<< "yes"
./easyrsa gen-crl

# Move server files
cp pki/ca.crt pki/dh.pem pki/private/server.key pki/issued/server.crt /etc/openvpn/
cp pki/crl.pem /etc/openvpn/crl.pem
chown nobody:nogroup /etc/openvpn/crl.pem

# Create OpenVPN server config with PAM auth
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
crl-verify crl.pem
auth-user-pass-verify /etc/openvpn/checkpsw.sh via-env
username-as-common-name
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
plugin /usr/lib/openvpn/openvpn-plugin-auth-pam.so login
status openvpn-status.log
verb 3
EOF

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Basic firewall config (UFW)
ufw allow OpenSSH
ufw allow 1194/udp
ufw disable
ufw --force enable

# NAT rules
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
iptables-save > /etc/iptables.rules

cat > /etc/network/if-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-up.d/iptables

# Start OpenVPN
systemctl start openvpn@server
systemctl enable openvpn@server

# Create client config with auth prompt
mkdir -p $PROFILE_DIR
cat > $PROFILE_DIR/$CLIENT_NAME.ovpn <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
auth-user-pass
remote-cert-tls server
cipher AES-256-CBC
verb 3
<ca>
$(cat pki/ca.crt)
</ca>
<cert>
$(cat pki/issued/$CLIENT_NAME.crt)
</cert>
<key>
$(cat pki/private/$CLIENT_NAME.key)
</key>
EOF

# Create user for VPN login
USERNAME="vpnuser"
PASSWORD="changeme123"

echo -e "$PASSWORD\n$PASSWORD" | adduser --quiet --gecos "" $USERNAME

echo "✅ OpenVPN installed with username/password login."
echo "👤 Username: $USERNAME"
echo "🔑 Password: $PASSWORD"
echo "📁 Download your profile: $PROFILE_DIR/$CLIENT_NAME.ovpn"
