#!/usr/bin/env bash
# Instala y configura fail2ban + ufw para banear IPs que hagan fuerza bruta sobre SSH.
# Correr DESPUÉS de 04-harden-ssh.sh (usa la misma variable SSH_PORT para el jail).
set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"

if [[ $EUID -ne 0 ]]; then
  echo "Este script debe correrse con sudo/root." >&2
  exit 1
fi

echo "==> Instalando fail2ban y ufw"
apt-get update -qq
apt-get install -y -qq fail2ban ufw

echo "==> Configurando ufw (default deny incoming, allow SSH/${SSH_PORT}, 80, 443)"
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> Configurando jail de fail2ban para sshd en puerto ${SSH_PORT}"
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 3
findtime = 24h # 10m dejaba pasar bots "low and slow" (1 intento cada
# ~12-14 min, justo debajo del umbral) - nunca acumulaban los 3 fallos
bantime  = 1h
bantime.increment = true
bantime.factor    = 4
bantime.maxtime   = 1w
EOF

echo "==> Reiniciando fail2ban"
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "==> Estado de jails:"
fail2ban-client status sshd || true

cat <<'EOF'

==> Listo. Comandos útiles:
    sudo fail2ban-client status sshd        # ver IPs baneadas
    sudo fail2ban-client set sshd unbanip <IP>   # desbanear una IP
    sudo ufw status verbose                 # ver reglas de firewall
EOF
