#!/usr/bin/env bash
# scripts/check-ffi.sh — the two halves of the unchecked FFI boundary.
#
# lib/src/ria/bindings.dart mirrors raw_images_api.h by hand. Field order, field
# type and enum values must match exactly, and nothing catches a mismatch at
# compile time: it surfaces at runtime as garbage pixel data or a crash.
#
#   scripts/check-ffi.sh                      both checks, default paths
#   scripts/check-ffi.sh --stamp   <header>   header digest vs tool/ria_api.sha256
#   scripts/check-ffi.sh --symbols <lib.so>   every looked-up symbol is exported
#   scripts/check-ffi.sh --digest  <header>   print the digest and exit
#   scripts/check-ffi.sh --accept  <header>   re-stamp, after reconciling
#
# The stamp catches a header that has moved on. The symbol check catches the
# other direction: a lookupFunction naming something the library does not
# export, which throws only when that code path first runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/tool/ria_api.sha256"
DEFAULT_HEADER="${RAW_IMAGES_API_DIR:-$ROOT/../raw_images_api}/include/raw_images_api.h"
DEFAULT_LIB="$ROOT/build/linux/x64/release/bundle/lib/libraw_images_api.so"

# Digest the API surface, not the file: comments and whitespace change freely
# without changing the ABI, and re-stamping for a reflowed comment would train
# everyone to ignore this.
digest() {
    sed -e 's://.*::' "$1" \
        | sed -e ':a' -e 'N' -e '$!ba' -e 's:/\*[^*]*\*\+\([^/*][^*]*\*\+\)*/::g' \
        | tr -d '[:space:]' \
        | sha256sum | cut -d' ' -f1
}

check_stamp() {
    local header="$1"
    if [[ ! -f "$header" ]]; then
        echo "No header at $header." >&2
        echo "Set RAW_IMAGES_API_DIR, or clone raw_images_api beside this checkout." >&2
        return 1
    fi
    if [[ ! -f "$STAMP" ]]; then
        echo "No stamp at $STAMP — reconcile bindings.dart, then --accept." >&2
        return 1
    fi
    local current recorded
    current="$(digest "$header")"
    recorded="$(tr -d '[:space:]' < "$STAMP")"
    if [[ "$current" != "$recorded" ]]; then
        cat >&2 <<MSG
FFI DRIFT: raw_images_api.h has changed since bindings.dart was last reconciled
against it.

  header  ${current:0:16}...
  stamp   ${recorded:0:16}...

Check, in this order:
  1. Struct layouts:  ria_image, ria_decode_options, ria_metadata,
     ria_color_data, ria_histogram, ria_preview
  2. Enum values:     ria_status, ria_pixel_format, ria_transfer,
     ria_resize_filter, ria_demosaic
  3. New RIA_API exports needing a lookupFunction entry, and the wrapper in
     lib/src/ria/ria.dart

Then re-stamp:  scripts/check-ffi.sh --accept
MSG
        return 1
    fi
    echo "Header digest matches the stamp (${current:0:16}...)."
}

check_symbols() {
    local lib="$1"
    if [[ ! -f "$lib" ]]; then
        echo "No library at $lib — build first: flutter build linux --release" >&2
        return 1
    fi
    local wanted exported missing=0
    # Every ria_* string literal in the FFI layer is a symbol name: the
    # lookupFunction calls wrap across lines, so matching the call itself is
    # more fragile than matching what it asks for.
    wanted="$(grep -rhoE "'ria_[a-z0-9_]+'" "$ROOT/lib" | tr -d "'" | sort -u)"
    exported="$(nm -D --defined-only "$lib" | awk '{print $NF}' | sort -u)"
    while read -r sym; do
        [[ -n "$sym" ]] || continue
        if ! grep -qx -- "$sym" <<<"$exported"; then
            echo "  MISSING  $sym" >&2
            missing=$((missing + 1))
        fi
    done <<<"$wanted"
    if (( missing )); then
        echo >&2
        echo "$missing symbol(s) looked up by bindings.dart are not exported." >&2
        echo "Usually a public function in the C library missing its RIA_API macro." >&2
        return 1
    fi
    echo "All $(wc -l <<<"$wanted") looked-up symbols are exported by $(basename "$lib")."
}

case "${1:-}" in
    --digest)  digest "${2:-$DEFAULT_HEADER}" ;;
    --accept)
        mkdir -p "$(dirname "$STAMP")"
        digest "${2:-$DEFAULT_HEADER}" > "$STAMP"
        echo "Stamped: bindings.dart recorded as reconciled against the current header."
        ;;
    --stamp)   check_stamp "${2:-$DEFAULT_HEADER}" ;;
    --symbols) check_symbols "${2:-$DEFAULT_LIB}" ;;
    "")
        check_stamp "$DEFAULT_HEADER"
        check_symbols "$DEFAULT_LIB"
        ;;
    *)
        sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's:^# \?::'
        exit 1
        ;;
esac
