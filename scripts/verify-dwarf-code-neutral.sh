#!/usr/bin/env bash
# Self-contained guard that enabling DWARF on a prod kernel config is code-neutral.
#
# For each verified version, builds the kernel twice from the same source/tag/patches
# — WITH DWARF (the committed config) and WITHOUT DWARF (a generated reference) — with
# build metadata pinned, and asserts the boot image's loadable segments are
# byte-identical. DWARF lives only in non-loadable .debug_* sections, so a clean build
# must produce the same loadable image; a mismatch means enabling DWARF perturbed
# codegen.
#
# Usage: verify-dwarf-code-neutral.sh [version] [arch]
# With no version, verifies every x86_64 config that enables CONFIG_DEBUG_INFO_DWARF5,
# so the gate auto-tracks whatever kernel currently carries DWARF (no hardcoded
# version). x86_64 only. Two full kernel builds per version — intended for CI /
# occasional local runs, not every build.
set -euo pipefail

arch="${2:-x86_64}"
if [[ "$arch" != "x86_64" ]]; then
  echo "verify-dwarf-code-neutral: x86_64 only, skipping $arch"
  exit 0
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pin build metadata so linux_banner (.rodata, loadable) is identical across both
# builds; otherwise the embedded timestamp/builder would differ.
export KBUILD_BUILD_TIMESTAMP="2024-01-01"
export KBUILD_BUILD_USER="ci"
export KBUILD_BUILD_HOST="ci"

work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT

# Build vmlinux in the (already checked-out, patched) linux tree from a config
# derived by applying $1 (sed program) to the resolved DWARF config, and copy the
# result to $2.
build_variant() {
  local sed_prog="$1" out="$2" work
  work="$(dirname "$out")"
  sed -e "$sed_prog" "$work/dwarf.config" >"$work/variant.config"
  ( cd "$SCRIPT_DIR/linux"
    cp "$work/variant.config" .config
    make olddefconfig
    make vmlinux -j "$(nproc)"
    cp vmlinux "$out" )
}

# Verify one version: build a WITH-DWARF and a WITHOUT-DWARF kernel that differ
# only in the debug-info toggle, and assert their executable code is identical.
verify_one() {
  local version="$1"
  local work="$work_root/$version"
  mkdir -p "$work"

  # Real build: validates the shipped (IKCONFIG=y) kernel compiles, and leaves the
  # linux tree checked out at the right tag with patches applied + the resolved
  # DWARF config in linux/.config.
  echo ">>> [$version] build WITH DWARF (committed config, real build)"
  "$SCRIPT_DIR/build.sh" "$version" "$arch"
  cp "$SCRIPT_DIR/linux/.config" "$work/dwarf.config"

  # check-loadable-sections.sh compares the executable code, which is immune to the
  # per-build GNU build-id and the "#N" build counter. CONFIG_IKCONFIG must still be
  # disabled on both, though: with it on, each kernel embeds its own .config
  # (/proc/config.gz), the two configs differ by the debug-info lines, so the gzip
  # blob differs in size and shifts .init.data — moving symbols that .init.text
  # references and thus perturbing the compared code. Disabling it keeps .init.data
  # layout identical, so the only remaining difference is DWARF (non-loadable
  # .debug_*) and the executable code matches exactly.
  local ikconfig_off='s/^CONFIG_IKCONFIG=y$/# CONFIG_IKCONFIG is not set/'
  local dwarf_off='s/^CONFIG_DEBUG_INFO_DWARF5=y$/# CONFIG_DEBUG_INFO_DWARF5 is not set/;s/^# CONFIG_DEBUG_INFO_NONE is not set$/CONFIG_DEBUG_INFO_NONE=y/'

  echo ">>> [$version] build WITH DWARF, IKCONFIG off (A)"
  build_variant "$ikconfig_off" "$work/dwarf.bin"

  echo ">>> [$version] build WITHOUT DWARF, IKCONFIG off (B)"
  build_variant "${ikconfig_off};${dwarf_off}" "$work/nodwarf.bin"

  echo ">>> [$version] compare executable code"
  "$SCRIPT_DIR/scripts/check-loadable-sections.sh" "$work/dwarf.bin" "$work/nodwarf.bin"
  echo "OK: DWARF is code-neutral for ${version} (${arch})."
}

# Versions to verify: the explicit arg, else every x86_64 config enabling DWARF.
versions=()
if [[ -n "${1:-}" ]]; then
  versions=("$1")
else
  for cfg in "$SCRIPT_DIR"/configs/"$arch"/*.config; do
    [[ -e "$cfg" ]] || continue
    grep -q '^CONFIG_DEBUG_INFO_DWARF5=y' "$cfg" || continue
    v="$(basename "$cfg" .config)"
    # Skip variant configs (e.g. 6.1.158-numaemu); only plain version names ship.
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
    versions+=("$v")
  done
fi

if [[ ${#versions[@]} -eq 0 ]]; then
  echo "no ${arch} config enables CONFIG_DEBUG_INFO_DWARF5; nothing to verify"
  exit 0
fi

echo "verifying DWARF code-neutrality for: ${versions[*]}"
for v in "${versions[@]}"; do
  verify_one "$v"
done
