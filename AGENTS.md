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

## Migration: llama.cpp → vLLM (both `LLMInferenceService`s)

Both models were originally served via `ghcr.io/ggml-org/llama.cpp:server`
(GGUF-native, CPU/GPU llama.cpp backend). Moved to vLLM for better
throughput/batching and a more actively-maintained inference stack. Outcome
differs per model:

### DeepSeek-R1-Distill-Qwen-32B — vLLM + GGUF plugin (works)

vLLM's own GGUF support is explicitly "highly experimental" upstream
(https://docs.vllm.ai/en/stable/features/quantization/gguf/) and now requires
the out-of-tree `vllm-gguf-plugin`
(https://github.com/vllm-project/vllm-gguf-plugin). Since custom Docker
images are off the table for this project, the plugin is `pip install`ed at
container startup (before `vllm serve`) on top of the stock
`vllm/vllm-openai:latest` image — see
`deepseek-r1-distill/llinferenceservice-deepseek-r1-destill.yaml`.

DeepSeek-R1-Distill-Qwen-32B is a **dense Qwen2-style architecture**, one of
the plugin's tested/supported model families, and it works: `vllm serve`
loads the existing `/mnt/models/.../Q4_K_M.gguf` directly, with `--tokenizer
deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` supplying the tokenizer/config from
the (non-GGUF) base HF repo. Confirmed working end-to-end with a real chat
completion via direct pod curl.

### Qwen3-Coder-Next — GGUF+vLLM doesn't work; switched to native AWQ-4bit

Qwen3-Coder-Next is a **hybrid MoE + Gated-DeltaNet ("linear attention")
architecture** (`Qwen3NextForCausalLM`, 80B total / 3B active — same family
as `Qwen/Qwen3-Next-80B-A3B-Instruct`). vLLM natively supports this
architecture, but `vllm-gguf-plugin`'s tested model list
(Qwen 2.5, Qwen 3 dense, Phi 3.5, GPT-2, StableLM, Gemma 3, OLMoE) does not
include any hybrid/MoE-linear-attention architecture, and this was confirmed
in practice: the plugin correctly resolves the `Qwen3NextForCausalLM`
architecture from the HF config, but its GGUF weight loader has no tensor
mapping for `model_type: qwen3_next`, and the pod crash-loops with:

```
RuntimeError: Unknown gguf model_type: qwen3_next
```

**Fix:** dropped the GGUF checkpoint for this model entirely and switched to
`bullpoint/Qwen3-Coder-Next-AWQ-4bit` (~48G, AWQ/`compressed-tensors`
quantization — natively supported by vLLM, no plugin required, and the
closest-footprint alternative to the original ~46G GGUF `Q4_K_M`). vLLM
auto-detects the quantization method from the repo's `config.json`, so no
`--quantization` flag is needed. See
`qwen3coder/localmodelcache-qwen3-coder-next-awq.yaml` (points
`LocalModelCache`/`ClusterStorageContainer hf-awq-qwen3coder` at
`hf://bullpoint/Qwen3-Coder-Next-AWQ-4bit`, full-repo download — no
`STORAGE_ALLOW_PATTERNS`, since AWQ checkpoints are sharded safetensors, not
a single selectable GGUF file) and
`qwen3coder/llminferenceservice-qwen3-coder-next.yaml` (`vllm serve
/mnt/models` — the whole cached repo dir — instead of a single `.gguf` file).
Confirmed working end-to-end with a real chat completion via direct pod
curl.

Other engine options considered and rejected for Qwen3-Coder-Next before
landing on the AWQ pivot: `Qwen/Qwen3-Coder-Next-FP8` (official, ~80G, native
vLLM FP8 — larger footprint, viable fallback if AWQ ever regresses),
`huggingfaceserver` (would need a full non-GGUF checkpoint anyway, no
throughput advantage over vLLM), Triton/TensorRT-LLM and SGLang (same
GGUF-support gap, unrealistic given "no custom images" constraint).

**Rule of thumb:** before committing to a GGUF quantization of an exotic
architecture for vLLM, check `vllm-gguf-plugin`'s supported/tested model list
first — hybrid/MoE-linear-attention architectures (Qwen3-Next family, Jamba,
etc.) are very unlikely to be supported. Prefer a native
AWQ/GPTQ/`compressed-tensors`/FP8 checkpoint from HF for such models instead
of GGUF.

### Incident: router-scheduler `EndpointPickerConfig` apiVersion drift

The cluster's `llmisvc-controller-manager` was running the upstream default
`kserve/llmisvc-controller:latest` image (`imagePullPolicy: Always` — a
floating tag, not a pinned release). It had silently drifted ahead of the
pinned `ghcr.io/llm-d/llm-d-inference-scheduler:v0.7.1` image referenced by
KServe's own default `kserve-config-llm-scheduler` template: the drifted
controller started generating the router-scheduler's `--config-text` (an
inline `EndpointPickerConfig`) using `apiVersion: llm-d.ai/v1alpha1`, but
`v0.7.1`'s scheme only registers `apiVersion:
inference.networking.x-k8s.io/v1alpha1` — crash-looping the
router-scheduler's `main` container with:

```
no kind "EndpointPickerConfig" is registered for version "llm-d.ai/v1alpha1"
```

This surfaced when qwen3coder's `LLMInferenceService` was deleted/recreated
for the AWQ pivot (regenerating its config fresh from the now-drifted
default); `deepseek`'s router pod avoided it only by chance, having predated
the controller drift and never having restarted.

**Fix: pin `llmisvc-controller-manager` to a specific stable release
instead of overriding each `LLMInferenceService`'s scheduler config.**
The install docs for this project (see top of this file / repo README)
install llmisvc via:
```
kubectl apply -k config/overlays/addons/llmisvc --force-conflicts --server-side
```
from a local checkout of `kserve/kserve` (referenced here as `~/kserve`).
That overlay's image is set by
`~/kserve/config/llmisvc/llmisvc_manager_image_patch.yaml` — pinned there to
```yaml
image: kserve/llmisvc-controller:v0.19.0
imagePullPolicy: IfNotPresent
```
(the latest stable, non-`-rc` release as of 2026-07-22; confirmed via
`kubectl kustomize config/overlays/addons/llmisvc` that this resolves
correctly, then re-applied with the exact command above). `v0.19.0` was
confirmed to generate the older, compatible `apiVersion:
inference.networking.x-k8s.io/v1alpha1`.

**Caveat hit during the fix — downgrading in place can break existing
Deployments:** an in-place image change alone isn't enough if a *newer* drifted
controller had already created the `LLMInferenceService`'s child Deployments —
their `spec.selector` is immutable, and an older controller version may try to
reconcile a different selector, failing with `spec.selector: ... field is
immutable`. The working fix was to delete + recreate both
`LLMInferenceService`s (`kubectl delete/apply`) once the controller was
pinned, so their child Deployments regenerate cleanly under the new
controller version. This also released the per-model `LocalModelCache`
`PersistentVolume`s (`reclaimPolicy: Retain`) into `Released` state with a
stale `claimRef`; they had to be manually cleared before the new PVCs of the
same name could rebind:
```
kubectl patch pv <name>-workers-kserve-<ns> -p '{"spec":{"claimRef": null}}'
```
No data was lost — the local model cache directories under `/mnt/models`
were untouched, only the PV/PVC binding needed repairing. Confirmed both
models still serve real inference after the redeploy.

`spec.router.scheduler.config.inline` overrides are **not** used in either
`LLMInferenceService` manifest anymore — the pinned controller version alone
keeps them consistent. If `llmisvc-controller-manager` or
`llm-d-inference-scheduler` are ever deliberately upgraded, re-check that
their generated/expected `EndpointPickerConfig` `apiVersion`s still match
before rolling out, and expect to delete/recreate the `LLMInferenceService`s
if their child Deployments' `spec.selector` would change.
