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
  actually contain sensitive credentials (acme-dns account) — currently
  tracked as a real value in `cert/acmedns-account.yaml`, not templated.
- No Kustomize/Helm — every namespace/model is fully duplicated YAML with
  no shared base.
- No CI/CD, no automated apply/deploy script.
