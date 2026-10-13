"""Did the GB10 unified-memory patches actually take effect?

Two modes, because they can only be checked in two different places:

  --static   At image build. There is no GPU during `docker build`, so this
             compiles the patched file and asserts the patch's markers are
             present. It proves the patch applied and left valid Python; it
             cannot prove the behaviour.

  (default)  At run time, with `--gpus all`. Imports ComfyUI's memory manager
             for real and asserts the decisions it made on this hardware.

Keeping these apart matters. A build-time check that *looks* like it verifies
behaviour, but cannot, is worse than no check: it reports success for an
image whose patches might be inert.
"""

from __future__ import annotations

import os
import py_compile
import sys

COMFY_ROOT = os.environ.get("COMFY_ROOT", "/opt/comfyui")
TARGET = os.path.join(COMFY_ROOT, "comfy", "model_management.py")

# Every marker the patch is responsible for introducing. If upstream ever
# refactors one of these call sites away, the patch may still apply cleanly
# while silently covering less ground — so the markers are checked by name.
MARKERS = (
    "_gb10_unified_memory",
    "UNIFIED_MEMORY = _gb10_unified_memory()",
    "comfy.system_memory.virtual_memory_available() + mem_free_torch",
    "mem_total = comfy.system_memory.virtual_memory_total()",
    "if model_size < mem_dev - minimum_inference_memory():",
    "_gb10_cudnn_conv_is_correct",
    "torch.backends.cudnn.enabled = False",
)


def static() -> int:
    with open(TARGET, encoding="utf-8") as f:
        src = f.read()
    missing = [m for m in MARKERS if m not in src]
    if missing:
        for m in missing:
            print(f"MISSING MARKER: {m}")
        return 1
    py_compile.compile(TARGET, doraise=True)
    # The patch is only coherent against the pin; record what it was applied
    # to so a mismatch is visible in the build log rather than inferred later.
    ref = os.path.join(COMFY_ROOT, ".comfyui-ref")
    tree = "unknown"
    if os.path.exists(ref):
        with open(ref) as f:
            tree = f.read().strip()
    print(f"patched tree: {tree}")
    print(f"markers present: {len(MARKERS)}/{len(MARKERS)}; file compiles")
    return 0


def runtime() -> int:
    sys.argv = [sys.argv[0]]
    sys.path.insert(0, COMFY_ROOT)
    import comfy.model_management as mm
    import torch

    ok = True

    def check(name: str, got, want=None, predicate=None) -> None:
        nonlocal ok
        if predicate is not None:
            passed = predicate(got)
        else:
            passed = got == want
        ok = ok and passed
        detail = f"(wanted {want})" if want is not None and not passed else ""
        print(f"{'PASS' if passed else 'FAIL'} {name}={got} {detail}".rstrip())

    check("unified_detected", mm.UNIFIED_MEMORY, True)

    # The cuDNN convolution defect: wrong numbers, no exception. The patch
    # decides by running a convolution, so what is asserted here is the
    # outcome — cuDNN is on only if it was proved correct on this box.
    # Without this, every rendered image is noise and nothing says why.
    conv_ok = mm._gb10_cudnn_conv_is_correct()
    print(f"info cudnn_version={torch.backends.cudnn.version()}")
    print(f"info cudnn_conv_correct={'yes' if conv_ok else 'no'}")
    check(
        "cudnn_state_matches_its_correctness",
        f"enabled={torch.backends.cudnn.enabled}",
        predicate=lambda _: torch.backends.cudnn.enabled == conv_ok,
    )

    free_dev = mm.get_free_memory(mm.get_torch_device())
    free_cpu = mm.get_free_memory(torch.device("cpu"))
    driver_free, _ = torch.cuda.mem_get_info()

    print(f"info free_device_gib={free_dev / 1024**3:.2f}")
    print(f"info free_cpu_gib={free_cpu / 1024**3:.2f}")
    print(f"info driver_free_gib={driver_free / 1024**3:.2f}")
    print(f"info total_vram_gib={float(mm.total_vram) / 1024:.2f}")
    print(f"info vram_state={mm.vram_state.name}")

    # The point of the patch: one pool reports one number. Before it, the
    # device figure was depressed by page cache (39 GB against 118 GB) and so
    # disagreed with the CPU figure for the same memory.
    check(
        "device_and_cpu_agree",
        f"{abs(free_dev - free_cpu) / 1024**3:.2f}GiB_apart",
        predicate=lambda _: abs(free_dev - free_cpu) < 4 * 1024**3,
    )

    # Where a cgroup cap is in force, the device total must be the cap, not
    # the driver's view of the whole box — that is what makes renders
    # sequential instead of OOM-killed.
    import comfy.system_memory as sysmem

    cap = sysmem.cgroup_memory_limit()
    if cap:
        print(f"info cgroup_cap_gib={cap / 1024**3:.2f}")
        check(
            "total_follows_cgroup_cap",
            f"{float(mm.total_vram) / 1024:.2f}GiB",
            predicate=lambda _: abs(float(mm.total_vram) * 1024**2 - cap) < 1024**3,
        )
    else:
        print("info cgroup_cap_gib=none (run under a cap to check this)")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(static() if "--static" in sys.argv else runtime())
