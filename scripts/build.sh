#!/usr/bin/env bash
# xezim-bin build driver.
#
# Builds the exact xezim commit resolved by edapack-common's resolve-inputs.py
# (passed in via $CANDIDATE_JSON, or resolved locally), so the shipped
# manifest.json truthfully records what was built. xezim is a Rust crate; there
# is no CMake layer -- this script provisions a Rust toolchain, runs cargo, lays
# out the release tree, and hands off to the shared release tail (skills,
# export.envrc, manifest, tarball).
#
# Runs both in CI (via edapack-common's reusable workflow) and locally (via
# edapack-common/scripts/local-build.sh). All transient state goes to WORK_DIR;
# the tarball + manifest land in OUT_DIR. Nothing is written into the source tree.
#
# Release layout (<prefix> = the unpacked `xezim/` directory):
#   bin/xezim, bin/sv-parse
#   include/                 svdpi.h, vpi_user.h, ... for compiling DPI/VPI code
#   share/uvm/src            Accellera UVM (point -I and uvm_pkg.sv here)
#   share/xezim/             README, NOTES, docs/, LICENSE, Cargo.lock, BUILD-INFO.txt
#   skills/, export.envrc, manifest.json   (shared release tail)
set -euo pipefail

# --- locate edapack-common --------------------------------------------------
if [ -z "${EC_COMMON:-}" ]; then
    # sibling checkout fallback for plain local runs
    _repo="$(cd "$(dirname "$0")/.." && pwd)"
    for _c in "$_repo/packages/edapack-common" "$_repo/../edapack-common"; do
        if [ -f "$_c/scripts/build-common.sh" ]; then EC_COMMON="$_c"; break; fi
    done
fi
if [ -z "${EC_COMMON:-}" ] || [ ! -f "$EC_COMMON/scripts/build-common.sh" ]; then
    echo "ERROR: edapack-common not found. Set EC_COMMON or place edapack-common beside xezim-bin." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$EC_COMMON/scripts/build-common.sh"

# The shared helpers (ec_input_get, gen-manifest, ...) run python3, which the
# manylinux2014 image only has under /opt/python -- put one on PATH first.
for _py in /opt/python/cp312-cp312/bin /opt/python/cp311-cp311/bin; do
    if [ -x "$_py/python3" ]; then export PATH="$_py:$PATH"; break; fi
done

: "${EC_PACKAGE:=xezim-bin}"
export EC_PACKAGE
ec_init_dirs
ec_prepare_candidate

os="$(uname -s)"
plat="${EC_IMAGE_NAME:-}"
case "$os" in
    Linux)  : "${plat:=linux-$(uname -m)}" ;;
    Darwin) : "${plat:=macos-$(uname -m)}" ;;
    *)      ec_die "unsupported build host: $os (xezim-bin builds Linux and macOS only)" ;;
esac

# Accellera UVM shipped under share/uvm. Same release verilator-bin ships, so a
# testbench moves between the two simulators against one library. xezim serves
# UVM's DPI-C natively, so none of verilator-bin's DPI backend prep applies.
# The 2020.3.2 asset is a tarball served with a bare '.gz' name.
: "${UVM_VERSION:=1800.2-2020.3.2}"
: "${UVM_URL:=https://www.accellera.org/images/downloads/standards/uvm/1800.2-2020.3.2%20Release.gz}"

# Rust toolchain. xezim declares rust-version 1.92 (edition 2024) and upstream
# CI builds on `stable`, so that is what we use. Override with RUST_TOOLCHAIN to
# pin a specific release.
: "${RUST_TOOLCHAIN:=stable}"

# --- provision the stock manylinux image (EC_INSTALL_DEPS=1 in CI/local) -----
if [ "${EC_INSTALL_DEPS:-0}" = "1" ] && [ "$os" = "Linux" ]; then
    # gcc/make/perl: build scripts of mimalloc (C) and libffi-sys (vendored
    # autoconf build), plus xezim's own vpi_printf shim. git: xezim's build.rs
    # stamps the commit/tag into `xezim -V`.
    yum install -y git gcc gcc-c++ make perl curl tar gzip binutils || true
fi

