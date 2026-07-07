# Bootstrap de infraestructura — k3s + ArgoCD

Procedimiento de instalación asistida por **Claude Code** para levantar el
clúster en un VPS nuevo o migrar desde uno existente, usando este repositorio
como fuente de verdad (GitOps).

---

## Requisitos previos

- VPS con Ubuntu (22.04 o superior) y acceso SSH
- Mínimo 8 GiB RAM recomendado (probado con 12 GiB)
- Dominio gestionado en Cloudflare, con capacidad de editar registros DNS
- Claude Code instalado localmente, con acceso SSH configurado al VPS
- Este repositorio clonado (local o accesible desde el VPS)

---

## Uso

1. Reemplaza `[IP_O_HOST]`, `[USUARIO]` y `[DOMINIO]` en el prompt de abajo.
2. Pega el prompt completo en Claude Code.
3. Supervisa cada paso — el prompt está diseñado para pedir confirmación
   antes de operaciones destructivas y para detenerse ante errores en vez
   de improvisar fixes no versionados en Git.

---

## Prompt

```markdown
# Bootstrap de infraestructura k3s + ArgoCD

## Contexto
Tengo un VPS Ubuntu recién provisionado (o uno existente a migrar) y un repo Git
con toda la infraestructura declarativa en `apps/` siguiendo el patrón GitOps
"app of apps" de ArgoCD. El objetivo es dejar el clúster funcionando de forma
idéntica a la definición en Git, sin intervención manual más allá de lo que
listo abajo.

## Tarea
Conéctate por SSH a [IP_O_HOST] con el usuario [USUARIO] y ejecuta lo siguiente,
verificando el resultado de cada paso antes de continuar al siguiente:

1. **Pre-requisitos**
   - Verifica versión de Ubuntu, RAM disponible (`free -h`), y que los puertos
     6443, 80, 443 estén libres.
   - Actualiza paquetes del sistema.

2. **Instalación de k3s**
   - Ejecuta `bootstrap/01-install-k3s.sh` del repo (o instala k3s con
     `curl -sfL https://get.k3s.io | sh -` si el script no existe aún).
   - Verifica que el nodo esté `Ready` con `kubectl get nodes`.
   - Copia el kubeconfig a una ubicación accesible y ajusta permisos.

3. **Instalación de ArgoCD**
   - Ejecuta `bootstrap/02-install-argocd.sh`.
   - Espera a que todos los pods del namespace `argocd` estén `Running`.
   - Recupera la contraseña inicial de admin y muéstramela.

4. **Aplicar el "root app"**
   - Ejecuta `kubectl apply -f clusters/contabo-vps/root-app.yaml`.
   - Verifica en `argocd app list` que las aplicaciones hijas (galfields,
     maestrias) aparezcan y comiencen a sincronizar.
   - Si alguna app queda en estado `Degraded` o `OutOfSync` por más de 2
     minutos, diagnostica con `kubectl describe` / `argocd app get <app>` y
     repórtame el error antes de intentar un fix automático.

5. **Validación de ruteo**
   - Confirma que Traefik (Ingress) tenga IP/puerto expuesto correctamente
     (`kubectl get svc -n kube-system traefik`).
   - Lista los Ingress creados y verifica que los hosts coincidan con los
     subdominios esperados: galfields.[DOMINIO], maestrias.[DOMINIO].

6. **Reporte final**
   Al terminar, dame un resumen con:
   - Estado de cada namespace y sus pods
   - IP pública para apuntar los DNS de Cloudflare
   - Credenciales de ArgoCD (admin)
   - Cualquier paso manual pendiente (ej. secrets no versionados en Git,
     configuración de TLS)

## Restricciones
- No hagas cambios directamente en el clúster que no estén reflejados en Git
  primero (esto rompe el modelo GitOps). Si algo requiere un ajuste, edita el
  manifest correspondiente en el repo, haz commit/push, y deja que ArgoCD
  sincronice.
- Los Secrets (credenciales de DB, API keys) NO deben commitearse en texto
  plano. Si encuentras alguno pendiente, avísame y usamos
  `kubectl create secret` manual o sealed-secrets, según lo que definamos.
- Pregúntame antes de cualquier operación destructiva (`kubectl delete ns`,
  `helm uninstall`, etc.).
```

---

## Checklist post-bootstrap

- [ ] Nodo k3s en estado `Ready`
- [ ] Pods de `argocd` namespace en `Running`
- [ ] Todas las `Application` de ArgoCD en `Synced` / `Healthy`
- [ ] IP pública del VPS apuntada en Cloudflare para ambos subdominios
- [ ] Contraseña de admin de ArgoCD rotada (la inicial es temporal)
- [ ] Secrets pendientes gestionados fuera de texto plano

## Notas

- Los scripts en `bootstrap/` deben ser idempotentes (`kubectl apply`, no
  `create`; checks de "si ya existe, salta") para poder re-ejecutarse sin
  romper un clúster ya provisionado.
- El único paso verdaderamente manual al migrar de VPS es actualizar los
  registros DNS en Cloudflare — el resto es reproducible desde este repo.
