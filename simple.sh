echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf

sysctl -w net.ipv4.ip_forward=1

export MYIP=$(curl -s ifconfig.me)
export CLOUDFLAREIP=$(getent ahostsv4 engage.cloudflareclient.com | awk '{print $1; exit}')

iptables -t nat -A PREROUTING \
  -d ${MYIP} -p udp --dport 4500 \
  -j DNAT --to-destination ${CLOUDFLAREIP}:4500

iptables -t nat -A POSTROUTING \
  -p udp -d ${CLOUDFLAREIP} --dport 4500 \
  -j MASQUERADE


iptables -A FORWARD -p udp -d ${CLOUDFLAREIP} --dport 4500 -j ACCEPT
iptables -A FORWARD -p udp -s ${CLOUDFLAREIP} --sport 4500 -j ACCEPT

sudo apt install -y iptables-persistent

iptables-save > /etc/iptables/rules.v4
