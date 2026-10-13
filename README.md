# comfyui-patch — ComfyUI for NVIDIA GB10, and the GPL layer that comes with it

ComfyUI patched to work correctly on Grace-Blackwell (GB10 / DGX Spark)
hardware, packaged as a container image.

Two Cromozo products run image generation on that hardware and both need
the same fixes: the **ecobillz** on-premises AI appliance and the
**Vonzl** Local Appliance. This repository is the single place those
fixes live.

## Why this is its own repository

Not for code reuse — that is a side benefit. The reason is licensing.

**ComfyUI is GPL-3.0-or-later, and this repository modifies it.** Those
modifications are themselves GPL-3.0. Keeping them here means:

- **Neither product's repository contains GPL code.** Both are
  commercial, proprietary trees. A GPL-licensed file sitting unflagged
  inside one is the single most common finding in software due diligence,
  and the cheapest possible thing to avoid.
- **This repository is unambiguously GPL-3.0**, start to finish. No
  per-file analysis required to answer "what is the licence here".
- **Neither product becomes a derivative work.** ComfyUI runs as its own
  process in its own container, reachable only on loopback, and each
  product talks to it over HTTP. That is arm's-length use of a separate
  program, not linking. See `docs/gpl-compliance.md`.
- **One compliance mechanism, not two.** The duplication worth avoiding
  was never two Dockerfiles — it was two different answers to "produce
  the corresponding source", diverging quietly.

## What is here

| Path | What it is |
|---|---|
| `patches/` | The modifications, as unified diffs against a pinned upstream commit |
| `Dockerfile` | Clones ComfyUI at that commit, applies the patches, verifies they took |
| `scripts/entrypoint.sh` | Launcher. Every flag has a measured reason; the comments are the record |
| `scripts/verify.py` | Did the patches apply, and do they work on real hardware? |
| `scripts/release-source.sh` | Produces the complete corresponding source bundle |
| `docs/gpl-compliance.md` | The obligations, and how each is met |
| `LICENSE` | GNU General Public License v3 |

**Diffs, not copied files.** 243 lines of patch rather than ~2,900 lines
of vendored ComfyUI. A diff is unambiguously *our* modification, is
readable as such, and makes the source obligation trivially satisfiable —
without putting someone else's code in our tree.

**No workflow templates.** Those are product content. Each product mounts
or layers its own, so a ComfyUI bump cannot silently replace them and one
product's workflows never ship inside the other's image.

## The two modifications

**`0001-gb10-unified-memory.patch`** — memory accounting for hardware
where the CPU and GPU share one physical pool. Upstream assumes two
separate pools, so on GB10 it believes it has roughly twice the memory it
has, and reads a "free VRAM" figure depressed by reclaimable page cache.
Measured: 39.3 GB reported free against 117.7 GB actually available, the
whole gap being page cache. The patch also wires the cgroup memory limit
into the planner, so a container cap is understood as a budget.

**`0002-disable-cudnn-when-conv-is-wrong.patch`** — some cuDNN builds
return numerically incorrect convolution results on this hardware
**without raising an error**. The visible symptom is output images of
pure noise, with nothing in the logs. The patch runs one small
convolution at import, compares it against a reference, and disables
cuDNN only if the answer is wrong.

Both are guarded, reversible, and change no behaviour on hardware that is
unaffected:

| Variable | Default | Effect |
|---|---|---|
| `COMFY_GB10_UNIFIED_MEMORY` | `auto` | `0` forces upstream's two-pool accounting back on |
| `COMFY_GB10_FORCE_CUDNN` | `auto` | `1` keeps cuDNN enabled regardless of the correctness probe |

## Using it

Build and check, on the target hardware (GPU required for the real check —
`docker build` has no GPU, so the build can only prove the patches
applied):

```sh
make build      # clone at the pin, apply patches, verify --static
make verify     # the real check, with --gpus all
make source     # -> dist/comfyui-gpl-source-<commit>-<date>.tar.gz
```

Then reference the image from the product's own Compose stack:

```yaml
services:
  comfyui:
    image: comfyui-gb10:${COMFYUI_GB10_TAG:-dev}
    # the product supplies: model volume, workflow templates, network,
    # memory limits, and whatever talks to it over :8188
```

Each product keeps its own adapter — the thing that turns a product
request into a ComfyUI workflow — in its own repository, where it belongs.
Nothing in this image knows which product is calling it.

## Upstreaming

Both patches are written to be upstream-compatible: guarded, reversible by
environment variable, and no-ops on unaffected hardware. Offering them
upstream would be worth doing — GB10 owners hitting the unified-memory or
cuDNN problem currently have nothing. That is a contribution decision
rather than a compliance one: **publishing is not required** to satisfy
GPL-3.0 here, because the shipped image contains the source. See
`docs/gpl-compliance.md`.

## Changing the ComfyUI version

`COMFY_REF` in the `Dockerfile` is pinned to a commit, not a tag, because
these patches touch ComfyUI's internals and "which tree" has to be exact.

Moving it means: bump the ref, re-apply (the build fails loudly if a hunk
no longer applies, which is the point), update the upstream commit named
in `0001`'s modification notice, then `make verify` **on real hardware**.
A patch that applies cleanly can still have stopped covering what it
claims to — `verify.py`'s markers are checked by name for exactly that
reason.
