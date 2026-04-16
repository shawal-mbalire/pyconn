# ============================================================
#  pyconn — Hardened MicroPython / 60GHz mmWave Monorepo
#  Usage: just <recipe>
# ============================================================

# Default: list all available recipes
default:
    @just --list

# ── Configuration ────────────────────────────────────────────
PORT          := env_var_or_default("PORT",          "/dev/ttyUSB0")
BAUD          := env_var_or_default("BAUD",          "115200")
FIRMWARE_DIR  := "firmware"
TOOLS_DIR     := "tools"
DOCS_DIR      := "docs"
BUILD_DIR     := ".build"
MPY_CROSS     := env_var_or_default("MPY_CROSS",     "mpy-cross")
ESPTOOL       := env_var_or_default("ESPTOOL",       "esptool.py")
MICROPYTHON   := env_var_or_default("MICROPYTHON",   "micropython")

# ── Development Environment ──────────────────────────────────

# Install all host-side Python tooling
setup:
    @echo "→ Installing host tools..."
    pip install --upgrade esptool mpremote rshell mpy-cross pyserial

# Verify toolchain is present and show versions
doctor:
    @echo "=== Toolchain Health ==="
    @{{ ESPTOOL }} version          2>/dev/null || echo "  ✗ esptool not found"
    @mpremote --version             2>/dev/null || echo "  ✗ mpremote not found"
    @{{ MPY_CROSS }} --version      2>/dev/null || echo "  ✗ mpy-cross not found"
    @{{ MICROPYTHON }} --version    2>/dev/null || echo "  ✗ micropython (unix) not found"
    @just --version
    @echo "=== Serial Port ==="
    @python -c "import serial.tools.list_ports; [print(' ',p.device, p.description) for p in serial.tools.list_ports.comports()]"

# ── Firmware: Deploy ─────────────────────────────────────────

# Push all firmware source files to the device via mpremote
deploy:
    @echo "→ Deploying firmware to {{ PORT }}..."
    mpremote connect {{ PORT }} fs cp -r {{ FIRMWARE_DIR }}/. :

# Push a single file (usage: just push firmware/core/mem.py)
push FILE:
    @echo "→ Pushing {{ FILE }} to {{ PORT }}..."
    mpremote connect {{ PORT }} fs cp {{ FILE }} :{{ file_name(FILE) }}

# Soft-reset the device
reset:
    mpremote connect {{ PORT }} reset

# Hard-reset via DTR toggle
hard-reset:
    python -c "import serial, time; s=serial.Serial('{{ PORT }}'); s.dtr=False; time.sleep(0.1); s.dtr=True; s.close()"

# Open a REPL session on the device
repl:
    mpremote connect {{ PORT }} repl

# Run a local script on the device without uploading it
run FILE:
    mpremote connect {{ PORT }} run {{ FILE }}

# ── Firmware: Flash MicroPython Runtime ──────────────────────

# Erase the entire flash chip
erase-flash:
    @echo "→ Erasing flash on {{ PORT }}..."
    {{ ESPTOOL }} --port {{ PORT }} --baud {{ BAUD }} erase_flash

# Flash a MicroPython .bin image (usage: just flash-mp firmware.bin)
flash-mp BIN:
    @echo "→ Flashing {{ BIN }} to {{ PORT }}..."
    {{ ESPTOOL }} --chip esp32 --port {{ PORT }} --baud {{ BAUD }} \
        write_flash -z 0x1000 {{ BIN }}

# ── Build: Compile & Obfuscate ───────────────────────────────

# Compile all .py files under firmware/ to .mpy bytecode
compile:
    @echo "→ Compiling firmware to .mpy..."
    @mkdir -p {{ BUILD_DIR }}/mpy
    @find {{ FIRMWARE_DIR }} -name "*.py" | while read f; do \
        rel="$${f#{{ FIRMWARE_DIR }}/}"; \
        out="{{ BUILD_DIR }}/mpy/$${rel%.py}.mpy"; \
        mkdir -p "$$(dirname $$out)"; \
        echo "  mpy-cross $$f → $$out"; \
        {{ MPY_CROSS }} -O2 "$$f" -o "$$out"; \
    done

# Run the full production obfuscation pipeline (compile → mangle → package)
build-release:
    @echo "→ Release build pipeline..."
    @just compile
    @echo "→ Applying name mangling..."
    python {{ TOOLS_DIR }}/obfuscate.py --src {{ BUILD_DIR }}/mpy --out {{ BUILD_DIR }}/release
    @echo "→ Artefacts in {{ BUILD_DIR }}/release/"

# Remove all build artefacts
clean:
    @echo "→ Cleaning build artefacts..."
    rm -rf {{ BUILD_DIR }}

# ── Testing ──────────────────────────────────────────────────

# Run host-side unit tests (requires micropython unix port)
test:
    @echo "→ Running unit tests..."
    python -m pytest tests/ -v 2>/dev/null || {{ MICROPYTHON }} -m unittest discover -s tests -v

# Run tests for a specific module (usage: just test-module core)
test-module MODULE:
    python -m pytest tests/test_{{ MODULE }}.py -v 2>/dev/null || \
        {{ MICROPYTHON }} -m unittest tests/test_{{ MODULE }}

# ── Monitoring & Debugging ────────────────────────────────────

# Stream device logs to stdout
logs:
    mpremote connect {{ PORT }} repl --capture /dev/stdout

# Show memory stats from the running device
mem-stats:
    mpremote connect {{ PORT }} exec "import gc; gc.collect(); print('Free:', gc.mem_free(), 'Alloc:', gc.mem_alloc())"

# Show filesystem usage on the device
fs-stats:
    mpremote connect {{ PORT }} exec "import uos; st=uos.statvfs('/'); print('Free KB:', st[0]*st[3]//1024, '/ Total KB:', st[0]*st[2]//1024)"

# List files on the device
ls-device:
    mpremote connect {{ PORT }} fs ls :

# ── Documentation ────────────────────────────────────────────

# Serve docs locally (requires mkdocs)
docs-serve:
    cd {{ DOCS_DIR }} && mkdocs serve

# Build static docs site
docs-build:
    cd {{ DOCS_DIR }} && mkdocs build

# ── Git / CI Helpers ─────────────────────────────────────────

# Create and push a feature branch (usage: just branch core/mem-defensive)
branch NAME:
    git checkout -b feature/{{ NAME }}
    git push -u origin feature/{{ NAME }}

# Quick-commit all changes with a message (usage: just commit "fix: watchdog timeout")
commit MSG:
    git add -A
    git commit -m "{{ MSG }}"

# Push current branch
push-branch:
    git push

# Show a concise git log
log:
    git --no-pager log --oneline --graph --decorate -20
