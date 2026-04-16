"""
boot.py — Memory pre-allocation & emergency exception buffer.

Runs before main.py. All fixed-size buffers are allocated HERE, once,
so the heap stays flat for the lifetime of the application.
"""
import gc
import micropython

# Allocate an out-of-band exception buffer FIRST, before anything else.
# This lets MicroPython raise exceptions even when the heap is 100% full.
micropython.alloc_emergency_exception_buf(100)

# ── Pre-allocated shared buffers ─────────────────────────────────────────────
# Named with ALL_CAPS so every module can import them without re-allocating.

# Raw bytes from UART DMA → written by the IRQ drain, read by the parser.
RADAR_RX_BUF: bytearray = bytearray(2048)

# Assembled frame payload → written by the state machine, read by Processor.
RADAR_FRAME_BUF: bytearray = bytearray(256)

# General-purpose scratch space for encode/decode helpers.
SCRATCH_BUF: bytearray = bytearray(64)

# ── Initial heap sweep ───────────────────────────────────────────────────────
# Run a single GC pass now to consolidate any fragmentation from imports,
# then record the baseline so health-check code can detect slow leaks.
gc.collect()
HEAP_BASELINE_FREE: int = gc.mem_free()


def maybe_collect(threshold_kb: int = 20) -> bool:
    """
    Trigger GC only when free heap drops below *threshold_kb*.
    Call this at known-safe points (e.g. inside the scheduler tick),
    never inside a hard IRQ or state-machine hot path.
    Returns True if a collection was performed.
    """
    if gc.mem_free() < threshold_kb * 1024:
        gc.collect()
        return True
    return False
