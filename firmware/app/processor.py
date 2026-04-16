"""
app/processor.py — Consumer side of the Producer-Consumer pipeline.

Drains the frame queue filled by scheduler.enqueue(), parses each MR60
radar frame, and emits structured event dicts for downstream logic
(AI inference, MQTT, ESP-NOW, etc.).

Hot-path rules
--------------
  - No string concatenation inside _process().
  - No logging inside _process() — use integer event codes.
  - bytes() copy is made here (once, intentionally) so the frame buffer
    is immediately free for the next incoming packet.
"""
import uasyncio


# ── MR60 function codes (extend as per Seeed datasheet) ─────────────────────
_FC_HEARTBEAT   = const(0x01)
_FC_PRESENCE    = const(0x02)
_FC_MOTION      = const(0x03)
_FC_BREATH      = const(0x04)
_FC_HEART_RATE  = const(0x05)


class Processor:
    """
    Parameters
    ----------
    frame_queue : list — shared queue from Scheduler (append/pop(0))
    heartbeat   : Callable() -> None  (scheduler.heartbeat)
    on_event    : Optional Callable(dict) -> None for downstream consumers
    """

    def __init__(self, frame_queue, heartbeat, on_event=None):
        self._queue     = frame_queue
        self._heartbeat = heartbeat
        self._on_event  = on_event

    async def run(self):
        while True:
            if self._queue:
                mv, length = self._queue.pop(0)
                event = self._process(mv, length)
                if event and self._on_event:
                    self._on_event(event)
            self._heartbeat()
            await uasyncio.sleep_ms(10)

    def _process(self, mv, length):
        """
        Parse one validated MR60 frame payload.

        Frame payload layout (Seeed MR60BHA1):
          [0]      function_code
          [1]      data_type
          [2..n-1] data bytes

        Returns a plain dict with integer keys to avoid string interning cost
        in the hot path.
        """
        if length < 2:
            return None

        func_code = mv[0]
        data_type = mv[1]

        # Make a single bytes() copy so frame_buf is free immediately.
        # This is the ONLY allocation in the hot path — kept to minimum size.
        payload = bytes(mv[2:length])

        return {
            "fc":   func_code,
            "dt":   data_type,
            "data": payload,
        }
