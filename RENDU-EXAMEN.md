# Rendu — Déploiement Angular + Spring Boot sur Kubernetes

Environnement : cluster Kubernetes **local de Docker Desktop** (nœud unique `docker-desktop`, rôle control-plane et worker à la fois) sur macOS Intel.

## Architecture

```
Navigateur (poste local)
   │  http://localhost/ (port 80)
   ▼
ingress-nginx-controller (Service LoadBalancer → localhost:80)
   │  angular-ingress  /                  spring-ingress  /api/user/... → /user/...
   ▼                                      ▼
angular-service (ClusterIP 80)       spring-service (ClusterIP 8081)
   │                                      │
angular-app ×2 (Nginx :80)           spring-app ×2 (Spring Boot :8081)
  /assets/config.js ← ConfigMap         env ← ConfigMap spring-config + Secret spring-secret
                                          │  jdbc:mysql://mysql-service:3306/demo
                                          ▼
                                     mysql-service (ClusterIP 3306) → mysql ×1
                                          │  /var/lib/mysql
                                          ▼
                                     PVC mysql-pvc (1Gi demandé) → PV mysql-pv (2Gi, hostPath)
```

| Élément | Valeur |
|---|---|
| Nœud | `docker-desktop` (control-plane + worker) |
| Point d'entrée unique | **Ingress** `http://localhost` (contrôleur ingress-nginx, Service LoadBalancer publié par Docker Desktop sur le port 80) |
| Front-end | `http://localhost/` → `angular-service` |
| API | `http://localhost/api/user/...` → `spring-service` (préfixe `/api` retiré par l'Ingress) |
| Services | tous en **ClusterIP** : aucun NodePort, rien n'est joignable sans passer par l'Ingress |

> Le front appelle l'API par l'URL relative `/api` : front et API ont la même origine, il n'y a donc plus de requête cross-origin. Sur un cluster de VM, seule `CORS_ALLOWED_ORIGINS` est à adapter (`http://IP_du_nœud`), et le contrôleur s'installe avec le manifest `baremetal`, qui l'expose en NodePort.

---

## Partie 1 — Préparation

1. Installer Docker Desktop, puis **Settings → Kubernetes → Enable Kubernetes → Apply & Restart**.
2. Vérifications :

```bash
docker --version
kubectl version --client
kubectl config use-context docker-desktop
kubectl get nodes -o wide        # docker-desktop doit être Ready
git clone https://github.com/NouraneZouabi/test.git && cd test
```

## Partie 2 — Images Docker

### 2.1 Dockerfile Angular (`angular-app/Dockerfile`)

```dockerfile
FROM node:16-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm install --force
COPY . .
RUN npm run build --force

FROM nginx:1.17.1-alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist/angular-app /usr/share/nginx/html
EXPOSE 80
```

Le chemin de compilation est vérifié dans `angular.json` : `"outputPath": "dist/angular-app"`.

### 2.2 Dockerfile Spring Boot (`springboot/app/Dockerfile`)

```dockerfile
FROM eclipse-temurin:17-jre
VOLUME /tmp
EXPOSE 8081
ARG JAR_FILE=target/demo-0.0.1.jar
ADD ${JAR_FILE} app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
```

**Écart justifié par rapport à OpenJDK 11 :** le `pom.xml` fourni utilise Spring Boot 3.3.11 avec `java.version=17`. Spring Boot 3 exige Java 17 au minimum et le bytecode est compilé en version 61 : une JVM 11 échouerait avec `UnsupportedClassVersionError`. On utilise donc une JRE OpenJDK 17 (Eclipse Temurin, distribution officielle d'OpenJDK ; l'image `openjdk` de Docker Hub est dépréciée).

### 2.3 Build et publication

```bash
# Compilation Maven (dans un conteneur, aucune installation de Java/Maven requise)
cd springboot/app
docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-17 mvn -B package -DskipTests
ls target/demo-0.0.1.jar

docker build -t spring-app:1.0 .
cd ../../angular-app
docker build -t angular-app:1.0 .
cd ..

# Publication Docker Hub (compte g4ss99)
docker login
docker tag spring-app:1.0  g4ss99/spring-app:1.0
docker tag angular-app:1.0 g4ss99/angular-app:1.0
docker push g4ss99/spring-app:1.0
docker push g4ss99/angular-app:1.0
```

Les manifests utilisent `g4ss99/spring-app:1.0` et `g4ss99/angular-app:1.0` avec `imagePullPolicy: IfNotPresent` : Docker Desktop réutilise l'image locale si elle existe, sinon la tire depuis Docker Hub.

## Partie 3 — Déploiement

### 3.1 Manifests (`k8s/`)

| Fichier | Contenu |
|---|---|
| `configmap.yaml` | ConfigMap `spring-config` (port, URL JDBC, origine CORS, nom de base) + ConfigMap `angular-config` (`config.js`) |
| `secret.yaml` | Secret `spring-secret` (utilisateur, mot de passe, mot de passe root MySQL) en `data:` **encodé base64**, **valeurs fictives** |
| `mysql-storage.yaml` | PersistentVolume `mysql-pv` (2Gi, hostPath, `Retain`) + PersistentVolumeClaim `mysql-pvc` (demande 1Gi), classe `manual` |
| `mysql-deployment.yaml` | MySQL 8, `/var/lib/mysql` monté sur le PVC `mysql-pvc`, stratégie `Recreate` + Service **ClusterIP** `mysql-service` (communication interne uniquement) |
| `spring-deployment.yaml` | 2 réplicas, `configMapKeyRef`/`secretKeyRef`, initContainer qui attend MySQL, sondes `/actuator/health/readiness` et `/actuator/health/liveness` (indépendantes de MySQL), Service **ClusterIP** |
| `angular-deployment.yaml` | 2 réplicas Nginx, `config.js` monté depuis le ConfigMap, Service **ClusterIP** |
| `tools/pv-inspector.yaml` | Pod utilitaire `busybox` qui monte `mysql-pvc` en lecture seule sur `/data` (utilisé par `scripts/pv-content.sh`, non appliqué par `kubectl apply -f k8s/`) |
| `ingress.yaml` | Ingress `angular-ingress` (`/`) et `spring-ingress` (`/api/user/...` réécrit en `/user/...`), classe `nginx` |

Pourquoi un Ingress : Angular s'exécute **dans le navigateur**, qui doit joindre le front **et** l'API depuis l'extérieur du cluster. Plutôt qu'un NodePort par Service, un seul point d'entrée HTTP (port 80) route selon le chemin. Les Services restent en ClusterIP. L'Ingress ne publie que `/api/user/...` : les endpoints `/actuator` (dont `env` et `heapdump`) restent internes, et les sondes y accèdent directement dans le Pod.

`replicas: 2` pour `spring-app` et `angular-app` : si un Pod tombe ou est redéployé (rolling update), l'autre continue de répondre, et le Service répartit les requêtes entre les deux. MySQL reste à 1 réplica, car plusieurs instances indépendantes ne partageraient pas les mêmes données.

### 3.2 Exécution

```bash
# Contrôleur Ingress (une seule fois par cluster)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=300s
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP = localhost

cd k8s
kubectl apply -f configmap.yaml
kubectl apply -f secret.yaml
kubectl apply -f mysql-storage.yaml          # PV + PVC, avant le Deployment qui utilise le PVC
kubectl apply -f mysql-deployment.yaml
kubectl apply -f spring-deployment.yaml
kubectl apply -f angular-deployment.yaml
kubectl apply -f ingress.yaml

kubectl get nodes,pods,deployments,services,ingress -o wide
kubectl get pv,pvc                           # STATUS Bound pour les deux
kubectl describe ingress
kubectl describe pod -l app=spring-app
kubectl logs deploy/spring-app
```

Tests :

```bash
curl http://localhost/api/user/all
curl -X POST http://localhost/api/user/add -H 'Content-Type: application/json' \
     -d '{"firstName":"Ada","lastName":"Lovelace"}'
curl http://localhost/api/user/all
curl -X DELETE http://localhost/api/user/delete/1
curl http://localhost/assets/config.js                       # apiUrl = '/api'
curl -s http://localhost/api/actuator/env | head -c 15   # <!doctype html> : la page Angular, l'actuator n'est pas publié
```

Puis ouvrir **http://localhost** : liste, ajout et suppression d'utilisateurs. L'onglet Réseau des DevTools montre les appels à `http://localhost/api/user/...`.

### 3.3 Persistance MySQL (PV / PVC)

Avec `emptyDir`, les données disparaissaient à chaque recréation du Pod MySQL. Elles sont maintenant sur un volume persistant, en **provisionnement statique** :

- **PersistentVolume `mysql-pv`** : le stockage côté cluster (rôle administrateur). Il offre **2Gi**, en `ReadWriteOnce` (monté en écriture par un seul nœud), sur un répertoire `hostPath` du nœud (`/var/lib/mysql-pv`, dans la VM Docker Desktop). `persistentVolumeReclaimPolicy: Retain` conserve les données même si le PVC est supprimé.
- **PersistentVolumeClaim `mysql-pvc`** : la demande côté application. Il réclame **1Gi** en `ReadWriteOnce`, dans la classe `manual`, avec un selector sur le label `app: mysql`. Kubernetes le lie à un PV qui remplit **toutes** ces conditions : même `storageClassName`, mode d'accès compatible, labels correspondants et capacité **≥ 1Gi**.
- `storageClassName: manual` ne correspond à aucune StorageClass. Sans cela, le PVC serait servi automatiquement par la StorageClass par défaut de Docker Desktop (`hostpath`), qui créerait un volume dynamique au lieu d'utiliser `mysql-pv`.
- Le Deployment monte le PVC (`persistentVolumeClaim.claimName: mysql-pvc`) sur `/var/lib/mysql`. La stratégie `Recreate` arrête l'ancien Pod avant de démarrer le nouveau, ce qui est nécessaire avec un volume `ReadWriteOnce`.

À savoir : la liaison PV/PVC est **un pour un**. Un PVC qui demande 1Gi obtient le PV **entier**, et `kubectl get pvc` affiche donc `CAPACITY 2Gi`. Le Gi restant ne peut pas servir à un autre PVC. Pour ne rien perdre, on donne au PV la taille demandée. Avec `hostPath`, la capacité sert seulement à la mise en correspondance : aucun quota disque n'est appliqué. Un événement `ProvisioningFailed … "manual" not found` peut apparaître juste après la création : le PVC a été examiné avant que le PV soit visible, puis il est lié au passage suivant du contrôleur.

Vérification de la persistance :

```bash
kubectl get pv,pvc                                   # mysql-pv Bound à default/mysql-pvc
curl -X POST http://localhost/api/user/add -H 'Content-Type: application/json' \
     -d '{"firstName":"Persist","lastName":"Test"}'
kubectl rollout restart deploy/mysql                 # nouveau Pod MySQL, même PVC
kubectl rollout status deploy/mysql
kubectl exec deploy/mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT * FROM demo.user"'
# la ligne "Persist Test" est toujours présente
```

`rollout restart` respecte la stratégie `Recreate` : l'ancien Pod est arrêté avant que le nouveau monte le volume. Avec un `kubectl delete pod`, le ReplicaSet crée le remplaçant **immédiatement**, pendant que l'ancien MySQL s'arrête encore : deux `mysqld` ouvrent alors les mêmes fichiers. Le verrou d'InnoDB les protège (`Unable to lock ./ibdata1 error: 11` dans les logs, jusqu'à ce que l'ancien libère les fichiers), mais il vaut mieux l'éviter.

Limite : `hostPath` lie les données à **un** nœud, ce qui convient au cluster mono-nœud de Docker Desktop. Sur un cluster multi-nœuds, on utiliserait un stockage réseau (NFS, disque cloud) ou un PV `local` avec `nodeAffinity`.

**Récupérer le contenu du PV** (`scripts/pv-content.sh`) :

```bash
scripts/pv-content.sh ls      # liste les fichiers du PV (taille totale, dossier demo/ de la base…)
scripts/pv-content.sh dump    # pv-backup/mysql-dump-<date>.sql : export SQL cohérent, restaurable
scripts/pv-content.sh copy    # pv-backup/mysql-pv-<date>.tar.gz : copie brute des fichiers du PV
scripts/pv-content.sh shell   # shell dans /data (lecture seule)
scripts/pv-content.sh clean   # supprime le Pod pv-inspector
```

`ls`, `copy` et `shell` passent par le Pod `pv-inspector` (`k8s/tools/pv-inspector.yaml`), qui monte le **même PVC** en lecture seule. C'est possible parce que `ReadWriteOnce` limite l'accès à un **nœud**, pas à un Pod. Ces commandes fonctionnent donc même si MySQL ne démarre plus. `dump` passe par `mysqldump --single-transaction` dans le Pod MySQL. La copie brute est faite à chaud : elle sert à inspecter le contenu, mais une sauvegarde restaurable s'obtient avec `dump`. Restauration :

```bash
kubectl exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' < pv-backup/mysql-dump-<date>.sql
```

`pv-backup/` est exclu de Git (`.gitignore`) : il contient les données de la base et les clés TLS générées par MySQL.

### 3.4 Valeurs codées en dur relevées

| Fichier | Valeur d'origine | Correction |
|---|---|---|
| `CorsConfig.java` | `allowedOrigins("http://44.218.110.160:4200")` | lu depuis `app.cors.allowed-origins` ← `CORS_ALLOWED_ORIGINS` |
| `application.properties` | `server.port=8081`, URL JDBC, `username=root`, `password=root`, `spring.mvc.cors.*` avec `44.218.110.160:31238` | `${SERVER_PORT}`, `${SPRING_DATASOURCE_URL}`, `${SPRING_DATASOURCE_USERNAME}`, `${SPRING_DATASOURCE_PASSWORD}` ; les clés `spring.mvc.cors.*` (non reconnues par Spring Boot) sont supprimées |
| `environment.ts` / `environment.prod.ts` | pas d'URL d'API | `apiUrl` lu depuis `window.__env.apiUrl` |
| `user.service.ts` | `baseURL="http://44.218.110.160:8081/user"` | `environment.apiUrl + "/user"` |
| `proxy.config.json` (dev) | `http://44.218.110.160:8081/` | `http://localhost:8081/` |
| `utils/app-init.ts` | Keycloak `http://localhost:8080/` | fichier non compilé (absent de `tsconfig.app.json`), laissé tel quel |

## Partie 4 — ConfigMap et Secret

### 4.1 Classement

| Non sensible → ConfigMap | Sensible → Secret |
|---|---|
| `SERVER_PORT`, `SPRING_DATASOURCE_URL`, `MYSQL_DATABASE`, `CORS_ALLOWED_ORIGINS`, `apiUrl` du front | `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`, `MYSQL_ROOT_PASSWORD` |

L'application se connecte avec un utilisateur dédié (`MYSQL_USER`), et non plus avec `root`.

### 4.2 Secret encodé en base64

`secret.yaml` utilise le champ `data:`, qui attend des valeurs **encodées en base64** :

```bash
printf '%s' 'demo_user' | base64                 # ZGVtb191c2Vy   (printf : pas de \n final encodé)
kubectl get secret spring-secret -o jsonpath='{.data.SPRING_DATASOURCE_USERNAME}' | base64 -d
```

Base64 est un **encodage réversible, pas un chiffrement** : la ligne ci-dessus suffit à relire la valeur. La protection réelle vient du RBAC et du chiffrement d'etcd au repos (voir question 6).

### 4.3 Front-end : configuration à l'exécution

Une variable d'environnement d'un conteneur Nginx n'est jamais vue par le navigateur, car celui-ci télécharge seulement des fichiers statiques. La solution retenue :

1. `src/assets/config.js` définit `window.__env.apiUrl` (valeur par défaut pour le développement).
2. `index.html` charge `assets/config.js` **avant** le bundle Angular.
3. `environment.ts` lit `window.__env.apiUrl`, et `user.service.ts` utilise `environment.apiUrl`.
4. Dans Kubernetes, le ConfigMap `angular-config` est monté par `subPath` sur `/usr/share/nginx/html/assets/config.js` et remplace le fichier de l'image. Nginx le sert avec `Cache-Control: no-store`.

La même image fonctionne donc dans tous les environnements : changer d'URL d'API ne demande pas de recompiler.
Après une modification du ConfigMap : `kubectl rollout restart deploy/angular-app` (un montage `subPath` n'est pas mis à jour à chaud), et `kubectl rollout restart deploy/spring-app` pour les variables d'environnement.

### 4.4 Validation

```bash
kubectl apply -f configmap.yaml -f secret.yaml -f spring-deployment.yaml -f angular-deployment.yaml -f ingress.yaml
kubectl get configmaps,secrets,deployments,pods,services,ingress,pv,pvc
kubectl describe secret spring-secret          # n'affiche que la taille des valeurs
kubectl exec deploy/spring-app -- printenv | grep -E 'SERVER_PORT|DATASOURCE_URL|CORS'
```

---

## Partie 5 — Questions de compréhension

**1. Pourquoi Node.js puis Nginx ? WORKDIR et COPY ?**
Node.js sert uniquement à **compiler** Angular (TypeScript vers HTML, JS et CSS). Le résultat est un ensemble de fichiers statiques qu'un serveur web léger comme Nginx sert très bien. Le build multi-stage ne garde que l'étape Nginx dans l'image finale, sans Node ni `node_modules` : l'image est plus petite et la surface d'attaque réduite.
`WORKDIR /app` définit (et crée) le répertoire courant des instructions suivantes. Le premier `COPY package*.json ./` copie seulement les fichiers de dépendances, ce qui permet de mettre en cache la couche `npm install` tant qu'ils ne changent pas. Le second `COPY . .` copie le code source, qui change souvent, juste avant le build.

**2. EXPOSE, ENTRYPOINT, ARG JAR_FILE ?**
`EXPOSE 8081` documente le port d'écoute du conteneur, sans le publier (c'est `docker run -p` ou un Service qui le publie). `ENTRYPOINT ["java","-jar","/app.jar"]` est la commande lancée au démarrage du conteneur, en forme exec : java devient le PID 1 et reçoit SIGTERM. `ARG JAR_FILE` est une variable de **build** qui désigne le jar à copier, modifiable avec `docker build --build-arg JAR_FILE=...` ; elle n'existe plus à l'exécution.

**3. Sections d'un Deployment ? `kubectl apply -f` ?**
`apiVersion`, `kind`, `metadata` (nom, labels), puis `spec` : `replicas`, `selector.matchLabels`, `strategy`, et `template`, c'est-à-dire le modèle de Pod (`metadata.labels`, qui doivent correspondre au selector, et `spec.containers` avec image, ports, env, sondes, volumes). `kubectl apply -f` envoie la configuration déclarative à l'API server : il crée l'objet s'il n'existe pas, sinon il calcule la différence et le met à jour. Les contrôleurs font ensuite converger l'état réel vers l'état désiré (par exemple un rolling update).

**4. ClusterIP / NodePort / LoadBalancer ?**
**ClusterIP** (par défaut) donne une IP virtuelle et un nom DNS joignables seulement depuis le cluster : c'est le type des trois Services ici, puisque l'accès externe passe par l'Ingress. **NodePort** ouvre un port (30000–32767) sur **chaque nœud** et permet donc d'accéder au service depuis l'extérieur via `IP_du_nœud:port`, sans infrastructure supplémentaire : c'est adapté aux VM et à Docker Desktop. **LoadBalancer** demande à un fournisseur cloud (ou à MetalLB) de créer un répartiteur avec une IP externe. Sur des VM sans ce composant, l'`EXTERNAL-IP` reste `<pending>`. Docker Desktop publie les LoadBalancer sur `localhost`. Un **Ingress** n'est pas un type de Service : c'est une règle de routage HTTP (hôte et chemin vers un Service), appliquée par un contrôleur (ici ingress-nginx) qui est lui-même exposé par **un seul** Service LoadBalancer ou NodePort.

**5. Diagnostiquer un problème de connectivité VM → Service → Pod**
On remonte couche par couche :
- Nœuds : `kubectl get nodes` (Ready ?), `ping` entre les VM, pare-feu (`ufw status`, ports 30000–32767).
- Pods : `kubectl get pods -o wide` (Running/Ready ?), `kubectl describe pod` (events, ImagePullBackOff, sondes), `kubectl logs`.
- Service : `kubectl get endpoints <svc>` (une liste vide signifie que le selector ne correspond à aucun label de Pod ou que les Pods ne sont pas Ready), vérifier `port`/`targetPort`.
- DNS et réseau interne : `kubectl run tmp --rm -it --image=busybox -- sh`, puis `nslookup mysql-service` et `wget -qO- spring-service:8081/user/all`.
- Ingress : `kubectl get ingress` (classe `nginx`, ADDRESS renseignée ?), `kubectl describe ingress` (backends et endpoints), `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller` (404 = aucune règle ne correspond, 503 = Service sans endpoint).
- Accès externe : `curl http://localhost/api/user/all` depuis le poste client (`IP_nœud:NodePort_du_contrôleur` sur des VM).
- Navigateur : onglet Réseau, URL de `config.js`.

**6. ConfigMap vs Secret ? Pourquoi protéger les Secrets ?**
Les deux stockent des paires clé/valeur, injectées en variables d'environnement ou en fichiers. Le ConfigMap est fait pour la configuration non sensible. Le Secret est fait pour les données sensibles : il est traité à part (pas affiché par `describe`, montable en tmpfs, RBAC distinct). Mais un Secret est seulement **encodé en base64, pas chiffré** : toute personne qui peut faire `get secret` dans le namespace, ou créer un Pod qui le monte, peut lire la valeur. Il faut donc limiter l'accès avec **RBAC**. Par défaut, il est aussi stocké en clair dans **etcd** : on active le **chiffrement au repos** (`EncryptionConfiguration`, ou un KMS) pour qu'une sauvegarde etcd ou un accès disque ne révèle pas les mots de passe. Enfin, on ne committe jamais de vraies valeurs (d'où les valeurs fictives dans `secret.yaml`, simplement encodées en base64 dans `data:`).

