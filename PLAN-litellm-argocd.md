# Plan: LiteLLM + CloudNativePG via ArgoCD, EPP-routed inference

Status: **planning only — nothing applied/changed yet.**
Date: 2026-07-24

## Goal

- Single OpenAI-compatible API for every model (qwen, deepseek, future) at
  `https://inference.llm.bearingpoint.com/v1`.
- LiteLLM UI reachable at `https://inference.llm.bearingpoint.com/ui`
  (litellm default; keeps `/v1` clean — see "UI path decision").
- LiteLLM installed via Helm with `STORE_MODEL_IN_DB="True"` (manage models
  from the DB/Admin UI).
- Request chain:
  `envoy (public 443) -> litellm -> envoy (internal, ClusterIP-only, HTTP) ->
   endpoint picker (kserve router-scheduler / InferencePool EPP) -> vLLM pod`.
- Postgres backing store via **CloudNativePG**, single instance, on
  `/dev/sdd` using the `local-storage` StorageClass (single-node cluster).
- All Helm charts delivered as **ArgoCD Applications** (app-of-apps).

## Locked decisions

1. **UI path**: litellm default `/ui` at root host (NOT `/litellm`, which
   would force `SERVER_ROOT_PATH` and move the API to `/litellm/v1`).
2. **Internal hop**: dedicated **ClusterIP-only** internal Gateway (envoy),
   HTTP only, no TLS, not exposed on any LoadBalancer.
3. **Postgres**: single instance (`instances: 1`), no replica.
4. **LiteLLM chart**: monolithic `litellm-helm`
   (OCI `ghcr.io/berriai/litellm-helm`, image `litellm-database`).
5. **Internal routing style**: **kserve-native (Option K)** — the
   `LLMInferenceService.spec.router` generates the HTTPRoute + InferencePool
   backendRef itself (via `router.gateway.refs`). No hand-written internal
   HTTPRoutes, no URLRewrite.
6. **ArgoCD source**: Applications target `stefanpinterBE/azure-llm` @ `main`.
   Repo access will be granted later; until then git-sourced apps are applied
   with `kubectl apply` manually. Helm/OCI-sourced apps work immediately.

## Current state (verified against the live cluster)

- ArgoCD installed in `argocd` ns, **zero Applications** yet.
- Shared `kserve-ingress-gateway` (envoy, ns `kserve`): listeners :80 (HTTP,
  all hosts) and :443 (HTTPS, `*.llm.bearingpoint.com`, wildcard cert
  `wildcard-llm-bearingpoint-com-tls`). Its Envoy service
  `envoy-kserve-kserve-ingress-gateway-*` is a **LoadBalancer**
  (10.159.76.69), so its :80 is publicly reachable — NOT reused for the
  internal hop.
- Endpoint-picker chain already exists per model (`router.scheduler: {}`):
  `InferencePool` (`inference.networking.k8s.io/v1`, e.g.
  `qwen3coder-inference-pool`) -> `*-epp-service:9002`
  (llm-d-inference-scheduler EPP) -> `*-kserve-workload-svc:8000` (vLLM).
- **Gap**: current `*-ui` HTTPRoutes backendRef the workload svc directly,
  bypassing the EPP. No HTTPRoute currently references an InferencePool.
  KServe generates no route today because only `router.scheduler` is set
  (no `router.gateway.refs`).
- Old `litellm-router` (ns `kserve-litellm-router`): a `python:3.11-slim`
  pod `pip install`ing litellm at startup, ConfigMap config, routing straight
  to workload svcs. To be retired.
- `/dev/sdd` = 10G, empty, unformatted, unmounted. `local-storage` SC is
  `no-provisioner` + `WaitForFirstConsumer` (static PVs only).

## LLMInferenceService router schema (verified from CRD)

`spec.router` supports `gateway.refs` ([{name,namespace,sectionName}]),
`route.http` ({refs, spec}), `ingress.refs`, and `scheduler`. So KServe can
own the HTTPRoute -> InferencePool wiring natively (Option K).

---

## Work items

### A. Internal-only Gateway  (`internal-gateway/` — new dir, git-sourced)

- `GatewayClass` `envoy-internal` + `EnvoyProxy` CR referenced via
  `parametersRef`, setting
  `provider.kubernetes.envoyService.type: ClusterIP` (no LoadBalancer, no
  public IP).
