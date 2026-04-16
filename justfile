# ============================================================
#  pyconn — Hardened MicroPython / 60GHz mmWave Monorepo
#  Requires: uv (env) + just (task runner) + mpy-cross (binary)
#  Usage: just <recipe>
# ============================================================

set shell := ["bash", "-c"]

default:
    @just --list

# ── Configuration ────────────────────────────────────────────
PORT         := env_var_or_default("PORT",        "/dev/ttyUSB0")
BAUD         := env_var_or_default("BAUD",        "115200")
FIRMWARE_DIR := "firmware"
BUILD_DIR    := ".build"
MPY_CROSS    := env_var_or_default("MPY_CROSS",   "mpy-cross")

# ── 1. setup — create venv and install all tools via uv ──────
setup:
    uv sync --all-groups

# ── 2. doctor — verify toolchain & list serial ports ─────────
doctor:
    @echo "=== uv environment ==="
    @uv run python --version
    @uv run esptool.py version       2>/dev/null || echo "  ✗ esptool"
    @uv run mpremote --version       2>/dev/null || echo "  ✗ mpremote"
    @{{ MPY_CROSS }} --version       2>/dev/null || echo "  ✗ mpy-cross (install separately)"
    @echo "=== Serial ports ==="
    @uv run python -c "import serial.tools.list_ports; [print(' ',p.device,p.description) for p in serial.tools.list_ports.comports()]"

# ── 3. build [compile|minify|release|clean] — build pipeline ─
# just build            → compile .py → .mpy
# just build minify     → obfuscate sources into .build/minified
# just build release    → minify → compile → package
# just build clean      → remove .build/
build action="compile":
    #!/usr/bin/env bash
    set -e
    case "{{ action }}" in
        clean)
            rm -rf {{ BUILD_DIR }} && echo "→ Cleaned."
            ;;
        minify)
            echo "→ Minifying firmware sources..."
            mkdir -p {{ BUILD_DIR }}/minified
            find {{ FIRMWARE_DIR }} -name "*.py" | while read f; do
                rel="${f#{{ FIRMWARE_DIR }}/}"
                out="{{ BUILD_DIR }}/minified/${rel}"
                mkdir -p "$(dirname "$out")"
                echo "  $f → $out"
                uv run python-minifier --rename-globals --remove-annotations \
                    --remove-docstrings "$f" > "$out"
            done
            ;;
        release)
            just build minify
            echo "→ Compiling minified sources to .mpy..."
            mkdir -p {{ BUILD_DIR }}/mpy
            find {{ BUILD_DIR }}/minified -name "*.py" | while read f; do
                rel="${f#{{ BUILD_DIR }}/minified/}"
                out="{{ BUILD_DIR }}/mpy/${rel%.py}.mpy"
                mkdir -p "$(dirname "$out")"
                echo "  $f → $out"
                {{ MPY_CROSS }} -O2 "$f" -o "$out"
            done
            echo "→ Release artefacts in {{ BUILD_DIR }}/mpy/"
            ;;
        *)
            echo "→ Compiling firmware to .mpy..."
            mkdir -p {{ BUILD_DIR }}/mpy
            find {{ FIRMWARE_DIR }} -name "*.py" | while read f; do
                rel="${f#{{ FIRMWARE_DIR }}/}"
                out="{{ BUILD_DIR }}/mpy/${rel%.py}.mpy"
                mkdir -p "$(dirname "$out")"
                echo "  $f → $out"
                {{ MPY_CROSS }} -O2 "$f" -o "$out"
            done
            ;;
    esac

# ── 4. deploy [file] — push all firmware or a single file ────
# just deploy                        → full sync
# just deploy firmware/core/mem.py   → single file
deploy file="":
    #!/usr/bin/env bash
    if [ -n "{{ file }}" ]; then
        echo "→ Pushing {{ file }}..."
        uv run mpremote connect {{ PORT }} fs cp "{{ file }}" :"$(basename {{ file }})"
    else
        echo "→ Deploying all firmware to {{ PORT }}..."
        uv run mpremote connect {{ PORT }} fs cp -r {{ FIRMWARE_DIR }}/. :
    fi

# ── 5. flash [bin] — erase flash, or erase + flash a .bin ────
# just flash                  → erase only
# just flash micropython.bin  → erase + write
flash bin="":
    #!/usr/bin/env bash
    echo "→ Erasing flash on {{ PORT }}..."
    uv run esptool.py --chip esp32c3 --port {{ PORT }} --baud {{ BAUD }} erase_flash
    if [ -n "{{ bin }}" ]; then
        echo "→ Flashing {{ bin }}..."
        uv run esptool.py --chip esp32c3 --port {{ PORT }} --baud {{ BAUD }} \
            write_flash -z 0x0 "{{ bin }}"
    fi

# ── 6. connect [repl|logs|run] [arg] — interact with device ──
# just connect              → open REPL
# just connect logs         → stream serial output
# just connect run main.py  → run script on device
connect mode="repl" arg="":
    #!/usr/bin/env bash
    case "{{ mode }}" in
        logs) uv run mpremote connect {{ PORT }} repl --capture /dev/stdout ;;
        run)  uv run mpremote connect {{ PORT }} run "{{ arg }}" ;;
        *)    uv run mpremote connect {{ PORT }} repl ;;
    esac

# ── 7. device [mem|fs|ls] — query live device state ──────────
device stat="mem":
    #!/usr/bin/env bash
    case "{{ stat }}" in
        fs) uv run mpremote connect {{ PORT }} exec \
              "import uos; s=uos.statvfs('/'); print('Free KB:',s[0]*s[3]//1024,'/ Total KB:',s[0]*s[2]//1024)" ;;
        ls) uv run mpremote connect {{ PORT }} fs ls : ;;
        *)  uv run mpremote connect {{ PORT }} exec \
              "import gc; gc.collect(); print('Free:',gc.mem_free(),'Alloc:',gc.mem_alloc())" ;;
    esac

# ── 8. test [module] — run pytest, all or one module ─────────
test module="":
    #!/usr/bin/env bash
    if [ -n "{{ module }}" ]; then
        uv run pytest tests/test_{{ module }}.py -v
    else
        uv run pytest tests/ -v
    fi

# ── 9. lint — ruff check + format tools/ ─────────────────────
lint:
    uv run ruff check tools/ --fix
    uv run ruff format tools/

# ── 10. ppt [out] — generate architecture slide deck ─────────
ppt out="output/pyconn_overview.pptx":
    uv run python tools/ppt/generate_ppt.py --out {{ out }}

# ── 11. reset [soft|hard] — reboot the device ────────────────
reset type="soft":
    #!/usr/bin/env bash
    if [ "{{ type }}" = "hard" ]; then
        uv run python -c "import serial,time; s=serial.Serial('{{ PORT }}'); s.dtr=False; time.sleep(0.1); s.dtr=True; s.close()"
    else
        uv run mpremote connect {{ PORT }} reset
    fi

# ── 12. git-op <action> [arg] — branch / commit / push / log ─
# just git-op branch core/mem-defensive
# just git-op commit "fix: watchdog timeout"
# just git-op push
# just git-op log
git-op action arg="":
    #!/usr/bin/env bash
    case "{{ action }}" in
        branch) git checkout -b feature/{{ arg }} && git push -u origin feature/{{ arg }} ;;
        commit) git add -A && git commit -m "{{ arg }}" ;;
        push)   git push ;;
        log)    git --no-pager log --oneline --graph --decorate -20 ;;
        *)      echo "Usage: just git-op [branch|commit|push|log] [arg]" ;;
    esac