---

## Annexe — Dépôt Git et intégration continue (GitHub Actions)

### Contenu du dépôt

| Chemin | Rôle |
|---|---|
| `angular-app/`, `springboot/app/` | Code source et Dockerfiles |
| `k8s/` | Manifests Kubernetes (parties 3 et 4) |
| `scripts/deploy.sh` | Installe ingress-nginx puis applique les manifests dans l'ordre de la partie 3.2 et attend les déploiements |
| `scripts/smoke-test.sh` | Tests de la partie 3.2 via l'Ingress : front, `config.js`, ajout/lecture/suppression, `/actuator` non publié |
| `scripts/pv-content.sh` | Récupération du contenu du PV (partie 3.3) |
| `ci/kind-config.yaml` | Cluster kind de la CI : un nœud, ports 80/443 publiés sur le runner |
| `.github/workflows/ci.yml` | Pipeline GitHub Actions |

Les mêmes scripts servent en local et en CI. Sur Docker Desktop :

```bash
scripts/deploy.sh          # INGRESS_PROVIDER=cloud par défaut
scripts/smoke-test.sh
```

### Pipeline `.github/workflows/ci.yml`

Déclenché à chaque push sur `main`, à chaque pull request, ou à la main (`workflow_dispatch`). Un seul job reproduit les étapes de l'examen :

