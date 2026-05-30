# Banka-3-Infrastructure

Kubernetes manifests for [Banka-3-Backend] + [Banka-3-Frontend], deployed
into the [ykube] cluster via Argo CD.

[Banka-3-Backend]: https://github.com/RAF-SI-2025/Banka-3-Backend
[Banka-3-Frontend]: https://github.com/RAF-SI-2025/Banka-3-Frontend
[ykube]: https://github.com/urosevicvuk/ykube

## How it wires up

ykube's `apps/raf/banka/kustomization.yaml` references this repo as a
kustomize remote base. The `raf` ApplicationSet renders the result into
an Argo Application `raf-banka` deployed into namespace `raf-banka`.

```
ykube apps/raf/banka/kustomization.yaml
  └─> https://github.com/RAF-SI-2025/Banka-3-Infrastructure//?ref=main
       └─> kustomization.yaml (this repo)
            ├─ namespace.yaml         — ns + quota + limit-range + netpol
            ├─ secrets.yaml           — ExternalSecrets from Vault
            ├─ postgres/cluster.yaml  — CNPG cluster `banka-pg`
            ├─ redis/redis.yaml       — single-replica Redis
            ├─ migrate/job.yaml       — Argo PreSync hook
            ├─ services/<svc>.yaml    — 6 Deployments + Services (gRPC)
            ├─ frontend/frontend.yaml — Vite SPA (nginx)
            └─ httproute.yaml         — banka.raf-project.com routing
```

All 6 backend services and the frontend run as 1 replica. Inter-service
traffic is gRPC over the cluster network; the gateway is the only public
surface.

## Required manual setup

### 1. Vault keys

The 5 ExternalSecrets in `secrets.yaml` expect these paths in Vault
(kv-v2 engine mounted at `kv/`):

```sh
# Auth secrets — JWT signing key + CVV pepper
vault kv put kv/raf-banka/auth \
  jwt-signing-key="$(openssl rand -base64 48)" \
  cvv-pepper="$(openssl rand -base64 32)"

# SMTP — leave empty values if you want stdout-only email
vault kv put kv/raf-banka/smtp \
  host=smtp.gmail.com port=587 \
  username=... password=... \
  from=no-reply@banka.raf-project.com tls=true

# Inter-bank shared secret (X-Api-Key header, both directions)
vault kv put kv/raf-banka/interbank \
  api-key="$(openssl rand -base64 32)"

# AlphaVantage market-data key (optional — get one at
# https://www.alphavantage.co/support/#api-key). When empty, trading
# service skips the price-refresh cron.
vault kv put kv/raf-banka/alphavantage \
  api-key=<key-or-empty>

# Harbor pull credentials
# 1. In Harbor UI: create project `raf-banka3` (public OR with a robot
#    account scoped to `pull` on raf-banka3/*)
# 2. Build a dockerconfig:
#      docker login registry.urosevicvuk.dev -u <robot-name> -p <token>
#      # writes ~/.docker/config.json
#      cp ~/.docker/config.json /tmp/dockerconfig.json
# 3. Push to Vault:
vault kv put kv/raf-banka/registry-creds \
  .dockerconfigjson=@/tmp/dockerconfig.json
```

### 2. GitHub Actions secrets (per repo)

Both `Banka-3-Backend` and `Banka-3-Frontend` need:

- `HARBOR_USERNAME` — robot account with push on `raf-banka3/*`
- `HARBOR_PASSWORD` — robot token

### 3. DNS

Nothing to do — external-dns watches HTTPRoute resources and publishes
the CNAME for `banka.raf-project.com` to Cloudflare automatically. The
cloudflared tunnel already routes the `*.raf-project.com` wildcard into
envoy-external (see `ykube apps/system/networking/cloudflared/`), so the
new hostname rides the existing wildcard rule without a config edit.

### 4. First-time image push

The Argo Application will be stuck `ImagePullBackOff` until each image
exists in Harbor. Either:

- Push to main in both repos (CI builds + pushes), or
- Build locally and push:

  ```sh
  cd ../Banka-3-Backend
  for svc in user bank trading exchange notification gateway; do
    docker build -f docker/Dockerfile --build-arg SERVICE=$svc \
      -t registry.urosevicvuk.dev/raf-banka3/$svc:main .
    docker push registry.urosevicvuk.dev/raf-banka3/$svc:main
  done
  docker build -f docker/Dockerfile.migrate \
    -t registry.urosevicvuk.dev/raf-banka3/migrate:main .
  docker push registry.urosevicvuk.dev/raf-banka3/migrate:main

  cd ../Banka-3-Frontend
  docker build -t registry.urosevicvuk.dev/raf-banka3/frontend:main .
  docker push registry.urosevicvuk.dev/raf-banka3/frontend:main
  ```

## Operational notes

- **Migrations**: a single PreSync Job (`migrate/job.yaml`) walks the 5
  schemas in dependency order (user → exchange → bank → notification →
  trading). Idempotent: golang-migrate skips applied versions.
- **DB connection**: services read `DATABASE_URL` from CNPG's
  auto-generated `banka-pg-app` secret (key `uri`). No password
  juggling — CNPG rotates the role password and ESO-mirrors are not
  needed.
- **Redis**: single replica, AOF persistence on a 1Gi PVC. No password
  (cluster-internal, NetworkPolicy restricts ingress to the namespace).
- **Image tag**: every Deployment pins `:main`. CI tags both `:main`
  and `:<git-sha>`; switch the manifests to a pinned SHA when you want
  reproducibility, or wire up argocd-image-updater later.
- **Tenant guardrails**: ResourceQuota + LimitRange + CiliumNetworkPolicy
  default-deny mirror the morel tenant baseline in ykube.

## Why one Argo Application (not one per service)

The 6 backend services share generated proto contracts — gateway and
trading drift in lockstep with bank/user. A single Application makes
every release atomic; ApplicationSet-per-service would let services sync
out of sync with the contract their peers expect. If a service ever
needs its own release cadence, split it then.
