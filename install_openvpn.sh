#!/bin/bash

set -e

CLIENT_NAME="client"
SERVER_IP=$(curl -s https://api.ipify.org)
PROFILE_DIR="/root/ovpn-profiles"

# Install required packages
yum install -y epel-release
yum install -y openvpn easy-rsa firewalld curl

# Set up Easy-RSA
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p $EASYRSA_DIR
cp -r /usr/share/easy-rsa/3/* $EASYRSA_DIR
cd $EASYRSA_DIR
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
chown nobody:nobody /etc/openvpn/crl.pem

# Create server.conf with PAM plugin
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
crl-verify crl.pem
plugin /usr/lib64/openvpn/plugins/openvpn-plugin-auth-pam.so openvpn
client-cert-not-required
username-as-common-name
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nobody
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

# Enable IP forwarding
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
sysctl -p

# Start and enable firewalld
systemctl start firewalld
systemctl enable firewalld
firewall-cmd --permanent --add-service=openvpn
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-masquerade
firewall-cmd --reload

# Enable NAT
cat > /etc/sysconfig/iptables-openvpn <<EOF
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
COMMIT
EOF

iptables-restore < /etc/sysconfig/iptables-openvpn

# Start OpenVPN
systemctl enable openvpn@server
systemctl start openvpn@server

# Create client profile
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

# Prompt for username and password
echo "Enter VPN username:"
read -r USERNAME
echo "Enter VPN password:"
read -rs PASSWORD

# Create the user with the given credentials
useradd "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

echo "✅ OpenVPN installed with username/password login on CentOS."
echo "👤 Username: $USERNAME"
echo "🔑 Password: $PASSWORD"
echo "📁 Your profile: $PROFILE_DIR/$CLIENT_NAME.ovpn"
