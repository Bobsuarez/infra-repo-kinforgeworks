# Infraestructura GitOps — k3s + ArgoCD

Repositorio de infraestructura declarativa para el despliegue de los proyectos
**Galfield's** y **Maestrías** sobre un clúster Kubernetes (k3s), gestionado
mediante GitOps con ArgoCD.

Este repo es la **fuente de verdad**: cualquier VPS que ejecute
`kubectl apply -f clusters/<nombre-cluster>/root-app.yaml` reconstruye el
clúster completo a partir de estos manifests. El objetivo es portabilidad
total entre proveedores (Contabo u otro) sin reconfiguración manual.

---

## Arquitectura

```
Cloudflare (DNS + proxy)
        │
        ▼
   k3s Ingress (Traefik)
   ├── galfields.kinforgeworks.com      → namespace: galfields
   │     ├── micro (pos-backend)          (público)
   │     ├── postgrest (PostgreSQL primary, aislado, interno)
   │     │     └── db-replica (solo lectura, streaming replication, interno)
   │     └── cdn-galfields.kinforgeworks.com → minio  (aislado, público)
   └── maestrias.kinforgeworks.com      → namespace: maestrias
         ├── web                          (público, / )
         ├── leads                        (público, /api — mismo Ingress que web)
         ├── leadsprocessor, leadsdelivery, worker, rabbitmq (internos)
         ├── postgrest (PostgreSQL primary, aislado, interno)
         └── cdn.kinforgeworks.com → minio (aislado, público)
```

> Dominio confirmado: `kinforgeworks.com`.

**Decisiones de diseño:**

| Decisión | Justificación |
|---|---|
| k3s (no Minikube) | Minikube es solo para desarrollo local; k3s es la distribución estándar de K8s para VPS/single-node en producción |
| Namespace por proyecto | Aislamiento lógico + `ResourceQuota`/`LimitRange` independientes, evita que un proyecto consuma los recursos del otro |
| MinIO y PostgreSQL duplicados por proyecto (no compartidos) | Aunque hoy corran en el mismo VPS, cada namespace tiene su propia instancia (PVC, credenciales, Service) para poder migrar un proyecto a otro servidor el día de mañana sin arrastrar storage/datos del otro |
| Traefik (incluido en k3s) | Reemplaza a Caddy como Ingress Controller, ruteo por subdominio nativo |
| ArgoCD "app of apps" vía `ApplicationSet` | Un `root-app.yaml` con generador de directorio sobre `apps/*` crea automáticamente una `Application` por carpeta; agregar un proyecto nuevo es solo agregar una carpeta en `apps/` y hacer push, sin tocar el root-app |
| Bootstrap del clúster vía GitHub Actions (SSH) | k3s y ArgoCD no pueden auto-instalarse por GitOps (aún no existe ArgoCD para reconciliar); un workflow SSH al VPS resuelve ese huevo-y-gallina. Se dispara en push a `bootstrap/**` o `clusters/**`, nunca para sincronizar cambios de `apps/` (eso lo hace ArgoCD solo) |
| Secrets fuera de Git en texto plano | Sealed Secrets (ver sección "Gestión de Secrets"). Todos los manifests ya referencian `secretRef` a Secrets que faltan sellar con valores reales |

---

## Estructura del repositorio

