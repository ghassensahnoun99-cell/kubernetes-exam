#!/usr/bin/env bash
# Récupère le contenu du PersistentVolume de MySQL (mysql-pv, réclamé par mysql-pvc).
#   scripts/pv-content.sh ls          liste les fichiers du PV
#   scripts/pv-content.sh copy [dir]  copie brute du PV dans <dir>/mysql-pv-<date>.tar.gz (défaut : pv-backup)
#   scripts/pv-content.sh dump [dir]  export SQL cohérent de la base dans <dir>/mysql-dump-<date>.sql
#   scripts/pv-content.sh shell       shell dans le PV monté en lecture seule (/data)
#   scripts/pv-content.sh clean       supprime le Pod pv-inspector
set -euo pipefail

MANIFEST="$(cd "$(dirname "$0")/.." && pwd)/k8s/tools/pv-inspector.yaml"
POD=pv-inspector
STAMP=$(date +%Y%m%d-%H%M%S)

# ls, copy et shell lisent le PV via un Pod dédié : ils fonctionnent même si MySQL ne démarre plus
start_inspector() {
  kubectl apply -f "$MANIFEST" >/dev/null
  kubectl wait --for=condition=ready "pod/$POD" --timeout=120s >/dev/null
}

cmd=${1:-}
dest=${2:-pv-backup}

case "$cmd" in
  ls)
    start_inspector
    kubectl exec "$POD" -- sh -c 'du -sh /data && ls -la /data'
    ;;
  copy)
    # Copie à chaud des fichiers InnoDB : utile pour inspecter, mais pour une sauvegarde restaurable utiliser dump
    start_inspector
    mkdir -p "$dest"
    out="$dest/mysql-pv-$STAMP.tar.gz"
    kubectl exec "$POD" -- tar czf - -C /data . > "$out"
    echo "Copie brute du PV : $out ($(du -h "$out" | cut -f1))"
    ;;
  dump)
    mkdir -p "$dest"
    out="$dest/mysql-dump-$STAMP.sql"
    # shellcheck disable=SC2016  # les variables sont développées dans le Pod MySQL, pas en local
    kubectl exec deploy/mysql -- sh -c \
      'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump -uroot --single-transaction --databases "$MYSQL_DATABASE"' > "$out"
    echo "Export SQL : $out ($(du -h "$out" | cut -f1))"
    ;;
  shell)
    start_inspector
    kubectl exec -it "$POD" -- sh -c 'cd /data && exec sh'
    ;;
  clean)
    kubectl delete -f "$MANIFEST" --ignore-not-found
    ;;
  *)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
