#!/usr/bin/env bash
# Déploie toute l'application sur le cluster du contexte kubectl courant, dans l'ordre de RENDU-EXAMEN.md.
#   INGRESS_PROVIDER=cloud  Docker Desktop (défaut) : le contrôleur est exposé en LoadBalancer sur localhost
#   INGRESS_PROVIDER=kind   CI GitHub Actions : le contrôleur écoute en hostPort 80/443 du nœud kind
set -euo pipefail

INGRESS_NGINX_VERSION=controller-v1.15.1
INGRESS_PROVIDER=${INGRESS_PROVIDER:-cloud}
K8S_DIR="$(cd "$(dirname "$0")/../k8s" && pwd)"

echo "==> Contrôleur Ingress ingress-nginx ($INGRESS_PROVIDER)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/$INGRESS_PROVIDER/deploy.yaml"
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

echo "==> ConfigMap, Secret, PV/PVC et Deployments"
kubectl apply -f "$K8S_DIR/configmap.yaml" -f "$K8S_DIR/secret.yaml"
kubectl apply -f "$K8S_DIR/mysql-storage.yaml"
kubectl apply -f "$K8S_DIR/mysql-deployment.yaml"
kubectl apply -f "$K8S_DIR/spring-deployment.yaml"
kubectl apply -f "$K8S_DIR/angular-deployment.yaml"

echo "==> Ingress"
# Juste après son démarrage, le webhook d'admission d'ingress-nginx peut encore refuser les requêtes
attempts=0
until kubectl apply -f "$K8S_DIR/ingress.yaml"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 30 ] || exit 1
  sleep 5
done

echo "==> Attente des déploiements"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/mysql-pvc --timeout=180s
kubectl rollout status deploy/mysql --timeout=300s
kubectl rollout status deploy/spring-app --timeout=300s
kubectl rollout status deploy/angular-app --timeout=180s
kubectl get pods,services,ingress,pv,pvc -o wide
