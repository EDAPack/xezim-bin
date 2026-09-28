---
name: xezim
description: SystemVerilog (IEEE 1800-2017/2023) event-driven simulator with UVM and DPI-C/VPI support, installed from the xezim-bin package. Use when simulating SV/UVM designs with xezim, compiling DPI-C code against the shipped headers, using the bundled Accellera UVM, or triaging a hang, X-storm or wrong value. Also ships sv-parse, a standalone SV parser that can dump the AST as JSON.
license: MIT OR Apache-2.0
version: "0.0.0"
---

# xezim (xezim-bin package)

This skill covers the *packaged* xezim. For the full usage guide from
upstream — flags, env knobs, waveforms, performance and the debugging
workflow — read `references/upstream-guide.md`, which is taken from the same
xezim commit as the binary. Ignore its **Build** section: the package is
already built.

## What the package contains

`<prefix>` is the unpacked `xezim/` directory (the one holding `bin/xezim`).

| Path | What |
|---|---|
| `bin/xezim` | The simulator |
| `bin/sv-parse` | Standalone parser; `sv-parse --dump-json file.sv` emits the AST |
| `include/` | `svdpi.h`, `vpi_user.h`, `sv_vpi_user.h`, `veriuser.h` for DPI/VPI C code |
| `share/uvm/src` | Accellera UVM 1800.2-2020.3.2 (see `share/uvm/PROVENANCE.txt`) |
| `share/xezim/` | Upstream `README.md`, `NOTES.md` (changelog), `docs/`, `BUILD-INFO.txt` |

`xezim -V` prints the release tag and the upstream commit it was built from.

## Build configuration — know this before using the upstream guide

- **Interpreter build, no `--features jit`.** `XEZIM_JIT=1` and `XEZIM_AOT=1`
  do nothing useful with this binary; don't suggest them.
- **Not PGO-optimized.** Upstream's `build-pgo.sh` applies to source builds only.
- **DPI exports need a C compiler at run time.** A design that `export`s
  SV functions to C makes xezim build a small trampoline library with `cc`
  when the simulation starts, so `cc` must be on `PATH`.

## Running

```sh
xezim --simulate -s top design.sv tb.sv --max-time 1ms --error-exit
```

- `--max-time` has a default cap and the run silently stops there — always
  set it for long tests (bare numbers are ns).
- Add `--error-exit` in scripts/CI so `$error` fails the run.
- Runs are deterministic for a given `+seed=<n>`.

## UVM with the bundled library

```sh
UVM=<prefix>/share/uvm
xezim --simulate -s top -I $UVM/src $UVM/src/uvm_pkg.sv tb.sv +UVM_TESTNAME=my_test
```

UVM's DPI-C layer (regex matching for `uvm_config_db`/factory lookups,
command-line processing, `uvm_hdl_*` backdoor) is built into xezim, so you do
not compile `uvm_dpi.cc` and do not need `-D UVM_NO_DPI`. Add
`-D UVM_NO_DPI` only to reproduce another simulator's DPI-less behaviour.
Upstream's guide shows a `--sv2017` recipe for the public AVIP benches.

## DPI-C

```sh
cc -shared -fPIC -I <prefix>/include my_dpi.c -o my_dpi.so
xezim --simulate --dpi-lib ./my_dpi.so tb.sv
```

`--dpi-lib` is repeatable; `--vpi-lib`/`-m` loads a VPI module. Full detail:
`share/xezim/docs/dpi-guide.md`.

## When not to use xezim

- VHDL or mixed-language designs — unsupported.
- Synthesis or lint-for-synthesis — use yosys / verilator `--lint-only`.
