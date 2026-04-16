"""
core/scheduler.py — Cooperative task heartbeat monitor + WDT feeder.

Design
------
Every async task registers itself by name at startup and calls
heartbeat(name) at least once per HEARTBEAT_TIMEOUT_MS.

The scheduler's own async loop checks ALL heartbeats before feeding the
hardware WDT. If any single task misses its deadline the WDT starves,
the ESP32-C3 reboots, and the fault is visible in the reset-cause register.

Frame queue
-----------
enqueue() is safe to call from micropython.schedule() (between bytecodes,
no alloc restriction) because it appends a (memoryview, int) tuple.
memoryview itself does not copy bytes — it is a zero-copy reference into
RADAR_FRAME_BUF.
"""
import uasyncio
import time

from core.memory import collect


class Scheduler:
    HEARTBEAT_TIMEOUT_MS: int = 5_000  # tasks must check in within 5 s

    def __init__(self, wdt, tasks: list) -> None:
        self._wdt        = wdt
        self._heartbeats = {t: time.ticks_ms() for t in tasks}
        # Simple list used as a queue; pops from index 0 in the consumer.
        # Keep short — Processor drains it faster than Radar fills it.
        self._queue: list = []

    # ── Public API ───────────────────────────────────────────────────────────

    @property
    def queue(self) -> list:
        return self._queue

    def heartbeat(self, task_name: str) -> None:
        """Record that *task_name* is alive. Call frequently in async tasks."""
        self._heartbeats[task_name] = time.ticks_ms()

    def enqueue(self, frame_mv, length: int) -> None:
        """
        Called from micropython.schedule() — no heap allocation allowed here.
        frame_mv is a memoryview into the pre-allocated RADAR_FRAME_BUF.
        """
        self._queue.append((frame_mv, length))

    # ── Internal ─────────────────────────────────────────────────────────────

    def _all_healthy(self) -> tuple:
        now = time.ticks_ms()
        for name, last in self._heartbeats.items():
            if time.ticks_diff(now, last) > self.HEARTBEAT_TIMEOUT_MS:
                return False, name
        return True, None

    async def run(self) -> None:
        """
        Scheduler tick: runs every second.
        Only feeds the WDT when every registered task is healthy.
        """
        while True:
            healthy, stalled = self._all_healthy()
            if healthy:
                self._wdt.feed()
            # If not healthy: WDT timeout → hardware reboot. Intentional.

            collect()           # single safe GC point for the whole system
            self.heartbeat("health")
            await uasyncio.sleep_ms(1_000)