# --- Rust toolchain ---------------------------------------------------------
# A private rustup install under WORK_DIR, so the build does not depend on (or
# modify) whatever the host has. EC_USE_SYSTEM_RUST=1 uses the cargo on PATH.
if [ "${EC_USE_SYSTEM_RUST:-0}" != "1" ]; then
    export RUSTUP_HOME="$WORK_DIR/rust/rustup" CARGO_HOME="$WORK_DIR/rust/cargo"
    if [ ! -x "$CARGO_HOME/bin/cargo" ]; then
        ec_log "installing Rust ($RUST_TOOLCHAIN) into $WORK_DIR/rust"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
    fi
    export PATH="$CARGO_HOME/bin:$PATH"
fi
command -v cargo >/dev/null || ec_die "cargo not found"
ec_log "$(rustc --version)"

# --- resolved input commit --------------------------------------------------
xezim_sha="$(ec_input_get xezim resolved_sha)"
[ -n "$xezim_sha" ] || ec_die "missing resolved xezim SHA in candidate"
ec_log "xezim @ $xezim_sha"

# Full clone (not shallow): build.rs runs `git describe --tags` to name the
# release in `xezim -V`, which needs the tags and the history back to them.
xezim_src="$(ec_clone_input xezim https://github.com/aionhw/xezim "$xezim_sha")"

export CARGO_TARGET_DIR="$WORK_DIR/target"
# Any value skips build.rs's test-only `git clone nitronis/UVM` (it only checks
# that the variable is set). The release build never runs those tests.
export XEZIM_UVM_DIR="$WORK_DIR/no-test-uvm"

# --- build xezim ------------------------------------------------------------
# Interpreter only (no `--features jit`): the simplest configuration, and the
# one upstream's default `cargo build` produces.
#
# Cargo.lock is gitignored upstream, so crates.io dependencies float. Generate
# the lock explicitly, build --locked against it, and ship it: the tarball then
# records exactly which crate versions went in.
( cd "$xezim_src" && cargo generate-lockfile )
( cd "$xezim_src" && cargo build --release --locked --bin xezim )

# xezim-core rev actually built: the `source` of the xezim-core package in the
# lock, `git+https://github.com/aionhw/xezim-core.git?rev=fe2e897#<full-sha>`.
core_src="$(awk '/^name = "xezim-core"$/{f=1} f&&/^source = /{print; exit}' "$xezim_src/Cargo.lock" \
    | sed -e 's/^source = "//' -e 's/"$//')"
core_sha="${core_src##*#}"
[ -n "$core_sha" ] && [ "$core_sha" != "$core_src" ] || ec_die "cannot find xezim-core source in Cargo.lock"
ec_log "xezim-core @ $core_sha"

# --- build sv-parse (from the same xezim-core rev) ---------------------------
# sv-parse is a bin target of the sv-parser crate in xezim-core/xezim-parser.
# cargo cannot build a bin of a git *dependency*, so build it from a checkout of
# the exact rev xezim linked against.
core_src_dir="$(ec_clone_input xezim-core https://github.com/aionhw/xezim-core "$core_sha")"
( cd "$core_src_dir/xezim-parser" && cargo generate-lockfile \
    && cargo build --release --locked --bin sv-parse )

# --- lay out the release tree -----------------------------------------------
release_root="$WORK_DIR/release/xezim"
rm -rf "$release_root"
mkdir -p "$release_root/bin" "$release_root/share/xezim" "$release_root/share/uvm"

cp "$CARGO_TARGET_DIR/release/xezim" "$CARGO_TARGET_DIR/release/sv-parse" "$release_root/bin/"
cp -R "$xezim_src/include" "$release_root/include"
cp "$xezim_src/LICENSE" "$release_root/LICENSE"
cp "$xezim_src/README.md" "$xezim_src/NOTES.md" "$xezim_src/LICENSE" "$release_root/share/xezim/"
cp -R "$xezim_src/docs" "$release_root/share/xezim/docs"
cp "$xezim_src/Cargo.lock" "$release_root/share/xezim/Cargo.lock"

cat > "$release_root/share/xezim/BUILD-INFO.txt" <<EOF
xezim-bin ${EC_VERSION} (${EC_TRACK:-dev} track)
xezim       https://github.com/aionhw/xezim       ${xezim_sha}
xezim-core  https://github.com/aionhw/xezim-core  ${core_sha}
rustc       $(rustc --version)
features    (default; interpreter only)
uvm         Accellera ${UVM_VERSION} -> share/uvm
EOF