```
infra-repo-kinforgeworks/
├── .github/workflows/
│   └── bootstrap-cluster.yml      # SSH al VPS: k3s -> ArgoCD -> root-app (push a bootstrap/**, clusters/**)
├── bootstrap/
│   ├── 01-install-k3s.sh
│   ├── 02-install-argocd.sh       # incluye server.insecure=true (Ingress detrás de Traefik)
│   ├── 03-apply-root-app.sh
│   └── seal-secret.sh             # helper: wrapea kubeseal
├── clusters/
│   └── contabo-vps/
│       ├── root-app.yaml          # ArgoCD ApplicationSet ("app of apps" sobre apps/*)
│       ├── sealed-secrets-app.yaml # Application que instala el controller (namespace kube-system)
│       ├── sealed-secrets/
│       │   └── controller.yaml    # manifest oficial vendorizado (Bitnami, v0.38.4)
│       ├── argocd-ingress-app.yaml # Application que expone la UI de ArgoCD
│       └── argocd-ingress/
│           └── ingress.yaml       # argocd.kinforgeworks.com
├── apps/
│   ├── galfields/
│   │   ├── namespace.yaml
│   │   ├── resource-quota.yaml
│   │   ├── micro/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── ingress.yaml        # galfields.kinforgeworks.com
│   │   ├── minio/                  # instancia aislada (PVC + credenciales propias)
│   │   │   ├── statefulset.yaml
│   │   │   ├── pvc.yaml
│   │   │   ├── middleware.yaml     # Traefik: antepone el bucket a la ruta
│   │   │   └── ingress.yaml        # cdn-galfields.kinforgeworks.com
│   │   └── postgrest/              # PostgreSQL primary+réplica, sin Ingress (no es HTTP)
│   │       ├── statefulset.yaml               # db-primary
│   │       ├── pvc.yaml                       # db-primary-data
│   │       ├── init-schema-configmap.yaml     # stand-in de schema hasta que exista Flyway
│   │       ├── init-replication-configmap.yaml # 00_setup_replication.sh
│   │       ├── db-replica-statefulset.yaml    # streaming replication, solo lectura
│   │       ├── db-replica-pvc.yaml            # db-replica-data
│   │       └── backup-cronjob.yaml            # pg_dump -> Google Drive
│   └── maestrias/
│       ├── namespace.yaml
│       ├── resource-quota.yaml
│       ├── postgrest/              # PostgreSQL primary (StatefulSet), sin Ingress (no es HTTP)
│       │   ├── statefulset.yaml
│       │   └── pvc.yaml
│       ├── rabbitmq/               # broker interno, sin Ingress
│       ├── minio/                  # instancia aislada (PVC + credenciales propias)
│       │   ├── statefulset.yaml
│       │   ├── pvc.yaml
│       │   └── ingress.yaml        # cdn.kinforgeworks.com
│       ├── leads/                  # API REST (em-leads), sin Ingress propio (se rutea vía web/ingress.yaml)
│       ├── leadsprocessor/         # scheduler interno, sin Ingress
│       ├── leadsdelivery/          # consumer interno, sin Ingress
│       ├── worker/                 # ETL Python (leadsingestor), sin Service/Ingress
│       └── web/
│           ├── deployment.yaml
│           └── ingress.yaml        # maestrias.kinforgeworks.com  (/api -> leads, / -> web)
├── BOOTSTRAP_PROMPT.md
└── README.md
```

> Cada carpeta bajo `apps/` que no tiene `ingress.yaml` es intencionalmente interna
> (solo alcanzable dentro del namespace vía Service ClusterIP).

---

## Presupuesto de recursos (VPS real: 6 vCPU / ~12 GiB RAM)

| Componente | RAM estimada |
|---|---|
| k3s control plane | 0.5 – 0.7 GiB |
| ArgoCD | 0.5 – 0.8 GiB |
| Traefik | ~0.1 GiB |
| **Disponible para workloads** | **~10 GiB** |

Cada Deployment/StatefulSet en `apps/` debe declarar `resources.requests` y
`resources.limits` explícitos para evitar que un solo pod agote la memoria
del nodo.

**Importante sobre `limits.cpu` y el `ResourceQuota` por namespace:** la
suma de los `limits.cpu` de todos los Deployments/StatefulSets de un
namespace debe quedar **por debajo** del `limits.cpu` del `ResourceQuota`
de ese namespace, con margen — si no, el primer rolling update (que crea
un pod extra mientras el viejo todavía no se apaga) queda bloqueado con
`FailedCreate: exceeded quota` para siempre, aunque el `Deployment` ya
tenga la imagen/config correcta. Nos pasó exactamente esto en
`maestrias`: la suma de límites (5.25 CPU) superaba el propio
`limits.cpu: "5"` del `ResourceQuota`, incluso antes de intentar ningún
rollout. Con 6 vCPU compartidas entre `galfields`, `maestrias` y la
plataforma (ArgoCD, Traefik, sealed-secrets), la regla práctica es dejar
la suma de límites de cada namespace con margen de al menos ~30-40%
respecto a su cuota.

---

## Flujo de trabajo

1. Cualquier cambio de infraestructura se hace **en Git primero**, nunca
   directamente con `kubectl edit` sobre el clúster.
2. `git push` → ArgoCD detecta el cambio en `apps/` y sincroniza
   automáticamente (`syncPolicy.automated` con `prune` + `selfHeal` en el
   `ApplicationSet`). No se necesita ningún workflow de CI para esto.
