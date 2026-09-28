# xezim-bin

Binary builds of [xezim](https://github.com/aionhw/xezim), a SystemVerilog
(IEEE 1800-2017/2023) simulator with UVM and DPI-C/VPI support, for Linux
(x86_64, aarch64) and macOS (arm64). Each build also includes a copy of the
[Accellera UVM](https://www.accellera.org/downloads/standards/uvm) library,
the DPI/VPI headers and an Agent Skill.

## Release Scheme

Releases come from two automatic tracks.

**Release track** — when xezim publishes a tag newer than the last one we
built, CI builds it from that tag. The version matches upstream (`0.11.0`,
tagged `v0.11.0` here), it is published as a full release, its notes are the
section of upstream's `NOTES.md` for that version, and it becomes `latest`.
xezim tags often (five tags in the five weeks to 0.11.0), so the release
track checks for a new tag **daily**.

**Snapshot track** — a **weekly** (Sunday) build of xezim `main`, versioned
`<Cargo.toml version>.<CI run id>` (e.g. `0.11.0.32639969514`) and tagged
`v0.11.0.32639969514`. xezim bumps its `Cargo.toml` version at release time, so
a snapshot is named after the last release it follows. These are marked
pre-release and never become `latest`. A build is published only when xezim
changed since the previous snapshot.

The two tracks never both build in the same run: when a new upstream tag is
available, the release track builds it and the snapshot stands down.

So `latest` always points at a build of a tagged xezim release. Use `latest`
for stable work and a pre-release tag for top-of-trunk.

Both tracks build the same platform set and can be run by hand from the CI
workflow's *Run workflow* button, which takes a track selector and an optional
`core_ref` (any xezim tag, branch or commit).

## Platforms

| Asset | Minimum OS |
|---|---|
| `xezim-manylinux2014_x86_64-<ver>.tar.gz` | glibc 2.17 (RHEL/CentOS 7) |
| `xezim-manylinux_2_28_{x86_64,aarch64}-<ver>.tar.gz` | glibc 2.28 (RHEL 8, Debian 10, Ubuntu 18.10) |
| `xezim-manylinux_2_34_{x86_64,aarch64}-<ver>.tar.gz` | glibc 2.34 (RHEL 9, Ubuntu 22.04) |
| `xezim-macos-arm64-<ver>.tar.gz` | macOS on Apple silicon |

The binaries are self-contained apart from the system C runtime. Windows is
not built.

## What's in the tarball

```
xezim/
  bin/xezim           the simulator
  bin/sv-parse        standalone SV parser (--dump-json emits the AST)
  include/            svdpi.h, vpi_user.h, sv_vpi_user.h, veriuser.h, uvm_dpi_xezim.cc
  share/uvm/src       Accellera UVM 1800.2-2020.3.2
  share/xezim/        upstream README, NOTES (changelog), docs/, Cargo.lock, BUILD-INFO.txt
  skills/xezim/       Agent Skill (SKILL.md + upstream's usage guide)
  export.envrc        puts bin/ on PATH (direnv / ivpm)
  manifest.json       build provenance
```

`share/xezim/BUILD-INFO.txt` records the exact xezim and xezim-core commits
and the Rust compiler. `share/xezim/Cargo.lock` records every crate version:
upstream does not commit a lockfile, so this is the only record of them.

### Build configuration

- Plain `cargo build --release` — the interpreter. Not built with
  `--features jit`, and not PGO-optimized, so `XEZIM_JIT`/`XEZIM_AOT` have no
  effect.
- A design that **exports** SV functions to DPI-C makes xezim compile a small
  trampoline with `cc` at startup, so a C compiler must be on `PATH` for
  those designs (and for compiling your own DPI code).

## Using UVM

UVM's DPI-C layer is built into xezim; nothing needs compiling:

```bash
UVM=$XEZIM_PREFIX/share/uvm   # XEZIM_PREFIX = the unpacked xezim/ directory
xezim --simulate -s top -I $UVM/src $UVM/src/uvm_pkg.sv my_tb.sv +UVM_TESTNAME=my_test
```

This is the same UVM release verilator-bin ships. See
`share/xezim/docs/uvm-guide.md` for more.

## Building locally

```bash
ivpm update -a                                             # fetches edapack-common
packages/edapack-common/scripts/local-build.sh .           # manylinux_2_28_x86_64 by default
IMAGE_NAME=manylinux2014_x86_64 packages/edapack-common/scripts/local-build.sh .
core_ref=0.10.6 packages/edapack-common/scripts/local-build.sh .   # a specific xezim ref
```

On macOS, run `scripts/build.sh` directly (it installs a private Rust
toolchain under `.build/`; set `EC_USE_SYSTEM_RUST=1` to use your own).

The build ends by running `tests/run_smoke_test.sh` against the staged tree:
the version stamp, a hello-world, a DPI-C call through the shipped headers,
a UVM test against the bundled library, and `sv-parse`. It can also be run
against an unpacked release: `XEZIM_PREFIX=/path/to/xezim tests/run_smoke_test.sh`.

## License

xezim is MIT OR Apache-2.0. Accellera UVM is Apache-2.0. This packaging repo
is Apache-2.0 (see `LICENSE`).