1. **Build** : jar Spring Boot avec Java 17 (`./mvnw -B package -DskipTests`, cache Maven), puis les deux images avec les Dockerfiles du dépôt, sous les noms des manifests (`g4ss99/spring-app:1.0`, `g4ss99/angular-app:1.0`). Le cache des couches Docker est conservé entre deux exécutions.
2. **Cluster** : création d'un cluster Kubernetes éphémère **kind** sur le runner (après avoir déchargé le profil AppArmor `mysqld` du runner Ubuntu : il s'appliquerait aussi au MySQL du Pod et l'empêcherait de lire `/etc/my.cnf`), puis `kind load docker-image` des deux images. Grâce à `imagePullPolicy: IfNotPresent`, aucun registre n'est nécessaire.
3. **Déploiement** : `scripts/deploy.sh` avec `INGRESS_PROVIDER=kind`. Ce sont les mêmes manifests qu'en local ; seule change la variante du contrôleur ingress-nginx (hostPort 80 du nœud kind au lieu d'un LoadBalancer).
4. **Tests** : `scripts/smoke-test.sh` sur `http://localhost`.
5. **Persistance** : ajout d'une ligne, `kubectl rollout restart deploy/mysql`, puis vérification que la ligne est toujours dans le nouveau Pod. Les tests sont relancés ensuite pour vérifier que l'application se rétablit.
6. **Contenu du PV** : `scripts/pv-content.sh ls`, `dump` et `copy`. L'export SQL et le listing sont publiés comme artefact `pv-backup` (7 jours), téléchargeable depuis la page de l'exécution.
7. **Diagnostic** en cas d'échec : `kubectl get/describe`, événements, logs de Spring Boot, MySQL et ingress-nginx.
8. **Publication Docker Hub** : seulement sur un push vers `main`, une fois les tests passés, avec les tags `1.0` et `sha-<commit>`.

Secrets à créer dans **Settings → Secrets and variables → Actions** pour activer la publication (sans eux, cette étape est simplement ignorée) :

| Secret | Valeur |
|---|---|
| `DOCKERHUB_USERNAME` | `g4ss99` |
| `DOCKERHUB_TOKEN` | jeton d'accès Docker Hub (Account settings → Personal access tokens, droits *Read & Write*) |