3. Un push que toque `bootstrap/**` o `clusters/**` sí dispara CI:
   [`.github/workflows/bootstrap-cluster.yml`](.github/workflows/bootstrap-cluster.yml)
   se conecta por SSH al VPS (`secrets.SSH_HOST` / `vars.SSH_USER` /
   `secrets.SSH_KEY`, mismo Environment `works` que usa el repo de la app) y
   corre `01-install-k3s.sh` → `02-install-argocd.sh` → `03-apply-root-app.sh`.
   Los tres scripts son idempotentes: re-ejecutarlos contra un clúster ya
   provisionado no rompe nada.
4. Para migrar a un nuevo VPS: provisionar Ubuntu limpio, apuntar los
   secrets `SSH_HOST`/`SSH_KEY` al nuevo host, hacer un push trivial a
   `clusters/**` (o correr el workflow manualmente) y actualizar DNS en
   Cloudflare.

Ver [`BOOTSTRAP_PROMPT.md`](./BOOTSTRAP_PROMPT.md) para el procedimiento
manual equivalente asistido por Claude Code (útil para diagnosticar si el
workflow automático falla a mitad de camino).

### Acceder a la UI de ArgoCD

Una vez que sincronizó `clusters/contabo-vps/argocd-ingress-app.yaml`,
la UI queda disponible en **https://argocd.kinforgeworks.com** (usuario
`admin`, contraseña inicial impresa por `02-install-argocd.sh` — rotarla
con `argocd account update-password` en el primer login). Mientras el DNS
no esté creado, o para el primer acceso antes de que exista el Ingress, se
puede entrar por túnel SSH:

```bash
# en el VPS
kubectl -n argocd port-forward svc/argocd-server 8080:443
# en tu compu
ssh -L 8080:localhost:8080 usuario@vps
# abrir https://localhost:8080
```

Para el CLI de `argocd` contra el Ingress (que corre en modo `--insecure`,
HTTP plano puertas adentro), usar `--grpc-web`:
```bash
argocd login argocd.kinforgeworks.com --grpc-web
```

---

## Gestión de Secrets (Sealed Secrets)

Decisión tomada: **Sealed Secrets** (no SOPS) porque el resultado (un CR
`SealedSecret`) se commitea directo en `apps/` como cualquier otro manifest y
ArgoCD lo sincroniza igual que el resto — no hace falta ningún paso extra en
el pipeline para desencriptar.

- El controller se instala vía GitOps, no a mano: `03-apply-root-app.sh`
  aplica [`clusters/contabo-vps/sealed-secrets-app.yaml`](clusters/contabo-vps/sealed-secrets-app.yaml),
  una `Application` de ArgoCD que apunta al manifest vendorizado en
  [`clusters/contabo-vps/sealed-secrets/controller.yaml`](clusters/contabo-vps/sealed-secrets/controller.yaml)
  (namespace `kube-system`, igual que el default de Bitnami).
- Vive en `clusters/` y no en `apps/` porque es infraestructura de
  plataforma, no uno de los dos proyectos que descubre el `ApplicationSet`.
- Para generar un Secret cifrado: instalar `kubeseal` localmente, escribir el
  Secret en texto plano en un archivo que **no** se commitea, y correr:

  ```bash
  ./bootstrap/seal-secret.sh secret-plano.yaml apps/maestrias/leads/secret.sealed.yaml
  ```

  El archivo de salida sí es seguro de commitear; se coloca junto al
  Deployment que lo consume y se referencia con el mismo `secretRef` que ya
  usan los manifests de `apps/` (el `SealedSecret` genera un `Secret` normal
  con el mismo nombre/namespace declarado en su metadata).

### Caso especial: `ghcr-pull-secret` (pull de imágenes privadas)

Los paquetes de `ghcr.io/bobsuarez/kindredworks/*` son privados, así que
todo Deployment que jala de ahí necesita un `imagePullSecrets: - name:
ghcr-pull-secret` (ya está agregado en los manifests de `apps/`). Ese
Secret es del mismo tipo que cualquier otro para Sealed Secrets, solo que
`kubectl` lo genera con el formato `dockerconfigjson`. Hay que sellarlo
**una vez por namespace** (galfields y maestrias), con un Personal Access
Token de GHCR con scope `read:packages`:

```bash
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<tu-usuario-github> \
  --docker-password=<PAT con read:packages> \
  --namespace=maestrias \
  --dry-run=client -o yaml > ghcr-pull-secret-plain.yaml

./bootstrap/seal-secret.sh ghcr-pull-secret-plain.yaml apps/maestrias/ghcr-pull-secret.sealed.yaml
rm ghcr-pull-secret-plain.yaml   # no dejar el texto plano ni siquiera localmente

# repetir cambiando --namespace=galfields y la salida a apps/galfields/ghcr-pull-secret.sealed.yaml
```

