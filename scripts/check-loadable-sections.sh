#!/usr/bin/env bash
# Verify two kernel ELF images have byte-identical *executable code*.
#
# Enabling DWARF on a prod config is meant to be codegen-neutral: it only adds
# non-loadable .debug_* sections, so the machine code must be unchanged versus a
# no-DWARF build (see scripts/verify-dwarf-code-neutral.sh).
#
# We compare the executable (SHF_EXECINSTR) sections — .text and friends — rather
# than the whole loadable image, because the non-code loadable data legitimately
# differs between two independent builds and is not codegen:
#   - the GNU build-id note (.notes) is a hash over the build (it covers .debug_*,
#     so it changes when DWARF is toggled even though the code does not);
#   - the ".version" build counter ("#N" in linux_banner, .rodata/.data) increments
#     on every relink.
# The caller (verify-dwarf-code-neutral.sh) additionally builds with CONFIG_IKCONFIG
# disabled, so the embedded /proc/config.gz blob — whose gzip size depends on the
# config text, which differs by the debug-info lines — does not shift .init.data and
# the addresses that .init.text references.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <vmlinux-a> <vmlinux-b>" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Executable sections (flags "AX") of the first image. DWARF only adds non-loadable
# .debug_* sections, so the executable section set is identical between the two.
# (Plain read loop rather than mapfile/readarray to stay bash 3.2 compatible.)
secs=()
while IFS= read -r sec; do
  secs+=("$sec")
done < <(readelf -SW "$1" | grep -E ' AX ' | sed -E 's/.*\] (\.[^ ]+) .*/\1/' | sort -u)
if [[ ${#secs[@]} -eq 0 ]]; then
  echo "no executable sections found in $1" >&2
  exit 2
fi

rc=0
for s in "${secs[@]}"; do
  objcopy -O binary --only-section="$s" "$1" "$tmp/a" 2>/dev/null
  objcopy -O binary --only-section="$s" "$2" "$tmp/b" 2>/dev/null
  if ! cmp -s "$tmp/a" "$tmp/b"; then
    echo "MISMATCH: executable section $s differs between '$1' and '$2'" >&2
    rc=1
  fi
done

if [[ "$rc" -eq 0 ]]; then
  echo "OK: executable code is byte-identical (${#secs[@]} sections)"
else
  echo "Enabling DWARF must not change codegen; investigate before releasing." >&2
fi
exit "$rc"
