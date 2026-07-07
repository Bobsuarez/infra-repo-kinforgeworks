# Infraestructura GitOps — k3s + ArgoCD

Repositorio de infraestructura declarativa para el despliegue de los proyectos
**Galfiends** y **Maestrías** sobre un clúster Kubernetes (k3s), gestionado
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
   ├── galfiends.kinforgeworks.com      → namespace: galfiends
   │     ├── micro                        (público)
   │     ├── cdn.galfiends.kinforgeworks.com → minio  (aislado, público)
   │     └── api.galfiends.kinforgeworks.com → postgrest (aislado, público)
   └── maestrias.kinforgeworks.com      → namespace: maestrias
         ├── web                          (público, / )
         ├── leads                        (público, /api — mismo Ingress que web)
         ├── leadsprocessor, leadsdelivery, worker, whatsapp-gateway, rabbitmq (internos)
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
│   ├── 02-install-argocd.sh
│   └── 03-apply-root-app.sh
├── clusters/
│   └── contabo-vps/
│       ├── root-app.yaml          # ArgoCD ApplicationSet ("app of apps" sobre apps/*)
│       ├── sealed-secrets-app.yaml # Application que instala el controller (namespace kube-system)
│       └── sealed-secrets/
│           └── controller.yaml    # manifest oficial vendorizado (Bitnami, v0.38.4)
├── apps/
│   ├── galfiends/
│   │   ├── namespace.yaml
│   │   ├── resource-quota.yaml
│   │   ├── micro/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── ingress.yaml        # galfiends.kinforgeworks.com
│   │   ├── minio/                  # instancia aislada (PVC + credenciales propias)
│   │   │   ├── statefulset.yaml
│   │   │   ├── pvc.yaml
│   │   │   └── ingress.yaml        # cdn.galfiends.kinforgeworks.com
│   │   └── postgrest/              # API PostgREST pública (sin DB propia todavía, ver Pendientes)
│   │       ├── deployment.yaml
│   │       └── ingress.yaml        # api.galfiends.kinforgeworks.com
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
│       ├── whatsapp-gateway/       # gateway interno, sin Ingress
│       └── web/
│           ├── deployment.yaml
│           └── ingress.yaml        # maestrias.kinforgeworks.com  (/api -> leads, / -> web)
├── BOOTSTRAP_PROMPT.md
└── README.md
```

> Cada carpeta bajo `apps/` que no tiene `ingress.yaml` es intencionalmente interna
> (solo alcanzable dentro del namespace vía Service ClusterIP).

---

## Presupuesto de recursos (VPS 12 GiB RAM)

| Componente | RAM estimada |
|---|---|
| k3s control plane | 0.5 – 0.7 GiB |
| ArgoCD | 0.5 – 0.8 GiB |
| Traefik | ~0.1 GiB |
| **Disponible para workloads** | **~10 GiB** |

Cada Deployment/StatefulSet en `apps/` debe declarar `resources.requests` y
`resources.limits` explícitos para evitar que un solo pod agote la memoria
del nodo.

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

---

## Pendientes / próximos pasos

- [x] Definir gestión de Secrets — Sealed Secrets (controller vía GitOps en
      `clusters/contabo-vps/sealed-secrets-app.yaml`, helper
      `bootstrap/seal-secret.sh`)
- [ ] Sellar y commitear los `SealedSecret` reales de cada servicio (DB,
      MinIO, RabbitMQ, mail, WhatsApp) — hoy los `secretRef` de `apps/`
      apuntan a Secrets que todavía no existen en el clúster
- [x] Confirmar el dominio real por proyecto — `kinforgeworks.com`
      (`galfiends.kinforgeworks.com`, `maestrias.kinforgeworks.com`,
      `cdn.kinforgeworks.com`, `cdn.galfiends.kinforgeworks.com`,
      `api.galfiends.kinforgeworks.com`)
- [ ] Crear en Cloudflare los registros DNS para los subdominios de arriba
      apuntando a la IP del VPS (Traefik) — hoy solo existen, si acaso,
      `kinforgeworks.com` y los que ya usaba el stack viejo (`n8n.`, `cdn.`)
- [ ] Si `infra-repo-kinforgeworks` es privado, crear el secret
      `ARGOCD_REPO_TOKEN` (PAT de solo lectura) en el Environment `works`;
      sin él, `03-apply-root-app.sh` asume repo público y el
      `ApplicationSet` no podrá clonarlo
- [ ] Reemplazar las imágenes placeholder `ghcr.io/bobsuarez/...:latest`
      por las rutas reales una vez exista el build/push a GHCR de cada
      servicio
- [ ] Dar a `apps/galfiends/postgrest/` una base PostgreSQL propia (hoy
      solo tiene el deployment de PostgREST, apunta a una DB que aún no
      existe en el namespace)
- [ ] Agregar la réplica de solo lectura (`em-db-replica`) en
      `apps/maestrias/postgrest/` una vez definida la estrategia de
      streaming replication
- [ ] Configurar `cert-manager` si se requiere TLS end-to-end (fuera del
      modo "Full" de Cloudflare)
- [ ] Definir política de sync de ArgoCD (automática vs manual) por ambiente
- [ ] Agregar `metrics-server` para observabilidad básica (ya incluido en k3s)