### Caso especial: `maestrias-db-credentials` (compartido entre Postgres y 4 servicios)

`postgrest/statefulset.yaml` (el motor Postgres) y los Deployments de
`leads`, `leadsprocessor`, `leadsdelivery` y `worker` referencian el
**mismo** Secret `maestrias-db-credentials` — así los valores de usuario/
contraseña de la DB y de RabbitMQ viven en un solo lugar en vez de copias
que se pueden desincronizar.

**Importante — nombres de variable reales:** salieron de los
`application.yaml` reales de cada servicio (no del workflow viejo de
GitHub Actions, cuyos sufijos `_VARIABLE_GIT`/`_SECRET_GIT` eran solo el
nombre que usaba ese workflow para leer sus propios secrets/vars, no lo
que la app espera). Los servicios Java leen `DB_URL_PRIMARY`,
`DB_USER_PRIMARY`, `DB_PASSWORD_PRIMARY` (+ `DB_URL_REPLICA`/
`DB_USER_REPLICA`/`DB_PASSWORD_REPLICA` — `leads` los exige aunque no
haya réplica todavía, así que apuntan a la misma `db-primary` hasta que
se monte una real, ver Pendientes) y `RABBITMQ_HOST`/`RABBITMQ_PORT`/
`RABBITMQ_VHOST`/`RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD`. El worker
Python (`em-worker`) usa nombres **distintos** para lo mismo:
`DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/`DB_PASSWORD` y
`RABBITMQ_USER` (sin "NAME"). La URL JDBC apunta al Service de
Kubernetes `db-primary` (namespace `maestrias`), **no** a `em-db-primary`
(nombre de contenedor viejo de podman-compose, acá no existe).
`RABBITMQ_HOST`/`DB_HOST` apuntan a los Services `rabbitmq`/`db-primary`
del mismo namespace:

```bash
kubectl create secret generic maestrias-db-credentials \
  --from-literal=POSTGRES_DB=<nombre_db> \
  --from-literal=POSTGRES_USER=<usuario> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=DB_URL_PRIMARY='jdbc:postgresql://db-primary:5432/<nombre_db>' \
  --from-literal=DB_USER_PRIMARY=<usuario> \
  --from-literal=DB_PASSWORD_PRIMARY=<password> \
  --from-literal=DB_URL_REPLICA='jdbc:postgresql://db-primary:5432/<nombre_db>' \
  --from-literal=DB_USER_REPLICA=<usuario> \
  --from-literal=DB_PASSWORD_REPLICA=<password> \
  --from-literal=DB_HOST=db-primary \
  --from-literal=DB_PORT=5432 \
  --from-literal=DB_NAME=<nombre_db> \
  --from-literal=DB_USER=<usuario> \
  --from-literal=DB_PASSWORD=<password> \
  --from-literal=RABBITMQ_HOST=rabbitmq \
  --from-literal=RABBITMQ_PORT=5672 \
  --from-literal=RABBITMQ_VHOST=/ \
  --from-literal=RABBITMQ_USERNAME=<usuario_rabbitmq> \
  --from-literal=RABBITMQ_PASSWORD=<password_rabbitmq> \
  --from-literal=RABBITMQ_USER=<usuario_rabbitmq> \
  --namespace=maestrias \
  --dry-run=client -o yaml > db-credentials-plain.yaml

./bootstrap/seal-secret.sh db-credentials-plain.yaml apps/maestrias/db-credentials.sealed.yaml
rm db-credentials-plain.yaml
```

Estos mismos `RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD` deben coincidir con
los que use el propio broker (`maestrias-rabbitmq-secrets`, con
`RABBITMQ_DEFAULT_USER`/`RABBITMQ_DEFAULT_PASS`):

```bash
kubectl create secret generic maestrias-rabbitmq-secrets \
  --from-literal=RABBITMQ_DEFAULT_USER=<usuario_rabbitmq> \
  --from-literal=RABBITMQ_DEFAULT_PASS=<password_rabbitmq> \
  --namespace=maestrias \
  --dry-run=client -o yaml > rabbitmq-secrets-plain.yaml

