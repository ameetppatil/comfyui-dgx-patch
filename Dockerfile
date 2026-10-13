# ComfyUI for GB10 unified memory.
#
# Why this is its own image rather than a layer inside a product's: ComfyUI
# pulls its own dependency tree and patches its own internals, so keeping it
# out of the image that serves the LLM means a ComfyUI bump cannot break
# inference. It shares the NGC base layer with those images, so the cost on
# disk is much smaller than the sizes suggest. It is also what keeps GPL code
# out of the products — see docs/gpl-compliance.md.
#
# ---------------------------------------------------------------------------
# Licence note, deliberately at the top because it affects distribution.
#
# ComfyUI is **GPL-3.0-or-later**. A product ships it as a separate process
# behind its own loopback port and talks to it over HTTP — so the product is
# not a derivative work. Our *modifications to ComfyUI itself* are
# a different matter: `patches/*.patch` are changes to a GPL work and
# are published as source in this repo for that reason. Keeping them as diffs
# rather than copied files is what makes that offer trivially satisfiable.
# See docs/gpl-compliance.md.
# ---------------------------------------------------------------------------

# The same pinned NGC tag as the appliance image. It is pinned because
# 26.04-py3 cannot load NVFP4 MoE checkpoints, and because `pip install torch`
# does not produce a working wheel for sm_121 at all — this base is the only
# source of a torch *and* a matched torchvision for this architecture. Do not
# move it without re-running `make comfy-verify` on hardware.
FROM nvcr.io/nvidia/vllm:26.08-py3

# Pinned to a commit, not a tag: a tag can be moved, and this image patches
# ComfyUI's internals, so "which tree" has to be exact. v0.39.2.
ARG COMFY_REF=3c1b7a17fdf239d35ce98cc777756f572d089795
ARG COMFY_VERSION=v0.39.2

LABEL org.opencontainers.image.title="comfyui-gb10" \
      org.opencontainers.image.description="ComfyUI patched for GB10 unified memory" \
      org.opencontainers.image.licenses="GPL-3.0-or-later" \
      io.cromozo.comfyui.version="${COMFY_VERSION}" \
      io.cromozo.comfyui.ref="${COMFY_REF}"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --filter=blob:none https://github.com/comfyanonymous/ComfyUI.git comfyui \
 && cd comfyui \
 && git checkout -q "${COMFY_REF}" \
 && git rev-parse HEAD > /opt/comfyui/.comfyui-ref

WORKDIR /opt/comfyui

# torch and torchvision come from the base image and must survive this step.
#
# Two failure modes, both met on this hardware:
#   - A constraints file pinning the installed versions makes resolution
#     impossible, because NGC's local versions (2.14.0a0+4fdf77b940.nv26.08)
#     are not on any index, so pip cannot satisfy the constraint it was given.
#   - Letting pip see the bare `torch` line risks it deciding to "helpfully"
#     resolve a PyPI build, which on aarch64/sm_121 is either absent or
#     non-functional, and would also desynchronise torchvision's ABI.
# Dropping the two lines is what works: pip treats the already-installed
# distributions as satisfying every transitive `torch` requirement.
RUN grep -vE '^(torch|torchvision)[[:space:]]*$' requirements.txt > /tmp/requirements.comfy.txt \
 && pip install --no-cache-dir --root-user-action=ignore -r /tmp/requirements.comfy.txt \
 && python -c "import torch, torchvision; \
assert torch.__version__.endswith('nv26.08'), torch.__version__; \
assert torchvision.__version__.startswith('0.29'), torchvision.__version__; \
print('base torch intact:', torch.__version__, torchvision.__version__)"

# ---------------------------------------------------------------------------
# The unified-memory patches .
#
# Applied at build with `git apply`, against the commit pinned above, so a
# patch that no longer applies **fails the build**. That is the whole point:
# the alternative previously tried on this hardware — mounting patched files
# over a running container — fails at *runtime* with an import error that
# reads like a broken ComfyUI rather than a version mismatch, and costs an
# afternoon. A build-time failure names the file and the hunk.
# ---------------------------------------------------------------------------
COPY patches/ /opt/comfyui-patch/patches/
COPY scripts/verify.py /opt/comfyui-patch/verify.py
RUN set -e; \
    rm -f /opt/comfyui-patch/patches/._* /opt/comfyui-patch/patches/.DS_Store; \
    n=0; \
    for p in /opt/comfyui-patch/patches/*.patch; do \
      echo "applying $(basename "$p")"; \
      git apply --verbose --whitespace=nowarn "$p"; \
      n=$((n + 1)); \
    done; \
    [ "$n" -ge 2 ] || { echo "expected at least 2 patches, applied $n" >&2; exit 1; }; \
    python /opt/comfyui-patch/verify.py --static

# Note what the line above does *not* do. `docker build` has no GPU, so
# importing `comfy.model_management` here fails on `torch.cuda.current_device`
# — it is a build step that cannot test behaviour. It checks that the patch
# applied, left valid Python, and still covers every call site it names.
# Whether the patch *works* is `make verify`, which runs the same script
# with `--gpus all` and asserts the memory decisions on real hardware.

# NOTE: no workflow templates here, deliberately. They are product content
# rather than part of the GPL layer — each consuming product mounts or layers
# its own, so a ComfyUI bump cannot silently replace them and one product's
# workflows never ship inside another's image.
COPY scripts/entrypoint.sh /opt/comfyui-patch/entrypoint.sh
RUN chmod +x /opt/comfyui-patch/entrypoint.sh

# This Dockerfile ships inside the image it builds. GPL-3.0 §1 counts the
# scripts controlling installation of a covered work as part of its
# Corresponding Source, and ComfyUI is GPL — so `scripts/release-source.sh`
# can assemble a complete, conveyable source bundle from the image alone,
# without needing this repository. See docs/gpl-compliance.md.
COPY Dockerfile /opt/comfyui-patch/Dockerfile

# Model weights are bind-mounted read-only at run time, never baked in: they
# are ~30 GB, licence-encumbered, and shared with the other engines.
ENV COMFY_MODEL_ROOT=/models/image \
    COMFY_PORT=8188 \
    COMFY_LISTEN=127.0.0.1

# Flags each with a measured reason:
#   TORCH_COMPILE_DISABLE / TORCHDYNAMO_DISABLE — Triton has no sm_121a
#     support, and dynamo's fallback path is slower than eager here.
#   CUDA_CACHE_MAXSIZE — PTX->SASS compilation of these kernels is minutes on
#     first render; a 4 GiB on-disk cache makes that a one-off.
#   CUDA_MODULE_LOADING=LAZY — keeps start-up resident memory down, which
#     matters when five processes share one pool.
ENV TORCH_COMPILE_DISABLE=1 \
    TORCHDYNAMO_DISABLE=1 \
    CUDA_CACHE_MAXSIZE=4294967296 \
    CUDA_CACHE_PATH=/cache/cuda \
    CUDA_MODULE_LOADING=LAZY \
    PYTHONUNBUFFERED=1 \
    HF_HUB_OFFLINE=1

EXPOSE 8188
# No HEALTHCHECK on /system_stats alone: it answers before the model loads, so
# it would report healthy while the first render is still compiling kernels.
# The router's capacity endpoint owns readiness.
ENTRYPOINT ["/opt/comfyui-patch/entrypoint.sh"]
