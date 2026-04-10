# Container Registry

Simple self-hosted Docker container registry. Single domain, one
`docker-compose.yml`, no custom code.

## What you get

- **Registry endpoint** — `docker login / push / pull` against `registry.yourdomain.com`
- **Admin panel** — web UI at the root of the same domain (repo browser, tag explorer, manual delete)
- **Auto-cleanup** — retention sidecar deletes old tags nightly and runs `registry garbage-collect` to reclaim disk
- **Built on Docker's reference registry** — [`registry:2`](https://hub.docker.com/_/registry), the CNCF distribution implementation every major registry descends from

## Architecture

```
                 Internet
                    │
                    ▼
         Dokploy Traefik (TLS)
                    │
        ┌───────────┴───────────┐
        │                       │
  PathPrefix(/v2)          everything else
        │                       │
        ▼                       ▼
     registry:2        joxit/docker-registry-ui
     (push/pull)              (web UI)
        │                       │
        └───────────┬───────────┘
                    │
              shared htpasswd
                    │
                    ▼
              registry-data
                    ▲
                    │
               retention
     (daily tag prune + GC)
```

Services in `docker-compose.yml`:

| Service | Image | Purpose |
|---|---|---|
| `htpasswd-init` | `httpd:2.4-alpine` | One-shot. Bcrypt-hashes `ADMIN_PASSWORD` into `/auth/htpasswd` on first boot. |
| `registry` | `registry:2.8.3` | OCI-compliant registry. Serves `/v2/*` under `REGISTRY_DOMAIN`. |
| `ui` | `joxit/docker-registry-ui:2.5.7` | Static web UI. Serves `/` under `REGISTRY_DOMAIN`. Calls the registry API from the browser (same origin, no CORS). |
| `retention` | `registry:2.8.3` | Sidecar. Every `RETENTION_INTERVAL_SECONDS`, deletes old tags via the API (keeping `KEEP_LAST` per repo) and runs `registry garbage-collect --delete-untagged`. |

Traefik routes both services on the same domain via path priority:
`/v2/*` goes to the registry (priority 100), everything else goes to
the UI (priority 1).

## Quick start (Dokploy)

1. Connect this repo to Dokploy as a Compose application.
2. Set these env vars in Dokploy's **Environment** tab (see `.env.example`):
   - `REGISTRY_DOMAIN` — e.g. `registry.yourdomain.com`
   - `ADMIN_USERNAME` — e.g. `admin`
   - `ADMIN_PASSWORD` — strong password
3. Point a DNS A record for `REGISTRY_DOMAIN` at your Dokploy ingress IP.
4. Deploy. Let's Encrypt will issue a TLS cert automatically via Traefik.

## Client usage

```bash
docker login registry.yourdomain.com
docker tag alpine:latest registry.yourdomain.com/alpine:test
docker push registry.yourdomain.com/alpine:test
docker pull registry.yourdomain.com/alpine:test
```

Browse `https://registry.yourdomain.com/` for the UI. First API call
from the browser will prompt for the same admin credentials.

## Retention

Defaults: keep 10 tags per repo, run every 24h.

Tuning (set in Dokploy's Environment tab):

| Variable | Default | Meaning |
|---|---|---|
| `KEEP_LAST` | `10` | Number of tags to keep per repository (newest first, version-sorted). |
| `RETENTION_INTERVAL_SECONDS` | `86400` | Seconds between retention cycles. |

Tags are sorted with GNU `sort -V` (version sort descending), so
semver tags like `v1.10.0` correctly rank newer than `v1.2.0`. Tags
beyond the keep-count are DELETEd via the manifest API, then
`registry garbage-collect --delete-untagged` runs against the shared
volume to reclaim disk.

To trigger a retention pass immediately:

```bash
docker compose exec retention /bin/sh /retention.sh
```

## Rotating the admin password

The htpasswd file is generated on first boot and persisted in the
`registry-auth` volume, so changing `ADMIN_PASSWORD` alone has no
effect. To rotate:

1. Update `ADMIN_PASSWORD` in Dokploy's Environment tab.
2. SSH to the Dokploy host: `docker volume rm <stack>_registry-auth`
3. Redeploy — the init container will regenerate htpasswd from the new value.

## Adding a CI/service user

Append an additional htpasswd entry into the existing volume without
wiping the admin:

```bash
docker run --rm \
  -v <stack>_registry-auth:/auth \
  httpd:2.4-alpine \
  htpasswd -Bb /auth/htpasswd ci-bot <strong-password>
```

No redeploy needed — the registry reloads htpasswd on every auth.

## License

Apache 2.0. Built on:

- [Docker Distribution / Registry v2](https://github.com/distribution/distribution)
- [joxit/docker-registry-ui](https://github.com/Joxit/docker-registry-ui)