./bootstrap/seal-secret.sh rabbitmq-secrets-plain.yaml apps/maestrias/rabbitmq/rabbitmq-secrets.sealed.yaml
rm rabbitmq-secrets-plain.yaml
```

`leadsdelivery` además necesita su propio secret aparte con lo único
genuinamente sensible que le queda (el resto — URL de whatsapp-gateway,
nombre de cola — ya son variables planas en su Deployment, no secretas):

```bash
kubectl create secret generic maestrias-leadsdelivery-secrets \
  --from-literal=MAIL_HOST=<host_smtp> \
  --from-literal=MAIL_PORT=<puerto_smtp> \
  --from-literal=MAIL_USERNAME=<usuario_smtp> \
  --from-literal=MAIL_PASSWORD=<password_smtp> \
  --from-literal=MAIL_FROM_ADDRESS=<direccion_remitente> \
  --from-literal=MAIL_FROM_NAME=<nombre_remitente> \
  --namespace=maestrias \
  --dry-run=client -o yaml > leadsdelivery-secrets-plain.yaml

./bootstrap/seal-secret.sh leadsdelivery-secrets-plain.yaml apps/maestrias/leadsdelivery/leadsdelivery-secrets.sealed.yaml
rm leadsdelivery-secrets-plain.yaml
```

`leads` ya no tiene secret propio: lo único que necesitaba además de la
DB (`EM_LEADS_PROCESSOR_GATEWAY_URL`, `GOOGLE_CLIENT_ID`) no es sensible,
así que quedó como variables de entorno planas directo en su Deployment.

### Caso especial: `galfields-db-credentials` y `galfields-minio-secrets`

Mismo patrón que en `maestrias`: `postgrest/statefulset.yaml` (Postgres) y
`micro/deployment.yaml` (`pos-backend`) comparten `galfields-db-credentials`.
Los nombres de variable salen de `application.properties` real de
`pos-backend` — `DB_HOST` apunta al Service `db-primary` del namespace
`galfields`:

```bash
kubectl create secret generic galfields-db-credentials \
  --from-literal=POSTGRES_DB=<nombre_db> \
  --from-literal=POSTGRES_USER=<usuario> \
  --from-literal=POSTGRES_PASSWORD=<password> \
  --from-literal=DB_HOST=db-primary \
  --from-literal=DB_PORT=5432 \
  --from-literal=DB_NAME=<nombre_db> \
  --from-literal=DB_USERNAME=<usuario> \
  --from-literal=DB_PASSWORD=<password> \
  --namespace=galfields \
  --dry-run=client -o yaml > galfields-db-credentials-plain.yaml

./bootstrap/seal-secret.sh galfields-db-credentials-plain.yaml apps/galfields/postgrest/db-credentials.sealed.yaml
rm galfields-db-credentials-plain.yaml
```

`MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY` que usa `pos-backend` son, en la
práctica, el mismo usuario/password root del propio MinIO — por eso van
en el mismo Secret que consume el `StatefulSet` de MinIO:

```bash
kubectl create secret generic galfields-minio-secrets \
  --from-literal=MINIO_ROOT_USER=<usuario_minio> \
  --from-literal=MINIO_ROOT_PASSWORD=<password_minio> \
  --from-literal=MINIO_ACCESS_KEY=<usuario_minio> \
  --from-literal=MINIO_SECRET_KEY=<password_minio> \
  --namespace=galfields \
  --dry-run=client -o yaml > galfields-minio-secrets-plain.yaml

./bootstrap/seal-secret.sh galfields-minio-secrets-plain.yaml apps/galfields/minio/minio-secrets.sealed.yaml
rm galfields-minio-secrets-plain.yaml
```

### Caso especial: `galfields-replication-secret` (usuario `replicator` de `db-replica`)

Secret dedicado y separado de `galfields-db-credentials` a propósito: es
la contraseña del rol `replicator` que crea `init-replication-configmap.yaml`
en `db-primary` (no un usuario de aplicación), y la consume `db-replica`
como `PGPASSWORD` para autenticar `pg_basebackup`. Ver sección "Réplica de
solo lectura de PostgreSQL".

```bash
kubectl create secret generic galfields-replication-secret \
  --from-literal=REPLICATOR_PASSWORD=<password> \
  --namespace=galfields \
  --dry-run=client -o yaml > galfields-replication-secret-plain.yaml

