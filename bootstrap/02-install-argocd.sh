#!/usr/bin/env bash
# Instala ArgoCD (incluye ApplicationSet controller) de forma idempotente.
set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"

kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd

echo "==> Aplicando manifests de ArgoCD (stable)..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Esperando a que los deployments de argocd estén disponibles..."
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s

echo "==> Contraseña inicial de admin (rótala después del primer login):"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
