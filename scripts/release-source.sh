#!/usr/bin/env bash
# Produce the Corresponding Source for the modified ComfyUI we ship.
#
# ComfyUI is GPL-3.0-or-later and this project modifies it, so anyone we
# convey the appliance to is entitled to the complete source of that modified
# work. This builds that bundle as a standalone artefact, so the obligation
# can be met by handing over a file rather than by reconstructing anything
# under time pressure.
#
# **The source is taken out of the image, not rebuilt from upstream.** That
# distinction is the whole point: the obligation attaches to what was actually
# conveyed. A bundle regenerated from a repository that has since moved would
# be a *different* work that happens to resemble it.
#
# The bundle is then independently verified: clone upstream at the recorded
# commit, apply `patches/`, and diff against what came out of the
# image. If those differ, our published diffs do not fully describe our
# modifications — which would mean the patches are not the whole truth, and
# that is exactly the thing worth catching before a release rather than after.
#
# Runs where the image is (the DGX). Needs docker, git and network for the
# verification clone; the bundle itself is produced without network.
set -euo pipefail

IMAGE="${COMFY_IMAGE:-comfyui-gb10:dev}"
OUT_DIR="${OUT_DIR:-$HOME/comfyui-patch/dist}"
UPSTREAM_URL="https://github.com/comfyanonymous/ComfyUI.git"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { printf '[gpl-source] %s\n' "$*"; }
fail() { printf '[gpl-source] %s\n' "$*" >&2; exit 1; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "$IMAGE not built (make comfy-build)"

# ---------------------------------------------------------------- extract ---
say "extracting the source as shipped in $IMAGE"
CID=$(docker create "$IMAGE" /bin/true)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bundle"
docker cp "$CID:/opt/comfyui"          "$WORK/bundle/comfyui"
docker cp "$CID:/opt/comfyui-patch/patches" "$WORK/bundle/patches"

REF=$(cat "$WORK/bundle/comfyui/.comfyui-ref")
SHORT="${REF:0:12}"
say "upstream commit: $REF"

# `.git` is a partial clone and not part of the Corresponding Source;
# `__pycache__` is build output. Both are dropped so the bundle is source.
rm -rf "$WORK/bundle/comfyui/.git"
find "$WORK/bundle/comfyui" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true

# GPL §1: the Corresponding Source includes the scripts used to control
# installation. For a container that is the Dockerfile and the entrypoint, so
# they travel with the bundle. See the licensing note written into README.md.
mkdir -p "$WORK/bundle/install"
docker cp "$CID:/opt/comfyui-patch/entrypoint.sh" "$WORK/bundle/install/entrypoint.sh"
docker cp "$CID:/opt/comfyui-patch/Dockerfile" "$WORK/bundle/install/Dockerfile"

[ -f "$WORK/bundle/comfyui/LICENSE" ] || fail "no LICENSE in the extracted tree — refusing to publish"
cp "$WORK/bundle/comfyui/LICENSE" "$WORK/bundle/LICENSE"

# ----------------------------------------------------------------- verify ---
# Does upstream-at-the-pin plus our published diffs reproduce what we ship?
say "verifying the published diffs reproduce it"
VERIFY_OK=no
if git clone --quiet --filter=blob:none "$UPSTREAM_URL" "$WORK/upstream" 2>/dev/null; then
  git -C "$WORK/upstream" checkout --quiet "$REF"
  for p in "$WORK/bundle/patches"/*.patch; do
    git -C "$WORK/upstream" apply "$p" || fail "patch $(basename "$p") does not apply to $SHORT"
  done
  rm -rf "$WORK/upstream/.git"
  find "$WORK/upstream" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
  # .comfyui-ref is written by the build, not by upstream or the patches.
  if diff -r -q \
      --exclude=.comfyui-ref \
      "$WORK/upstream" "$WORK/bundle/comfyui" > "$WORK/diff.txt" 2>&1; then
    VERIFY_OK=yes
    say "verified: the patches account for every difference from upstream"
  else
    say "DIFFERENCES between upstream+patches and the shipped tree:"
    sed 's/^/    /' "$WORK/diff.txt" >&2
    fail "the published diffs do not fully describe the shipped source. Fix before release."
  fi
else
  say "WARNING: could not reach upstream; bundle produced but NOT verified"
fi

# ----------------------------------------------------------------- readme ---
STAMP=$(date -u +%Y-%m-%d)
cat > "$WORK/bundle/README.md" <<EOF
# ComfyUI — complete corresponding source, as modified and shipped

This is the source of the ComfyUI that the appliance
runs, **as shipped**, provided under the GNU General Public License version 3
or (at your option) any later version. The full licence text is in \`LICENSE\`.

Produced: $STAMP
Upstream: ComfyUI commit \`$REF\` (tag v0.39.2), $UPSTREAM_URL
Verified reproducible from upstream + \`patches/\`: **$VERIFY_OK**

## What is here

| Path | What it is |
|---|---|
| \`comfyui/\` | The complete ComfyUI source tree as it exists in the shipped image, modifications included |
| \`patches/\` | Our modifications on their own, as unified diffs against the upstream commit above |
| \`install/\` | The Dockerfile and entrypoint used to build and launch it |
| \`LICENSE\` | GNU General Public License v3 |

## The modifications

Two changes, both to \`comfy/model_management.py\`, which carries a notice of
modification at the top of the file as GPL-3.0 §5(a) requires:

1. \`0001-gb10-unified-memory.patch\` — memory accounting for hardware where the
   CPU and GPU share one physical memory pool (NVIDIA GB10). Upstream assumes
   two separate pools, which on this hardware means it believes it has roughly
   twice the memory it has, and reads a "free VRAM" figure that is depressed
   by reclaimable page cache.

2. \`0002-disable-cudnn-when-conv-is-wrong.patch\` — some cuDNN builds return
   numerically incorrect convolution results on this hardware *without raising
   an error*; the visible symptom is output images of pure noise. This runs a
   single small convolution at import, compares it against a reference, and
   disables cuDNN only if the answer is wrong.

Both are offered upstream-compatible: they are guarded, reversible by
environment variable, and change no behaviour on hardware that is unaffected.

## Rebuilding

\`\`\`sh
git clone $UPSTREAM_URL && cd ComfyUI
git checkout $REF
git apply /path/to/patches/*.patch
\`\`\`

The result is byte-identical to \`comfyui/\` here, which is what the
"Verified" line above records.

## A note on \`install/\`

\`Dockerfile\` and \`entrypoint.sh\` are ours rather than ComfyUI's. They
are included because GPL-3.0 §1 counts the scripts that control installation
of the covered work as part of its Corresponding Source, and because without
them this source would be materially harder to build and run as we run it.
To the extent they form part of the Corresponding Source, they are offered
under the same GPL-3.0-or-later terms.

Nothing else in the appliance is derived from ComfyUI. The rest of the system
is separate software that communicates with this program over a network
socket.
EOF

# ---------------------------------------------------------------- package ---
mkdir -p "$OUT_DIR"
NAME="comfyui-gpl-source-${SHORT}-${STAMP}"
rm -rf "${OUT_DIR:?}/$NAME" "$OUT_DIR/$NAME.tar.gz" "$OUT_DIR/$NAME.tar.gz.sha256"
cp -a "$WORK/bundle" "$OUT_DIR/$NAME"
tar -czf "$OUT_DIR/$NAME.tar.gz" -C "$OUT_DIR" "$NAME"
( cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

say "bundle:   $OUT_DIR/$NAME"
say "tarball:  $OUT_DIR/$NAME.tar.gz  ($(du -h "$OUT_DIR/$NAME.tar.gz" | cut -f1))"
say "sha256:   $(cut -d' ' -f1 "$OUT_DIR/$NAME.tar.gz.sha256")"
say "verified: $VERIFY_OK"