./bootstrap/seal-secret.sh galfields-replication-secret-plain.yaml apps/galfields/postgrest/replication-secret.sealed.yaml
rm galfields-replication-secret-plain.yaml
```

### Caso especial: `galfields-backup-rclone-config` (backup externo a Google Drive)

A diferencia de los demás secrets, este no se arma con `--from-literal`:
contiene un `rclone.conf` con un token OAuth de Google Drive que solo se
puede generar autorizando por navegador. **Se genera en tu compu, nunca
en el VPS ni pegado en un chat**:

```bash
rclone config
# crear un remote llamado "gdrive", tipo "drive" (Google Drive)
# scope recomendado: drive.file (solo archivos creados por esta app,
# no acceso a todo el Drive del usuario)
# autorizar por navegador cuando lo pida

kubectl create secret generic galfields-backup-rclone-config \
  --from-file=rclone.conf=$HOME/.config/rclone/rclone.conf \
  --namespace=galfields \
  --dry-run=client -o yaml > rclone-secret-plain.yaml

./bootstrap/seal-secret.sh rclone-secret-plain.yaml apps/galfields/postgrest/backup-rclone-config.sealed.yaml
rm rclone-secret-plain.yaml
```

El remote debe llamarse exactamente `gdrive` (nombre que usa
`backup-cronjob.yaml` al invocar `rclone copy`/`rclone delete`).

---

## Backups de PostgreSQL (`galfields`)

`db-primary` corre en un solo pod sobre un PVC del mismo VPS — igual que
el MinIO del namespace. Ninguno de los dos sobrevive a la pérdida del VPS,
así que `apps/galfields/postgrest/backup-cronjob.yaml` saca copias fuera
del cluster:

- **Cuándo:** `CronJob` a las 12:00pm y 9:00pm hora `America/Bogota`
  (`schedule: "0 12,21 * * *"`, `timeZone: America/Bogota`).
- **Cómo:** un `initContainer` corre `pg_dump | gzip` contra el Service
  `db-primary` usando el mismo Secret `galfields-db-credentials` del
  StatefulSet, y un container `rclone/rclone` sube el archivo a
  `gdrive:galfields-backups/`.
- **Retención:** 30 días (`rclone delete --min-age 30d` al final de cada
  corrida).
- **Requiere:** el Secret `galfields-backup-rclone-config` — ver la
  sección "Caso especial" arriba, hay que generarlo manualmente antes de
  que el primer `CronJob` corra exitosamente.

**Restaurar un backup:**
```bash
gunzip -c galfields-YYYYMMDD-HHMMSS.sql.gz | \
  kubectl exec -i -n galfields db-primary-0 -- psql -U $POSTGRES_USER -d $POSTGRES_DB
```

**Probar sin esperar al cron:**
```bash
kubectl create job --from=cronjob/galfields-db-backup manual-test-1 -n galfields
kubectl logs -n galfields job/manual-test-1 -c pg-dump
kubectl logs -n galfields job/manual-test-1 -c upload
```

---

## Réplica de solo lectura de PostgreSQL (`galfields`)

`db-replica` es una réplica de streaming (WAL) de `db-primary`, traducida
del servicio `em-db-replica` de `compose.yaml` (repo de `pos-backend`).
Igual que `db-primary`, es un `StatefulSet` interno sin `Ingress` — solo
alcanzable dentro del namespace `galfields`.

**Cómo se sincroniza:** en su primer arranque (PVC `db-replica-data`
vacío), el contenedor corre `pg_basebackup` contra el Service
`db-primary`, autenticado como el usuario `replicator` (creado por
`init-replication-configmap.yaml`, que corre en `db-primary` antes que el
schema). El flag `-R` de `pg_basebackup` deja el `standby.signal` +
`primary_conninfo` ya configurados, así que en arranques siguientes el
contenedor detecta que `PGDATA` ya existe y se salta directo a
`exec postgres` — nunca vuelve a clonar mientras no se borre el PVC.

**Conexión desde una app dentro de `galfields`** (ej. `pos-backend`, para
enrutar lecturas ahí en vez de a `db-primary`):

```
host: db-replica.galfields.svc.cluster.local   # o solo "db-replica" dentro del mismo namespace
port: 5432
user/password/db: los mismos DB_USERNAME/DB_PASSWORD/DB_NAME de
                   galfields-db-credentials (la réplica comparte el mismo
                   rol de aplicación que el primario, solo el usuario
                   "replicator" es exclusivo de la replicación en sí)
