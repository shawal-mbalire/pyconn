"""
core/memory.py — GC management and bytearray buffer pools.

Rules enforced here:
  • No string concatenation (use .join or pre-format at boot).
  • No allocation inside hot paths — acquire() from a pool instead.
  • GC is only triggered from designated safe points.
"""
import gc


def stats() -> dict:
    """Return heap statistics without allocating strings in the hot path."""
    free  = gc.mem_free()
    alloc = gc.mem_alloc()
    total = free + alloc
    return {
        "free":     free,
        "alloc":    alloc,
        "total":    total,
        "pct_free": free * 100 // total,
    }


def collect(force: bool = False, threshold_kb: int = 20) -> bool:
    """
    Conditionally collect garbage.
    Pass force=True at startup or after a known large deallocation.
    """
    if force or gc.mem_free() < threshold_kb * 1024:
        gc.collect()
        return True
    return False


class BufferPool:
    """
    A fixed pool of pre-allocated bytearray slots.

    Usage
    -----
        pool = BufferPool(count=4, size=256)
        mv, slot = pool.acquire()   # returns a memoryview + slot index
        if mv is None:
            # pool exhausted — drop the frame or take recovery action
            ...
        ...
        pool.release(slot)          # return to pool without allocating
    """

    def __init__(self, count: int, size: int) -> None:
        self._bufs = [bytearray(size) for _ in range(count)]
        self._free = list(range(count))
        self.size  = size

    def acquire(self):
        """Return (memoryview, slot_index) or (None, -1) if exhausted."""
        if not self._free:
            return None, -1
        idx = self._free.pop()
        return memoryview(self._bufs[idx]), idx

    def release(self, idx: int) -> None:
        """Return a slot to the pool. Caller must stop using the memoryview."""
        self._free.append(idx)

    @property
    def available(self) -> int:
        return len(self._free)
