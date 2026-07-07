#!/usr/bin/env bash
# Convierte un Secret en texto plano en un SealedSecret listo para commitear a
# Git. Correr desde tu máquina local con kubectl apuntando al clúster (o con
# el certificado público exportado, ver `kubeseal --fetch-cert`).
#
# Uso:
#   ./bootstrap/seal-secret.sh secret-plano.yaml apps/maestrias/leads/secret.sealed.yaml
#
# El archivo de salida es seguro de commitear. El de entrada (texto plano) NO -
# bórralo o guárdalo fuera del repo después de sellarlo.
set -euo pipefail

if ! command -v kubeseal >/dev/null 2>&1; then
  echo "kubeseal no está instalado: https://github.com/bitnami-labs/sealed-secrets#kubeseal" >&2
  exit 1
fi

INPUT="${1:?uso: $0 <secret-plano.yaml> <salida-sealedsecret.yaml>}"
OUTPUT="${2:?uso: $0 <secret-plano.yaml> <salida-sealedsecret.yaml>}"

kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml \
  <"$INPUT" >"$OUTPUT"

echo "Listo: $OUTPUT (seguro de commitear)."
echo "Recuerda NO commitear $INPUT."