```

> **Pendiente, del lado de la app, no de infra:** `pos-backend` necesita
> soportar dos `DataSource` (uno para escrituras a `db-primary`, otro de
> solo lectura a `db-replica`) para aprovechar esto — hoy no sabemos si
> `application.properties` ya tiene esa distinción (a diferencia de
> `maestrias`/`leads`, que sí declara `DB_URL_REPLICA` explícito). Sin ese
> cambio en el código de `pos-backend`, la réplica queda sincronizada y
> lista, pero nada la consulta todavía.

**Verificar que la replicación está al día:**
```bash
# en db-primary: WAL enviado vs. confirmado por la réplica (debería ser ~0 de diferencia)
kubectl exec -n galfields db-primary-0 -- psql -U $POSTGRES_USER -c \
  "SELECT client_addr, state, sent_lsn, replay_lsn, replay_lsn - sent_lsn AS lag_bytes FROM pg_stat_replication;"

# en db-replica: confirma que está en modo standby y el timestamp del último WAL aplicado
kubectl exec -n galfields db-replica-0 -- psql -U $POSTGRES_USER -c \
  "SELECT pg_is_in_recovery(), pg_last_xact_replay_timestamp();"
```

**Failover manual** (si `db-primary` se pierde, para promover la réplica a
primario — no hay failover automático, esto es una réplica de lectura,
no un cluster de alta disponibilidad):
```bash
kubectl exec -n galfields db-replica-0 -- pg_ctl promote -D /var/lib/postgresql/data
```
Después de promoverla hay que repuntar `DB_HOST` en `galfields-db-credentials`
hacia `db-replica` (o renombrar Services) y levantar una réplica nueva
desde cero si se quiere recuperar el nivel de redundancia.

---

## Pendientes / próximos pasos

- [x] Definir gestión de Secrets — Sealed Secrets (controller vía GitOps en
      `clusters/contabo-vps/sealed-secrets-app.yaml`, helper
      `bootstrap/seal-secret.sh`)
- [x] Sellar `maestrias-db-credentials` (DB + RabbitMQ compartidos por
      postgrest, leads, leadsprocessor, leadsdelivery y worker, con los
      nombres reales de `application.yaml`, no los del workflow viejo)
- [x] Corregir puertos internos de leads/leadsprocessor/leadsdelivery a
      8080 (el `server.port` real de Spring; 8085/8081/8082 eran puertos
      de host de podman-compose, no del contenedor)
- [x] Sellar `maestrias-rabbitmq-secrets` (`RABBITMQ_DEFAULT_USER/PASS`)
- [x] Sellar `maestrias-leadsdelivery-secrets` (`MAIL_*`)
- [x] `web` no necesita secret propio — `PUBLIC_API_URL`/`PUBLIC_GOOGLE_CLIENT_ID`
      son variables de build-time de Astro (horneadas en la imagen), no de
      runtime; se eliminó el `secretRef: maestrias-web-secrets`
- [x] `whatsapp-gateway` removido de `apps/maestrias/` (deshabilitado por
      ahora); `WHATSAPP_GATEWAY_URL` en `leadsdelivery` queda apuntando a un
      Service que no existe a propósito — solo falla el envío puntual por
      WhatsApp, no el arranque del pod
- [x] Sellar `maestrias-minio-secrets`
- [ ] Si el usuario/password de `maestrias-minio-secrets` no es
      `minioadmin`/`minioadmin`, agregar `MINIO_ACCESS_KEY`/`MINIO_SECRET_KEY`
      con el valor real al secret de `leads` (hoy usa esos defaults)
- [ ] Sellar los Secrets que faltan de `galfields` (`galfields-*`)
- [x] Confirmar el dominio real por proyecto — `kinforgeworks.com`
      (`galfields.kinforgeworks.com`, `maestrias.kinforgeworks.com`,
      `cdn.kinforgeworks.com`, `cdn-galfields.kinforgeworks.com`,
      `api.galfields.kinforgeworks.com`)
- [ ] Crear en Cloudflare los registros DNS para los subdominios de arriba
      **+ `argocd.kinforgeworks.com`** apuntando a la IP del VPS (Traefik) —
      hoy solo existen, si acaso, `kinforgeworks.com` y los que ya usaba el
      stack viejo (`n8n.`, `cdn.`)
- [ ] Si `infra-repo-kinforgeworks` es privado, crear el secret
      `ARGOCD_REPO_TOKEN` (PAT de solo lectura) en el Environment `works`;
      sin él, `03-apply-root-app.sh` asume repo público y el
      `ApplicationSet` no podrá clonarlo
- [x] Corregir las rutas de imagen de maestrias al namespace real
      `ghcr.io/bobsuarez/kindredworks/em-*` (antes apuntaban a
      `ghcr.io/bobsuarez/em-*`, sin `kindredworks/`)
- [x] Confirmar si el pipeline de KindredWorks publica un tag flotante —
      confirmado en GHCR que `:latest` existe junto al `sha-<corto>` para
      `em-leads-processor`; asumimos que aplica igual al resto (mismo
      pipeline), pendiente de verificar en los otros 5 paquetes si algo
      sigue en `ImagePullBackOff` después de sellar el pull secret
- [x] Sellar `ghcr-pull-secret` en `galfields` y `maestrias`
- [x] Renombrar `galfiends`→`galfields` en todo el repo (typo del nombre
      real de la empresa, "Galfield's") y re-sellar `ghcr-pull-secret` para
      el namespace nuevo (Sealed Secrets ata el cifrado a namespace+nombre,
      el que existía para `galfiends` quedó inválido)
- [x] `apps/galfields/micro` es el servicio real `pos-backend`
      (`ghcr.io/bobsuarez/galfields/pos-backend`), imagen pública, aún no
      probado en su totalidad
- [x] `apps/galfields/postgrest/` pasó a ser Postgres puro (como
      `maestrias/postgrest/`), con su propio `StatefulSet`+`PVC` en vez del
      Deployment de PostgREST que apuntaba a una DB inexistente
- [x] Sellar `galfields-db-credentials` (POSTGRES_*+DB_* compartido entre
      `postgrest` y `micro`) y `galfields-minio-secrets`
      (`MINIO_ROOT_USER/PASSWORD` + `MINIO_ACCESS_KEY/SECRET_KEY`, mismo
      valor)
- [ ] Actualizar en Cloudflare los registros DNS de `galfiends.*` a
      `galfields.*` (fuera de este repo, acción manual pendiente)
- [x] `apps/galfields/postgrest` alineado a `postgres:15-alpine` (no 16),
      para coincidir con la versión ya probada en el `compose.yaml` de
      `pos-backend` y ser compatible con streaming replication el día que
      se agregue la réplica
- [x] Schema inicial de `galfields` traducido de MySQL a Postgres y
      montado como `ConfigMap` en `/docker-entrypoint-initdb.d/`
      (`apps/galfields/postgrest/init-schema-configmap.yaml`) — es un
      stand-in para poder probar `pos-backend` ya, **no reemplaza
      migraciones Flyway reales**. Requiere borrar el PVC existente para
      que se re-inicialice y el script corra (solo corre en un volumen
      vacío)
- [ ] **Pendiente de la app, no de infra**: cuando `pos-backend` tenga
      migraciones Flyway reales en `src/main/resources/db/migration`
      (sintaxis Postgres), borrar `init-schema-configmap.yaml` y el PVC de
      `galfields` para que Flyway quede como única fuente de verdad del
      schema, sin conflictos con el stand-in
- [x] Agregar la réplica de solo lectura de `galfields` (`db-replica`,
      streaming replication desde `db-primary`) — ver sección "Réplica de
      solo lectura de PostgreSQL". `00_setup_replication.sh` portado a
      `init-replication-configmap.yaml`, contraseña de `replicator`
      parametrizada vía `galfields-replication-secret` (Sealed Secret,
      pendiente sellar con valor real — ver "Gestión de Secrets")
- [ ] `pos-backend` no tiene (que sepamos) un segundo `DataSource` de solo
      lectura — la réplica de `galfields` está lista y sincronizada pero
      nada la consulta todavía; requiere cambio en el código de la app,
      fuera de este repo
- [ ] Agregar la réplica de solo lectura (`em-db-replica`) en
      `apps/maestrias/postgrest/` una vez definida la estrategia de
      streaming replication (mismo patrón que se acaba de aplicar en
      `galfields`, ver sección "Réplica de solo lectura de PostgreSQL")
- [ ] Sellar `galfields-backup-rclone-config` (requiere autorizar rclone
      con Google Drive localmente y correr `seal-secret.sh` — ver sección
      "Backups de PostgreSQL"); hasta entonces `backup-cronjob.yaml` está
      aplicado pero el container `upload` va a fallar por falta del Secret
- [ ] Configurar `cert-manager` si se requiere TLS end-to-end (fuera del
      modo "Full" de Cloudflare)
- [ ] Definir política de sync de ArgoCD (automática vs manual) por ambiente
- [ ] Agregar `metrics-server` para observabilidad básica (ya incluido en k3s)
