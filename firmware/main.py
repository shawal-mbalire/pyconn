"""
main.py — Entry point for the hardened MicroPython application.

Boot order
----------
1. boot.py  runs first (MicroPython default) — allocates all static buffers.
2. main.py  runs next — wires components together and starts the async loop.

The hardware WDT is started here with an 8-second timeout.
It is ONLY fed by the Scheduler after all task heartbeats pass.
"""
import uasyncio
from machine import WDT

import boot
from core.scheduler import Scheduler
from drivers.mr60_radar import RadarDriver
from app.processor import Processor

# ── GPIO pin assignments (Seeed XIAO ESP32-C3) ──────────────────────────────
_RADAR_TX = const(21)
_RADAR_RX = const(20)


async def main():
    # Start the hardware WDT. From this point on the scheduler MUST feed it.
    wdt = WDT(timeout=8_000)

    scheduler = Scheduler(
        wdt=wdt,
        tasks=["radar", "processor", "health"],
    )

    radar = RadarDriver(
        uart_id=1,
        tx_pin=_RADAR_TX,
        rx_pin=_RADAR_RX,
        rx_buf=boot.RADAR_RX_BUF,
        frame_buf=boot.RADAR_FRAME_BUF,
        on_frame=scheduler.enqueue,
        heartbeat=lambda: scheduler.heartbeat("radar"),
    )

    processor = Processor(
        frame_queue=scheduler.queue,
        heartbeat=lambda: scheduler.heartbeat("processor"),
    )

    await uasyncio.gather(
        scheduler.run(),
        radar.run(),
        processor.run(),
    )


uasyncio.run(main())
