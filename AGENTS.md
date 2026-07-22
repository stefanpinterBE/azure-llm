# azure-llm

## What this is
A collection of Kubernetes manifests (no application code, no build system) for
self-hosting LLM inference on a Kubernetes cluster (likely on Azure, given the
repo name and the `local-storage` / GPU node setup) using **KServe** as the
model-serving layer, **Gateway API (Envoy)** for ingress/routing, and
**cert-manager** with a DNS-01 (acme-dns) solver for TLS certificates.

Domain used throughout: `*.llm.bearingpoint.com`.

This is an early-stage / experimental infra project: manifests are applied
manually (`kubectl apply -f ...`), there's no CI, no Helm/Kustomize wrapping,
and no automation script tying it all together yet.

## Layout
- `gateway-https.yaml` — cluster-wide Gateway API `Gateway` (`kserve-ingress-gateway`,
  Envoy gatewayClass) terminating TLS for `*.llm.bearingpoint.com` on 443, plus
  plain HTTP on 80.
- `httproute.yaml` — top-level `HTTPRoute` for `qwen-ui.llm.bearingpoint.com`
  routing to the qwen3coder service in namespace `kserve-qwen3coder`.
- `cert/` — cert-manager resources:
  - `clusterissuer.yaml`: `ClusterIssuer` using Let's Encrypt via DNS-01
    through acme-dns.
  - `acmedns-account.yaml`: acme-dns account credentials Secret
    (**contains real credentials — gitignored, do not commit**).
  - `certificates.yaml`: wildcard `Certificate` for `*.llm.bearingpoint.com`.
- `clusterstoragecontainer.yaml` — cluster-wide KServe `ClusterStorageContainer`
  (`hf-hub`) defining how `hf://` URIs are downloaded (Hugging Face storage
  initializer, needs `hf-secret`/`HF_TOKEN`).
- `localmodelnodegroup.yaml` — KServe `LocalModelNodeGroup` (`workers`):
  reserves a 900G local PVC/PV on GPU worker nodes (labelled
  `kserve/localmodel: worker`) at `/mnt/models` for caching model weights
  locally on-node.
- `kserve-test/` — earliest experiment: a `v1beta1 InferenceService` serving
  `Qwen2.5-0.5B-Instruct` via the HuggingFace runtime, plus its own namespace
  and a smaller-resource `ClusterStorageContainer`. Looks like a first PoC,
  superseded by the `LLMInferenceService` (v1alpha1) approach used later.
- `qwen35/` — `LLMInferenceService` (v1alpha1) for `Qwen/Qwen3.5-0.8B` using
  the `kserve/huggingfaceserver` GPU image, with a matching `LocalModelCache`
  and namespace `kserve-qwen3`.
- `qwen3coder/` — `LLMInferenceService` for `unsloth/Qwen3-Coder-Next-GGUF`,
  served via `llama.cpp` server-cuda image (GGUF/quantized model,
  `Q4_K_M.gguf`), with `ClusterStorageContainer` + `LocalModelCache`
  restricted to that GGUF file via `STORAGE_ALLOW_PATTERNS`, namespace
  `kserve-qwen3coder`, plus its own `httproute.yaml` for `qwen-ui...`.
- `deepseek-r1-distill/` — same pattern as qwen3coder but for
  `unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF`, namespace `kserve-deepseek`,
  route `deepseek-ui.llm.bearingpoint.com`.
- `testing/` — manual smoke-test helpers: `curl.sh` (OpenAI-compatible
  `/v1/chat/completions` request against the deployed gateway) and
  `chat-input.json` (sample chat payload, model name `qwen`).
- `kubespray-venv/` — a leftover Python venv used to run **kubespray**
  (cluster bootstrapping tool); gitignored, not part of the app.

## Key patterns / conventions observed
- Each model gets its own directory with: `namespace.yaml`, an
  `LLMInferenceService` (or `InferenceService` for the older PoC), a
  `LocalModelCache` + dedicated `ClusterStorageContainer` (scoped via
  `STORAGE_ALLOW_PATTERNS` for GGUF quantizations to avoid downloading the
  whole HF repo), and often its own `HTTPRoute`.
- Two serving runtimes in use: `kserve/huggingfaceserver` (transformers-based,
  full precision) and `ghcr.io/ggml-org/llama.cpp:server-cuda` (GGUF quantized
  models, args `-m <path> --host 0.0.0.0 --port 8000 -ngl 99 --metrics`).
- GPU scheduling via `nvidia.com/gpu: "1"` resource requests/limits;
  GGUF-based services also pin to `nodeSelector: kserve/localmodel: worker`
  to land on nodes with the local model cache PV.
