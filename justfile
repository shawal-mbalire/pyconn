# ============================================================
#  pyconn — Hardened MicroPython / 60GHz mmWave Monorepo
#  Usage: just <recipe>
# ============================================================

default:
    @just --list

# ── Configuration ────────────────────────────────────────────
PORT         := env_var_or_default("PORT",        "/dev/ttyUSB0")
BAUD         := env_var_or_default("BAUD",        "115200")
FIRMWARE_DIR := "firmware"
TOOLS_DIR    := "tools"
DOCS_DIR     := "docs"
BUILD_DIR    := ".build"
MPY_CROSS    := env_var_or_default("MPY_CROSS",   "mpy-cross")
ESPTOOL      := env_var_or_default("ESPTOOL",     "esptool.py")
MICROPYTHON  := env_var_or_default("MICROPYTHON", "micropython")

# ── 1. setup — install all host-side tooling ─────────────────
setup:
    pip install --upgrade esptool mpremote mpy-cross pyserial

# ── 2. doctor — verify toolchain & list serial ports ─────────
doctor:
    @echo "=== Toolchain Health ==="
    @{{ ESPTOOL }} version       2>/dev/null || echo "  ✗ esptool"
    @mpremote --version          2>/dev/null || echo "  ✗ mpremote"
    @{{ MPY_CROSS }} --version   2>/dev/null || echo "  ✗ mpy-cross"
    @{{ MICROPYTHON }} --version 2>/dev/null || echo "  ✗ micropython (unix)"
    @echo "=== Serial Ports ==="
    @python -c "import serial.tools.list_ports; [print(' ',p.device, p.description) for p in serial.tools.list_ports.comports()]"

# ── 3. deploy [file] — push all firmware, or a single file ───
# Usage: just deploy                   (full sync)
#        just deploy firmware/core/mem.py  (single file)
deploy file="":
    #!/usr/bin/env bash
    if [ -n "{{ file }}" ]; then
        echo "→ Pushing {{ file }} to {{ PORT }}..."
        mpremote connect {{ PORT }} fs cp "{{ file }}" :"$(basename {{ file }})"
    else
        echo "→ Deploying all firmware to {{ PORT }}..."
        mpremote connect {{ PORT }} fs cp -r {{ FIRMWARE_DIR }}/. :
    fi

# ── 4. flash [bin] — erase flash, or flash a .bin image ──────
# Usage: just flash                    (erase only)
#        just flash micropython.bin    (erase + write)
flash bin="":
    #!/usr/bin/env bash
    echo "→ Erasing flash on {{ PORT }}..."
    {{ ESPTOOL }} --chip esp32 --port {{ PORT }} --baud {{ BAUD }} erase_flash
    if [ -n "{{ bin }}" ]; then
        echo "→ Flashing {{ bin }}..."
        {{ ESPTOOL }} --chip esp32 --port {{ PORT }} --baud {{ BAUD }} \
            write_flash -z 0x1000 "{{ bin }}"
    fi

# ── 5. reset [hard|soft] — reboot the device ─────────────────
reset type="soft":
    #!/usr/bin/env bash
    if [ "{{ type }}" = "hard" ]; then
        python -c "import serial,time; s=serial.Serial('{{ PORT }}'); s.dtr=False; time.sleep(0.1); s.dtr=True; s.close()"
    else
        mpremote connect {{ PORT }} reset
    fi

# ── 6. connect [repl|logs|run] — interact with device ────────
# Usage: just connect                     (open REPL)
#        just connect logs                (stream logs)
#        just connect run main.py         (run script)
connect mode="repl" arg="":
    #!/usr/bin/env bash
    case "{{ mode }}" in
        logs) mpremote connect {{ PORT }} repl --capture /dev/stdout ;;
        run)  mpremote connect {{ PORT }} run "{{ arg }}" ;;
        *)    mpremote connect {{ PORT }} repl ;;
    esac

# ── 7. build [compile|release|clean] — build pipeline ────────
# Usage: just build            (compile .py → .mpy)
#        just build release    (compile + obfuscate + package)
#        just build clean      (remove artefacts)
build action="compile":
    #!/usr/bin/env bash
    case "{{ action }}" in
        clean)
            rm -rf {{ BUILD_DIR }} && echo "→ Cleaned."
            ;;
        release)
            just build compile
            echo "→ Applying name mangling..."
            python {{ TOOLS_DIR }}/obfuscate.py --src {{ BUILD_DIR }}/mpy --out {{ BUILD_DIR }}/release
            echo "→ Artefacts in {{ BUILD_DIR }}/release/"
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

# ── 8. test [module] — run tests, all or one module ──────────
# Usage: just test             (all tests)
#        just test core        (tests/test_core.py only)
test module="":
    #!/usr/bin/env bash
    if [ -n "{{ module }}" ]; then
        python -m pytest tests/test_{{ module }}.py -v 2>/dev/null || \
            {{ MICROPYTHON }} -m unittest tests/test_{{ module }}
    else
        python -m pytest tests/ -v 2>/dev/null || \
            {{ MICROPYTHON }} -m unittest discover -s tests -v
    fi

# ── 9. device [mem|fs|ls] — query device state ───────────────
# Usage: just device           (memory stats)
#        just device fs        (filesystem usage)
#        just device ls        (list files)
device stat="mem":
    #!/usr/bin/env bash
    case "{{ stat }}" in
        fs) mpremote connect {{ PORT }} exec \
              "import uos; s=uos.statvfs('/'); print('Free KB:', s[0]*s[3]//1024, '/ Total KB:', s[0]*s[2]//1024)" ;;
        ls) mpremote connect {{ PORT }} fs ls : ;;
        *)  mpremote connect {{ PORT }} exec \
              "import gc; gc.collect(); print('Free:', gc.mem_free(), 'Alloc:', gc.mem_alloc())" ;;
    esac

# ── 10. ppt [out] — generate architecture slide deck ─────────
# Usage: just ppt
#        just ppt slides/demo.pptx
ppt out="output/pyconn_overview.pptx":
    pip install -q -r tools/ppt/requirements.txt
    python tools/ppt/generate_ppt.py --out {{ out }}

# ── 11. docs [serve|build] — documentation site ──────────────
docs action="serve":
    #!/usr/bin/env bash
    cd {{ DOCS_DIR }}
    if [ "{{ action }}" = "build" ]; then mkdocs build; else mkdocs serve; fi

# ── 11. git-op <action> [arg] — branch/commit/push/log ───────
# Usage: just git-op branch core/mem-defensive
#        just git-op commit "fix: watchdog timeout"
#        just git-op push
#        just git-op log
git-op action arg="":
    #!/usr/bin/env bash
    case "{{ action }}" in
        branch) git checkout -b feature/{{ arg }} && git push -u origin feature/{{ arg }} ;;
        commit) git add -A && git commit -m "{{ arg }}" ;;
        push)   git push ;;
        log)    git --no-pager log --oneline --graph --decorate -20 ;;
        *)      echo "Usage: just git-op [branch|commit|push|log] [arg]" ;;
    esac
