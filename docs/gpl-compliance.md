# GPL-3.0 compliance for the ComfyUI we ship

ComfyUI is **GPL-3.0-or-later** (its `LICENSE` is GPLv3; its file headers
say "version 3 … or any later version"). Two Cromozo products ship it,
and this repository modifies it. Four things follow. The design
accommodates all four, and `make source` turns the last one into a
command.

This file is the reference both products point at. Each keeps its own
`THIRD-PARTY-NOTICES.md` for everything else it ships.

---

## 1. The products are not derivative works

ComfyUI runs as its own process, in its own container, listening on
loopback only. Each product talks to it over HTTP. That is arm's-length
use of a separate program, not linking — so GPL-3.0 does not reach the
product code, and the products' own licensing is unaffected.

This is the load-bearing architectural fact, not an afterthought. It is
also what the FSF's own position on separate processes rests on: nothing
in either product links against, imports, or is compiled with ComfyUI.

**Do not change this without re-reading this file.** Importing any part of
ComfyUI into a product's own process would make that product a derivative
work of a GPL-3.0 program.

## 2. Our modifications are GPL-3.0, and are distributed as source

`patches/*.patch` are changes to a GPL work, so they are GPL-3.0
themselves. They are distributed as source, in this repository and inside
every image built from it (`/opt/comfyui-patch/patches/`).

Kept as **diffs rather than copied files** for two reasons. The
maintenance one is obvious. The licensing one matters more: a diff is
unambiguously *our* modification, is readable as such, and satisfies the
obligation to make the modified source available without vendoring
thousands of lines of someone else's code into a tree that is otherwise
proprietary.

## 3. The modified file says it was modified

GPL-3.0 §5(a) wants a prominent notice on a changed file, naming the
change and its date. `0001` adds that notice to the head of
`comfy/model_management.py`, above the code and below the original
copyright — so anyone opening the file in a running appliance sees
immediately that it is not upstream's, who changed it, when, and where
the diffs are.

## 4. The corresponding source is a build target, not a fire drill

```sh
make source      # -> dist/comfyui-gpl-source-<commit>-<date>.tar.gz
```

**That bundle is what to hand over if source is ever requested.** It
contains the entire ComfyUI tree as extracted from the shipped image, our
patches separately, the GPL text, the Dockerfile and entrypoint that
install and launch it, and a README giving the upstream commit and rebuild
instructions.

Three properties of it are deliberate:

**It is extracted from the image, not rebuilt from upstream.** The
obligation attaches to what was actually conveyed. A bundle regenerated
from a repository that has since moved would be a *different* work that
happens to resemble it.

**It verifies itself.** It clones upstream at the recorded commit, applies
the published patches, and diffs the result against what came out of the
image. If anything in the image is not accounted for by a published diff,
it prints the differing files and **refuses to produce a bundle** (exit
1). That check is what keeps this document honest over time — it is what
would catch a hand-edit made inside a container, or a patch that silently
stopped covering what it claims to.

**It includes the installation scripts.** GPL-3.0 §1 counts the scripts
controlling installation of a covered work as part of its Corresponding
Source, so the `Dockerfile` and `entrypoint.sh` travel with it and are
offered under the same terms. `Dockerfile` is copied *into* the image it
builds for precisely this reason — the bundle can be assembled from the
image alone, without this repository.

---

## The compliance route, stated plainly

**Because ComfyUI is Python, the appliance conveys source *with* the
object — GPL-3.0 §6(a).** `/opt/comfyui` in the image *is* the source.
The obligation is therefore satisfied at the moment of conveyance,
automatically, with no action required at delivery time.

The bundle exists so that the obligation can *also* be met on request, in
one piece, without reconstructing anything under time pressure.

### Why no public repository is needed

A question worth recording, because the instinct is that GPL means
"publish it".

GPL-3.0's obligation runs to **recipients of the work**, not to the
public. Nothing in the licence requires publication. §6(b)'s written offer
and §6(d)'s "designated place" are *alternatives* needed when you convey
object code **without** source — compiled binaries. They do not apply to
an interpreted program shipped with its own source.

So publishing is a contribution decision, on its own merits (see the
README's note on upstreaming), not a compliance requirement.

### What would change this

- **Shipping ComfyUI compiled, bundled, or byte-code-only.** Then §6(a)
  no longer applies and a written offer or a download location becomes
  necessary.
- **Importing ComfyUI code into a product process.** See §1 above.
- **Replacing ComfyUI with something else.** The obligation attaches to
  what was distributed, not to what is current — so this document should
  be revised rather than deleted, and the bundle for any version already
  conveyed must remain producible.

## If someone asks for source

1. `make source` on the box running the version they received — the pin is
   recorded in the image at `/opt/comfyui/.comfyui-ref`, so the right
   version is not a guess.
2. Check the script printed `verified: yes`. If it printed a warning
   instead, it could not reach upstream to self-check; the bundle is still
   complete and conveyable, but re-run it with network before sending.
3. Send the tarball and its `.sha256`.

No charge, no conditions, no account required. Those are the terms.