- `Gateway` `kserve-internal-gateway` (ns `kserve`): HTTP :80 only, no TLS,
  `allowedRoutes.namespaces.from: All`.

### B. Per-model kserve-native routing  (edit existing manifests)

Add to `qwen3coder/llminferenceservice-qwen3-coder-next.yaml` and
`deepseek-r1-distill/llinferenceservice-deepseek-r1-destill.yaml`:

```yaml
router:
  scheduler: {}
  gateway:
    refs:
      - name: kserve-internal-gateway
        namespace: kserve
  route:
    http: {}     # KServe generates the HTTPRoute + InferencePool backendRef
```

- KServe owns the envoy -> EPP -> vLLM wiring. No hand-written internal
  HTTPRoute, no URLRewrite (path stays `/v1/...`).
- **Verify during impl**: the hostname/path KServe stamps on the generated
  route. If it defaults every service to path `/` on the shared gateway
  (collision), pin a distinct per-model hostname via `router.route.http.spec`.

### C. Postgres / CloudNativePG  (`postgres/` — new dir)

1. **Host one-time (operator runs manually, outside git):**
   `mkfs.ext4 /dev/sdd`, mount at `/mnt/pgdata` (+ persist in `/etc/fstab`).
2. `pv-postgres.yaml`: `local-storage` static PV, `local.path: /mnt/pgdata`,
   ~10Gi, `nodeAffinity` pinned to this node.
3. `cluster.yaml`: CNPG `Cluster`, `instances: 1`,
   `storage: { storageClass: local-storage, size: 10Gi }` (binds the PV),
   bootstrap DB `litellm` + owner role. CNPG emits app credentials Secret
   (`litellm-app`: username/password/uri).

### D. LiteLLM values  (`litellm/` — new dir; chart from OCI)

- Namespace `litellm`.
- Secrets (plain k8s Secrets, **gitignored** like `cert/acmedns-account.yaml`):
  - `litellm-masterkey` (`LITELLM_MASTER_KEY`).
  - `litellm-env`: `LITELLM_SALT_KEY` (generate once, **never rotate**),
    `STORE_MODEL_IN_DB="True"`, `DISABLE_SCHEMA_UPDATE="true"`.
- `values.yaml` for `ghcr.io/berriai/litellm-helm` (pinned version), image
  `ghcr.io/berriai/litellm-database`:
  - `db.useExisting` -> CNPG service endpoint + `litellm-app` secret.
  - migration job enabled (chart default) + ArgoCD PreSync hook.
  - `proxy_config.model_list` seed (`qwen3coder`, `qwen`, `deepseek`) with
    `api_base` -> the kserve-native internal route (host/path confirmed in B),
    resolved via pod `hostAliases` -> internal gateway ClusterIP.
    (With `STORE_MODEL_IN_DB=True`, further models are added from the UI.)

### E. Public exposure  (`litellm/httproute.yaml`)

- HTTPRoute on the public `kserve-ingress-gateway`, host
  `inference.llm.bearingpoint.com`, `PathPrefix: /` -> litellm Service :4000.
  Serves both `/v1/...` and `/ui`.

### F. ArgoCD app-of-apps  (`argocd/` — new dir)

- `apps/cloudnative-pg.yaml` — helm repo `https://cloudnative-pg.github.io/charts`,
  chart `cloudnative-pg`, ns `cnpg-system`. **Works before repo access.**
- `apps/litellm.yaml` — OCI `ghcr.io/berriai/litellm-helm` + inline
  `helm.valuesObject`. **Works before repo access.**
- `apps/postgres.yaml` — git path `postgres/`. Needs repo access; `kubectl
  apply` interim.
- `apps/internal-gateway.yaml` — git path `internal-gateway/`. Needs repo
  access; `kubectl apply` interim.
- `apps/kserve-models.yaml` — git path(s) for the model dirs. Needs repo
  access; `kubectl apply` interim.
- `root-app.yaml` — app-of-apps watching `argocd/apps/`.

### G. Cleanup

- Retire old `litellm-router/` (deployment/service/configmap/kustomization/
  httproute) once new litellm verified.
- Remove or repoint the direct-to-workload `*-ui` HTTPRoutes (EPP-bypassing).
  Flag, do not silently delete.

---