- All inference is exposed through the shared `kserve-ingress-gateway`
  Gateway API resource and per-model `HTTPRoute`s under
  `*.llm.bearingpoint.com`, terminating TLS from the wildcard cert.
- Endpoint path convention seen in testing: `https://inference.llm.bearingpoint.com/<namespace>/<model-name>/v1/chat/completions`.

## Notable rough edges (early phase)
- No README previously existed.
- Inconsistent API versions/kinds across experiments (`InferenceService`
  v1beta1 vs `LLMInferenceService` v1alpha1) — `kserve-test/` and `qwen35/`
  look like earlier iterations before standardizing on the llama.cpp +
  `LLMInferenceService` pattern used by qwen3coder/deepseek-r1-distill.
  `qwen35`'s `LLMInferenceService` also doesn't set `replicas`/`router`
  like the newer two do.
- Secrets checked into manifests: `cert/acmedns-account.yaml` actually
  contains a real acme-dns credential value, not a template/placeholder.
  It's excluded from git via `.gitignore`, but the working copy still has
  live secrets sitting in a plain YAML file on disk.
- No Kustomize/Helm — every namespace/model is fully duplicated YAML with
  no shared base.
- No CI/CD, no automated apply/deploy script.

## Incident: LocalModelCache downloaded every GGUF quantization variant (fixed 2026-07-22)
**Symptom:** `/dev/sdc` (`/mnt/models`, the `LocalModelNodeGroup` PV) filled to
100%, even though `hf-gguf-deepseek` / `hf-gguf-q4` set
`STORAGE_ALLOW_PATTERNS` to only the intended `*Q4_K_M.gguf` file.

**Root cause:** kserve's `ClusterStorageContainer` auto-selection
(`GetStorageContainerSpec` / `getContainerSpecForStorageUri` in
`pkg/webhook/admission/pod/storage_initializer_injector.go` and
`pkg/controller/v1alpha1/localmodelnode/controller.go`) lists all
`ClusterStorageContainer`s and returns the **first one whose
`supportedUriFormats` prefix matches the URI** — but the list comes from an
informer cache backed by a Go map, so iteration order is **not
deterministic**. Three containers all declared the same generic
`prefix: hf://` with `workloadType: localModelDownloadJob`:
`hf-hub` (root, no filtering), `hf-gguf-deepseek`, and `hf-gguf-q4`. On every
download-job (re)creation, kserve could randomly pick the unfiltered `hf-hub`
container instead of the model-specific one, causing a full unfiltered
`snapshot_download` of the entire HF repo (every quant, including huge `BF16`
/ `F16` masters) — confirmed directly from a live job pod's env
(`HF_TOKEN` only, no `STORAGE_ALLOW_PATTERNS`) and its logs ("Fetching 11
files").

**Fix applied:**
1. Freed disk space: deleted every non-`Q4_K_M.gguf` file/dir under
   `/mnt/models/models/<hash>/` for both models (reclaimed ~940G).
2. Scoped `hf-gguf-deepseek` and `hf-gguf-q4`'s `supportedUriFormats.prefix`
   from the generic `hf://` to their **exact source repo URI**
   (`hf://unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF` /
   `hf://unsloth/Qwen3-Coder-Next-GGUF`).
3. Changed the root `hf-hub` `ClusterStorageContainer`'s `workloadType` from
   `localModelDownloadJob` to `initContainer` — it currently has no active
   `localModelDownloadJob` consumer (the `qwen35/` LocalModelCache isn't
   deployed) and its blanket `hf://` prefix was the source of the collision.
4. Re-applied to the cluster, deleted the stuck job, verified
   `LocalModelNode` status is `ModelDownloaded` for both models with only the
   intended file on disk, and confirmed both `LLMInferenceService`s are still
   `READY`.

**Rule of thumb for future models:** every `ClusterStorageContainer` with
`workloadType: localModelDownloadJob` must have a `supportedUriFormats` prefix
that is unique to its target repo — never reuse the bare `hf://` prefix for
more than one such container, or selection becomes a race again. If a future
model wants full-repo caching (no `STORAGE_ALLOW_PATTERNS` filtering), give it
its own dedicated container scoped to its exact repo URI rather than reviving
`hf-hub` as a shared `localModelDownloadJob` fallback.

**Still worth addressing:** `kserve-test/clusterstoragecontainer.yaml` defines
a second, differently-sized `ClusterStorageContainer` also named `hf-hub`,
which silently overwrites/conflicts with the root one on `kubectl apply`
(cluster-scoped names collide) — same class of bug, currently latent because
`kserve-test`'s `InferenceService` isn't deployed.
