#!/usr/bin/env bash
# Instala ArgoCD (incluye ApplicationSet controller) de forma idempotente.
set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"

kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd

echo "==> Aplicando manifests de ArgoCD (stable)..."
# --server-side: el CRD applicationsets.argoproj.io supera el límite de 262144
# bytes para la anotación kubectl.kubernetes.io/last-applied-configuration que
# usa el apply "client-side" normal. Server-side apply no depende de esa
# anotación. --force-conflicts para que sea idempotente entre corridas.
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# argocd-server sirve HTTPS autofirmado por defecto; si lo exponemos detrás de
# un Ingress que ya termina TLS (Traefik), eso genera un loop de redirects.
# --insecure hace que sirva HTTP plano puertas adentro, tal como recomienda
# la documentación oficial de ArgoCD para este escenario.
echo "==> Configurando argocd-server en modo --insecure (TLS se termina en el Ingress)..."
kubectl apply -n argocd -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "true"
EOF
kubectl -n argocd rollout restart deployment argocd-server

echo "==> Esperando a que los deployments de argocd estén disponibles..."
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s

echo "==> Contraseña inicial de admin (rótala después del primer login):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