## UI path decision (why `/ui`, not `/litellm`)

LiteLLM serves everything under `SERVER_ROOT_PATH`. Setting it to `/litellm`
would move the API to `/litellm/v1`, conflicting with the required `/v1`.
So litellm stays at root: API at `/v1`, UI at default `/ui`.

## Verification (after implementation)

- `kubectl -n litellm exec ... curl /health/readiness` returns healthy.
- UI loads at `https://inference.llm.bearingpoint.com/ui` (login w/ master key).
- `POST https://inference.llm.bearingpoint.com/v1/chat/completions` with
  `"model":"qwen3coder"` and `"deepseek"` returns completions.
- EPP pod logs show endpoint-picking activity (proves envoy -> EPP -> pod, not
  a direct workload hit).
- CNPG `Cluster` reports `Ready`; its PVC is `Bound` to the `/mnt/pgdata` PV.

## Open items to confirm at implementation time

- Exact hostname/path on the KServe-generated internal route (drives litellm
  `api_base` + `hostAliases`).
- Pinned chart/image versions (litellm-helm, cloudnative-pg).
- CNPG Postgres major version.

---

## Implementation notes (APPLIED — 2026-07-24)

Deployed and verified end-to-end. Resolved details:

- **Internal gateway**: `GatewayClass envoy-internal` (parametrised by
  `EnvoyProxy envoy-internal`, `envoyService.type: ClusterIP`) +
  `Gateway kserve-internal-gateway` (ns `kserve`, HTTP :80). Data-plane
  Service: `envoy-kserve-kserve-internal-gateway-172612ac.envoy-gateway-system`
  (ClusterIP only, no LoadBalancer).
- **KServe-native routing confirmed**: adding
  `router.gateway.refs -> kserve-internal-gateway` + `router.route.http: {}`
  makes KServe generate an HTTPRoute on the internal gateway with an
  `InferencePool` backendRef **and its own URLRewrite** — no hand-written route,
  no manual rewrite. Path convention: `/<namespace>/<model>/v1/...` rewritten to
  `/v1/...`. litellm `api_base` values:
  - qwen3coder: `http://<internal-gw-svc>/kserve-qwen3coder/qwen3coder/v1`
  - deepseek:   `http://<internal-gw-svc>/kserve-deepseek/deepseek/v1`
  No hostAliases needed (routes have no hostname → match all Hosts).
- **litellm-helm OCI tag**: chart `oci://ghcr.io/berriai/litellm-helm` version
  **`1.93.0`** (the in-repo Chart.yaml `1.1.0` is NOT a published OCI tag; OCI
  tags follow litellm release numbers). Image tag left empty → chart appVersion.
- **CNPG**: operator chart `cloudnative-pg` `0.29.0` (CNPG 1.30); DB image
  `ghcr.io/cloudnative-pg/postgresql:17`; `/dev/sdd` formatted ext4, mounted
  `/mnt/pgdata` (fstab, chown 26:26), static PV `litellm-pg-pv` (8Gi) bound by
  PVC `litellm-pg-1`.
- **Secrets** (gitignored, created out-of-band): `litellm-masterkey`,
  `litellm-env` (`LITELLM_SALT_KEY`). Postgres creds from CNPG's `litellm-pg-app`.
- **UI redirect fix**: litellm emits an http-scheme 307 for the bare `/ui`;
  added a gateway `RequestRedirect` (`/ui` -> https `/ui/`, 301) on the public
  HTTPRoute, plus `FORWARDED_ALLOW_IPS: "*"`.
- **Retired**: `litellm-router/` dir + `kserve-litellm-router` namespace.
- **Deploy state**: applied directly (ArgoCD lacks repo access yet) —
  `cloudnative-pg` + `litellm` ArgoCD Apps (Helm/OCI) are live and
  Synced/Healthy; git-sourced content (internal-gateway, postgres, model
  router edits, public route) applied via `kubectl`. Once repo access lands,
  `kubectl apply -f argocd/root-app.yaml` adopts everything.

**Verified**: `POST /v1/chat/completions` for `qwen3coder`, `qwen`, `deepseek`
through the full public chain
`envoy(443 TLS) -> litellm -> envoy(internal) -> EPP/InferencePool -> vLLM`;
`/v1/models` lists all three; UI 200 at `/ui/`; CNPG healthy; DB connected.