# --- UVM ----------------------------------------------------------------------
uvm_dl="$WORK_DIR/uvm-dl"
rm -rf "$uvm_dl"; mkdir -p "$uvm_dl"
ec_log "fetching UVM $UVM_VERSION"
curl -fsSL "$UVM_URL" -o "$uvm_dl/uvm.tar.gz"
tar -C "$uvm_dl" -xzf "$uvm_dl/uvm.tar.gz"
uvm_pkg="$(find "$uvm_dl" -path '*/src/uvm_pkg.sv' | head -1)"
[ -n "$uvm_pkg" ] || ec_die "UVM archive has no src/uvm_pkg.sv"
cp -R "$(dirname "$uvm_pkg")" "$release_root/share/uvm/src"
uvm_top="$(dirname "$(dirname "$uvm_pkg")")"
for f in LICENSE.txt LICENSE NOTICE.txt README.md release-notes.txt; do
    [ -f "$uvm_top/$f" ] && cp "$uvm_top/$f" "$release_root/share/uvm/" || true
done
cat > "$release_root/share/uvm/PROVENANCE.txt" <<EOF
Accellera UVM ${UVM_VERSION}
source: ${UVM_URL}
unmodified; only src/ (and the kit's top-level license/readme) is shipped.
EOF

# --- portability check ------------------------------------------------------
# The binaries must need nothing beyond the platform's base C/C++ runtime:
# mimalloc and libffi are compiled in (libffi via the vendored build on Linux;
# macOS links the SDK's system libffi, which every macOS has).
check_deps() {
    local bin="$1" libs bad=""
    if [ "$os" = "Linux" ]; then
        libs="$(readelf -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
        for l in $libs; do
            case "$l" in
                libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libgcc_s.so*|libutil.so*|ld-linux*) ;;
                *) bad="$bad $l" ;;
            esac
        done
    else
        libs="$(otool -L "$bin" | tail -n +2 | awk '{print $1}')"
        for l in $libs; do
            case "$l" in
                /usr/lib/*|/System/*) ;;
                *) bad="$bad $l" ;;
            esac
        done
    fi
    ec_log "$(basename "$bin") needs: $(echo $libs)"
    [ -z "$bad" ] || ec_die "$(basename "$bin") links non-system libraries:$bad"
}
check_deps "$release_root/bin/xezim"
check_deps "$release_root/bin/sv-parse"

# --- smoke test the staged tree ---------------------------------------------
# Run from a copy of tests/ in WORK_DIR: the test writes scratch files, and
# SRC_DIR is read-only in the build container.
rm -rf "$WORK_DIR/tests"
cp -R "$SRC_DIR/tests" "$WORK_DIR/tests"
XEZIM_PREFIX="$release_root" EXPECT_TAG="$(git -C "$xezim_src" describe --tags --abbrev=0 2>/dev/null || true)" \
    bash "$WORK_DIR/tests/run_smoke_test.sh"

# --- skill staging copy -----------------------------------------------------
# The shared tail reads skills and export.envrc from a source root. Hand it a
# copy of ours with the skill completed for THIS build: the version stamped
# into SKILL.md, and upstream's own usage guide (docs/xezim-skill.md, minus its
# frontmatter) at the built commit added as references/upstream-guide.md.
skill_src="$WORK_DIR/skill-src"
rm -rf "$skill_src"; mkdir -p "$skill_src"
cp -R "$SRC_DIR/scripts" "$SRC_DIR/skills" "$skill_src/"
sed -i.bak "s/^version: .*/version: \"${EC_VERSION}\"/" "$skill_src/skills/xezim/SKILL.md"
rm -f "$skill_src/skills/xezim/SKILL.md.bak"
if [ -f "$xezim_src/docs/xezim-skill.md" ]; then
    mkdir -p "$skill_src/skills/xezim/references"
    awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm' \
        "$xezim_src/docs/xezim-skill.md" > "$skill_src/skills/xezim/references/upstream-guide.md"
else
    ec_log "WARNING: upstream docs/xezim-skill.md missing; skill ships without references/upstream-guide.md"
fi

# --- shared release tail ----------------------------------------------------
ec_finalize_release "$skill_src" "$release_root" "$CANDIDATE_JSON"
tarball="xezim-${plat}-${EC_VERSION}.tar.gz"
ec_make_tarball "$release_root" "$tarball"
ec_log "build complete: $tarball"
