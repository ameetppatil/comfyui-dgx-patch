#!/usr/bin/env bash
# ComfyUI launcher for the appliance.
#
# Every flag below is here for a measured reason; the comments are the record.
set -euo pipefail

COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_LISTEN="${COMFY_LISTEN:-127.0.0.1}"
COMFY_MODEL_ROOT="${COMFY_MODEL_ROOT:-/models/image}"
COMFY_OUTPUT="${COMFY_OUTPUT:-/data/comfyui/output}"
COMFY_TEMP="${COMFY_TEMP:-/data/comfyui/temp}"
COMFY_USER_DIR="${COMFY_USER_DIR:-/data/comfyui/user}"
COMFY_INPUT="${COMFY_INPUT:-/data/comfyui/input}"

# the design's reserve. Note what this is *not*: a hard limit.
#
# The README.3 assumed a Docker memory cap would bound ComfyUI and protect the LLM.
# Measured here, it does not. CUDA allocations on GB10 are not charged to the
# container's cgroup — during a render that moved 39 GB of host memory, the
# container's own `memory.current` peaked at 2.2 GB, and a container capped at
# 24 GB happily used 33 GB without being killed. A cgroup cap constrains
# ComfyUI's *host-side* allocations only.
#
# So a cap is a way to tell ComfyUI its budget (the unified-memory patch wires
# the cgroup limit into its planner), not a way to enforce one. Measured, a
# cap made things slightly worse: capped at 24 GB and at 40 GB both peaked
# ~3 GB *higher* than uncapped, for the same latency, because the planner
# double-buffers when it believes memory is tight. The appliance therefore
# runs it uncapped and relies on the footprint being bounded by the weights
# themselves — which the measurements show it is: the peak is flat from 1024²
# to 1328², because weights dominate and activations are small.
COMFY_RESERVE_VRAM_GB="${COMFY_RESERVE_VRAM_GB:-2}"

mkdir -p "$COMFY_OUTPUT" "$COMFY_TEMP" "$COMFY_USER_DIR" "$COMFY_INPUT" "${CUDA_CACHE_PATH:-/cache/cuda}"

# Point ComfyUI at the bind-mounted weights rather than copying them into its
# tree. One directory, three engines — the models are shared, so a
# symlink farm or a copy would both be wrong.
cat > /opt/comfyui/extra_model_paths.yaml <<YAML
appliance:
  base_path: ${COMFY_MODEL_ROOT}
  is_default: true
  diffusion_models: diffusion_models
  text_encoders: text_encoders
  vae: vae
YAML

echo "ComfyUI $(cat /opt/comfyui/.comfyui-ref 2>/dev/null || echo unknown)"
echo "models:  ${COMFY_MODEL_ROOT}"
echo "listen:  ${COMFY_LISTEN}:${COMFY_PORT}"

exec python /opt/comfyui/main.py \
  --listen "$COMFY_LISTEN" \
  --port "$COMFY_PORT" \
  --output-directory "$COMFY_OUTPUT" \
  --input-directory "$COMFY_INPUT" \
  --temp-directory "$COMFY_TEMP" \
  --user-directory "$COMFY_USER_DIR" \
  --extra-model-paths-config /opt/comfyui/extra_model_paths.yaml \
  --reserve-vram "$COMFY_RESERVE_VRAM_GB" \
  --disable-pinned-memory \
  --disable-xformers \
  --use-pytorch-cross-attention \
  --disable-auto-launch \
  --dont-print-server \
  "$@"

# On --disable-xformers / --use-pytorch-cross-attention, measured here:
#
# ComfyUI finds the xformers that ships in the NGC base image and selects it
# automatically ("Using xformers attention"). Its flash-attention kernels are
# built for Hopper and have **no sm_121 binary**, so the first denoise step
# dies with:
#
#   CUDA error (.../hopper/flash_fwd_launch_template.h:188):
#   no kernel image is available for execution on the device
#
# which kills the process rather than raising a Python exception — the server
# exits mid-render and the client sees a connection reset, pointing nowhere
# near attention. The same class of failure is recorded for the audio engines
# in The README.2 (`flash_attn` undefined symbol). PyTorch SDPA has a working kernel
# for this architecture, so it is selected explicitly rather than left to
# autodetection, which here detects wrongly.
#
# Notes on flags *not* passed, since their absence is also a decision:
#
#   --gpu-only       Would keep every tensor on the device and defeat the
#                    eviction described above. On a discrete card it is the
#                    performance flag; here it is the one that breaks The README.
#   --highvram       Same problem, less bluntly.
#   --lowvram        Tempting, but it forces per-layer streaming for every
#                    model including the 250 MB VAE, which costs latency for
#                    memory we do not need to save. Upstream's DynamicVRAM
#                    staging already streams weights from NVMe here.
#   --fast           Enables autotune and fp16 accumulation paths that Triton
#                    cannot compile for sm_121a.
#   --cpu-vae        Pointless on unified memory: the VAE decode would read
#                    and write the same physical pages, just more slowly.
