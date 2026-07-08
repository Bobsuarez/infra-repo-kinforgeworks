#!/usr/bin/env bash
# Endurece sshd: deshabilita login por contraseña (root solo puede entrar con llave) y mueve SSH
# a un puerto no estándar.
# IMPORTANTE: requiere que ya tengas tu llave pública en ~/.ssh/authorized_keys del usuario con el
# que te conectas. Verifica ANTES de correr este script que puedes hacer login sin contraseña,
# o quedarás bloqueado fuera del VPS.
set -euo pipefail

SSH_PORT="${SSH_PORT:-2222}"
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "Este script debe correrse con sudo/root." >&2
  exit 1
fi

echo "==> Backup de ${SSHD_CONFIG} en ${BACKUP}"
cp "$SSHD_CONFIG" "$BACKUP"

set_directive() {
  local key="$1" value="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$SSHD_CONFIG"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${value}|" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

echo "==> Aplicando directivas de hardening"
set_directive "Port" "$SSH_PORT"
set_directive "PasswordAuthentication" "no"
set_directive "PermitRootLogin" "prohibit-password"
set_directive "ChallengeResponseAuthentication" "no"
set_directive "KbdInteractiveAuthentication" "no"
set_directive "PubkeyAuthentication" "yes"
set_directive "MaxAuthTries" "3"

echo "==> Validando sintaxis de sshd_config"
sshd -t

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "==> Abriendo puerto ${SSH_PORT}/tcp en ufw antes de reiniciar sshd"
  ufw allow "${SSH_PORT}/tcp"
fi

echo "==> Reiniciando sshd"
SSH_UNIT="sshd"
if ! systemctl list-unit-files --type=service | grep -q '^sshd\.service'; then
  SSH_UNIT="ssh"
fi
systemctl restart "$SSH_UNIT"

cat <<EOF

==> Listo. A partir de ahora conéctate así:
    ssh -p ${SSH_PORT} usuario@host

NO cierres esta sesión todavía: abre una terminal nueva y confirma que puedes
entrar por el puerto ${SSH_PORT} con tu llave antes de cerrar esta.

Si algo falla, restaura el backup con:
    cp ${BACKUP} ${SSHD_CONFIG} && systemctl restart sshd
EOF
