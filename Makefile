# comfyui-patch — build, verify, and produce the GPL corresponding source.
#
# GB10 hardware is required for anything real, so every target can run either
# locally (if you are on the box) or over ssh. Set DGX to a host to use the
# latter:
#
#   make build                 # build here
#   make build DGX=dgx-1       # build there
#
# `docker build` has no GPU, so `build` can only prove the patches applied.
# `verify` is what proves they work. Keeping those apart is deliberate: a
# build-time check that looks like it verifies behaviour, but cannot, reports
# success for an image whose patches might be inert.

IMAGE   ?= comfyui-gb10:dev
DGX     ?=
CTX     ?= ~/comfyui-patch/build
OUT_DIR ?= dist

# Run a command here or there, depending on whether DGX is set.
ifeq ($(strip $(DGX)),)
  RUN = bash -c
  REMOTE = no
else
  RUN = ssh $(DGX)
  REMOTE = yes
endif

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "comfyui-patch — ComfyUI for GB10, and its GPL layer"
	@echo
	@echo "  make build     clone at the pin, apply patches, verify --static"
	@echo "  make verify    the real check, needs --gpus all on GB10"
	@echo "  make source    the GPL corresponding-source bundle -> $(OUT_DIR)/"
	@echo "  make check     lint the patches and scripts (no docker, no GPU)"
	@echo
	@echo "  IMAGE=$(IMAGE)"
	@echo "  DGX=$(if $(strip $(DGX)),$(DGX),<unset — running locally>)"

# --------------------------------------------------------------------- build ---

.PHONY: sync
sync:
ifeq ($(REMOTE),yes)
	@ssh $(DGX) 'rm -rf $(CTX) && mkdir -p $(CTX)'
# COPYFILE_DISABLE and the excludes keep macOS AppleDouble (`._*`) files out of
# the build context. They are invisible to the build — shell globs skip leading
# dots, so `*.patch` never matched them — but they were copied into the image
# and then into the GPL source bundle, which is junk to hand a third party and
# an odd thing to find in a licence release.
	@COPYFILE_DISABLE=1 tar --exclude='._*' --exclude='.DS_Store' \
	  --exclude='__pycache__' --exclude='$(OUT_DIR)' \
	  -czf - Dockerfile patches scripts 2>/dev/null \
	  | ssh $(DGX) 'tar xzf - -C $(CTX) 2>/dev/null'
	@echo "build context synced to $(DGX):$(CTX)"
else
	@echo "local build — no sync needed"
endif

.PHONY: build
build: sync
ifeq ($(REMOTE),yes)
	@ssh $(DGX) 'cd $(CTX) && docker build -t $(IMAGE) .'
else
	@docker build -t $(IMAGE) .
endif
	@echo "built $(IMAGE)"

# Separate from the build on purpose — see the header comment.
.PHONY: verify
verify:
	@$(RUN) 'docker run --rm --gpus all --ipc=host --entrypoint python \
	  $(IMAGE) /opt/comfyui-patch/verify.py'

# --------------------------------------------------------------------- source ---

# Produces the complete corresponding source of the modified ComfyUI we ship,
# and FAILS if our published diffs do not fully account for what is in the
# image. See docs/gpl-compliance.md.
.PHONY: source
source:
ifeq ($(REMOTE),yes)
	@ssh $(DGX) 'mkdir -p ~/comfyui-patch/scripts'
	@rsync -az scripts/release-source.sh $(DGX):~/comfyui-patch/scripts/
	@ssh $(DGX) 'COMFY_IMAGE=$(IMAGE) bash ~/comfyui-patch/scripts/release-source.sh'
	@mkdir -p $(OUT_DIR)
	@scp -q $(DGX):'~/comfyui-patch/dist/comfyui-gpl-source-*.tar.gz*' $(OUT_DIR)/
else
	@OUT_DIR=$(PWD)/$(OUT_DIR) COMFY_IMAGE=$(IMAGE) bash scripts/release-source.sh
endif
	@ls -la $(OUT_DIR)/
	@echo "hand this over if source is ever requested — docs/gpl-compliance.md"

# The notice embedded in 0001 (and therefore in every shipped source bundle)
# names `make comfy-source`, and ecobillz's own Makefile uses that name. Kept
# as an alias so both stay true.
.PHONY: comfy-source comfy-build comfy-verify
comfy-source: source
comfy-build: build
comfy-verify: verify

# ---------------------------------------------------------------------- check ---

# Everything that can be checked without docker or a GPU. Cheap enough to run
# before every commit.
.PHONY: check
check:
	@python3 scripts/check_patches.py
	@python3 -m py_compile scripts/verify.py && echo "verify.py: compiles"
	@for f in scripts/*.sh; do bash -n "$$f" && echo "$$f: valid bash"; done
	@rm -rf scripts/__pycache__

.PHONY: clean
clean:
	@rm -rf $(OUT_DIR) scripts/__pycache__
