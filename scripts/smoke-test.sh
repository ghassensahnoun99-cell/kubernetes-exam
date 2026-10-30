#!/usr/bin/env bash
# Tests de bout en bout via l'Ingress : mêmes vérifications que RENDU-EXAMEN.md (partie 3.2).
set -euo pipefail

BASE_URL=${BASE_URL:-http://localhost}

fail() { echo "ÉCHEC : $*" >&2; exit 1; }

# L'Ingress et Spring Boot peuvent mettre un moment à répondre après un déploiement ou un redémarrage
echo "==> Attente de l'API ($BASE_URL/api/user/all)"
attempts=0
until curl -fs -o /dev/null "$BASE_URL/api/user/all"; do
  attempts=$((attempts + 1))
  [ "$attempts" -lt 60 ] || fail "l'API ne répond pas"
  sleep 5
done

echo "==> Front-end Angular"
index=$(curl -fsS "$BASE_URL/")
grep -q '<app-root' <<<"$index" || fail "index.html d'Angular non servi"
config=$(curl -fsS "$BASE_URL/assets/config.js")
grep -q "apiUrl = '/api'" <<<"$config" || fail "config.js inattendu : $config"

echo "==> API : ajout, lecture, suppression"
created=$(curl -fsS -X POST "$BASE_URL/api/user/add" -H 'Content-Type: application/json' \
  -H "Origin: $BASE_URL" -d '{"firstName":"Smoke","lastName":"Test"}')
id=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"$created")
[ -n "$id" ] || fail "réponse inattendue à l'ajout : $created"
users=$(curl -fsS "$BASE_URL/api/user/all")
grep -q "\"id\":$id," <<<"$users" || fail "utilisateur $id absent de la liste"
curl -fsS -o /dev/null -X DELETE "$BASE_URL/api/user/delete/$id"
users=$(curl -fsS "$BASE_URL/api/user/all")
if grep -q "\"id\":$id," <<<"$users"; then fail "utilisateur $id non supprimé"; fi

echo "==> /actuator non publié par l'Ingress"
actuator=$(curl -sS "$BASE_URL/api/actuator/env")
if grep -q 'propertySources' <<<"$actuator"; then fail "/actuator/env est accessible depuis l'extérieur"; fi

echo "Tous les tests sont passés."
