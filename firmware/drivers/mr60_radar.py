"""
drivers/mr60_radar.py — Non-blocking state-machine UART driver for the
Seeed Studio MR60 60GHz mmWave radar module.

Architecture
------------
  Hard IRQ -> micropython.schedule(_drain) -> State Machine -> on_frame()
                   ^ "interrupt-to-schedule" pattern

The UART IRQ fires as soon as bytes arrive. It does exactly one thing:
schedule _drain() for the next safe VM boundary. _drain() reads bytes
into the pre-allocated RX buffer without creating any new Python objects,
then feeds each byte through the state machine.

Frame format (MR60 standard)
-----------------------------
  [0x55] [0xAA] [LEN] [PAYLOAD x LEN] [CHECKSUM]
  CHECKSUM = sum(PAYLOAD bytes) & 0xFF

@micropython.native on the checksum loop compiles it to RISC-V machine
code at load time, 2-5x faster than interpreted bytecode.
"""
import uasyncio
import micropython
from machine import UART

# ── Parser states (module-level constants — zero allocation) ─────────────────
_S_WAIT_H1  = const(0)
_S_WAIT_H2  = const(1)
_S_READ_LEN = const(2)
_S_READ_PAY = const(3)
_S_VERIFY   = const(4)

_HEADER_1 = const(0x55)
_HEADER_2 = const(0xAA)


@micropython.native
def _checksum(data, length):
    """Sum-of-bytes mod 256, compiled to native RISC-V machine code."""
    s = 0
    for i in range(length):
        s = (s + data[i]) & 0xFF
    return s


class RadarDriver:
    """
    Parameters
    ----------
    uart_id   : MicroPython UART bus number (1 on ESP32-C3)
    tx_pin    : GPIO number for TX
    rx_pin    : GPIO number for RX (GPIO20 on Seeed XIAO ESP32-C3)
    rx_buf    : Pre-allocated bytearray from boot.py (RADAR_RX_BUF)
    frame_buf : Pre-allocated bytearray from boot.py (RADAR_FRAME_BUF)
    on_frame  : Callable(memoryview, length) -> None  (scheduler.enqueue)
    heartbeat : Callable() -> None  (scheduler.heartbeat)
    """

    def __init__(self, uart_id, tx_pin, rx_pin, rx_buf, frame_buf,
                 on_frame, heartbeat):
        # Hardware UART with a 2 KB kernel-level RX buffer.
        # This buffer catches bytes during any GC pause (up to ~17 ms at 115200).
        self._uart = UART(
            uart_id, baudrate=115200,
            tx=tx_pin, rx=rx_pin,
            rxbuf=2048,
        )
        self._rx_buf   = rx_buf            # bytearray(2048) from boot.py
        self._frame_buf = frame_buf        # bytearray(256)  from boot.py
        self._mv        = memoryview(frame_buf)  # zero-copy view, allocated once
        self._on_frame  = on_frame
        self._heartbeat = heartbeat

        # State machine state
        self._state       = _S_WAIT_H1
        self._payload_len = 0
        self._payload_idx = 0

        # Guard: prevent scheduling _drain() more than once at a time
        self._drain_pending = False

    # ── IRQ / schedule ───────────────────────────────────────────────────────

    def _uart_irq(self, uart):
        """
        Soft IRQ handler (hard=False).
        Runs between VM bytecodes — full Python environment available.
        Does only one thing: schedule the drain to avoid re-entrancy.
        """
        if not self._drain_pending:
            self._drain_pending = True
            micropython.schedule(self._drain, 0)

    def _drain(self, _):
        """
        Drain the UART RX buffer into the pre-allocated bytearray.
        Called by the MicroPython scheduler — never allocates new objects.
        """
        self._drain_pending = False
        n = self._uart.readinto(self._rx_buf)
        if n:
            for i in range(n):
                self._feed(self._rx_buf[i])

    # ── State machine ────────────────────────────────────────────────────────

    def _feed(self, byte):
        """Consume one byte through the parser state machine."""
        s = self._state

        if s == _S_WAIT_H1:
            if byte == _HEADER_1:
                self._state = _S_WAIT_H2

        elif s == _S_WAIT_H2:
            self._state = _S_READ_LEN if byte == _HEADER_2 else _S_WAIT_H1

        elif s == _S_READ_LEN:
            self._payload_len = byte
            self._payload_idx = 0
            self._state = _S_READ_PAY if byte > 0 else _S_WAIT_H1

        elif s == _S_READ_PAY:
            self._frame_buf[self._payload_idx] = byte
            self._payload_idx += 1
            if self._payload_idx >= self._payload_len:
                self._state = _S_VERIFY

        elif s == _S_VERIFY:
            if byte == _checksum(self._frame_buf, self._payload_len):
                # Pass a zero-copy memoryview slice — no bytes() copy needed
                self._on_frame(self._mv[:self._payload_len], self._payload_len)
            # Bad checksum: silently discard and resync
            self._state = _S_WAIT_H1

    # ── Async task ───────────────────────────────────────────────────────────

    async def run(self):
        """Register the IRQ then keep the heartbeat alive."""
        self._uart.irq(self._uart_irq, hard=False)
        while True:
            self._heartbeat()
            await uasyncio.sleep_ms(500)
