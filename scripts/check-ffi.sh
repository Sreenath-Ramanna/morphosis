#!/usr/bin/env bash
# scripts/check-ffi.sh — the three halves of the unchecked FFI boundary.
#
# lib/src/ria/bindings.dart mirrors raw_images_api.h by hand. Field order, field
# type and enum values must match exactly, and nothing catches a mismatch at
# compile time: it surfaces at runtime as garbage pixel data or a crash.
#
#   scripts/check-ffi.sh                      all checks, default paths
#   scripts/check-ffi.sh --stamp   <header>   header digest vs tool/ria_api.sha256
#   scripts/check-ffi.sh --enums   <header>   mirrored enum values match
#   scripts/check-ffi.sh --symbols <lib.so>   every looked-up symbol is exported
#   scripts/check-ffi.sh --digest  <header>   print the digest and exit
#   scripts/check-ffi.sh --accept  <header>   re-stamp, after reconciling
#
# The stamp catches a header that has moved on. The symbol check catches the
# other direction: a lookupFunction naming something the library does not
# export, which throws only when that code path first runs.
#
# The stamp alone was not enough. It hashes the header, so it only fires when
# the *header* moves; bindings.dart falling behind a header that then sits
# still is invisible to it, and that is exactly what happened to ria_status
# and ria_resize_filter. --enums compares the values themselves.
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
     ria_resize_filter, ria_demosaic, ria_colorspace
  3. New RIA_API exports needing a lookupFunction entry, and the wrapper in
     lib/src/ria/ria.dart

Then re-stamp:  scripts/check-ffi.sh --accept
MSG
        return 1
    fi
    echo "Header digest matches the stamp (${current:0:16}...)."
}

# The enums bindings.dart mirrors, as  c_enum:DartClass  pairs. The names do
# not correspond mechanically (ria_pixel_format is RiaFormat), so the mapping
# is written down rather than guessed. A C enum absent from this list is one
# Dart has no mirror for; RiaFlip is the reverse — LibRaw orientation codes,
# which are not a ria_* enum at all.
ENUM_MAP=(
    "ria_status:RiaStatus"
    "ria_pixel_format:RiaFormat"
    "ria_transfer:RiaTransfer"
    "ria_resize_filter:RiaResizeFilter"
    "ria_demosaic:RiaDemosaic"
    "ria_colorspace:RiaColorspace"
)

# Same comment handling as digest(): the ABI is what matters, not the prose.
strip_comments() {
    sed -e 's://.*::' "$1" \
        | sed -e ':a' -e 'N' -e '$!ba' -e 's:/\*[^*]*\*\+\([^/*][^*]*\*\+\)*/::g'
}

# The numeric values of one C enum, sorted. Enumerators are required to carry
# an explicit "= n": this header writes them all that way, and an implicit one
# cannot be checked against Dart without reimplementing C's numbering rules.
header_enum_values() {
    strip_comments "$1" | awk -v want="$2" '
        /typedef[[:space:]]+enum/ { inside = 1; body = ""; next }
        inside && /^\}[[:space:]]*ria_[a-z_]+[[:space:]]*;/ {
            name = $0
            sub(/^\}[[:space:]]*/, "", name); sub(/[[:space:]]*;.*/, "", name)
            if (name == want) print body
            inside = 0; next
        }
        inside { body = body $0 "\n" }
    ' | grep -oE '=[[:space:]]*-?[0-9]+' | tr -d '= \t' | sort -n
}

# Every enumerator name in that C enum, so a missing "= n" can be reported.
header_enum_names() {
    strip_comments "$1" | awk -v want="$2" '
        /typedef[[:space:]]+enum/ { inside = 1; body = ""; next }
        inside && /^\}[[:space:]]*ria_[a-z_]+[[:space:]]*;/ {
            name = $0
            sub(/^\}[[:space:]]*/, "", name); sub(/[[:space:]]*;.*/, "", name)
            if (name == want) print body
            inside = 0; next
        }
        inside { body = body $0 "\n" }
    ' | grep -oE 'RIA_[A-Z0-9_]+' | sort -u
}

header_enum_exists() {
    strip_comments "$1" | grep -qE "^\}[[:space:]]*$2[[:space:]]*;"
}

dart_class_values() {
    awk -v want="$2" '
        $0 ~ "^abstract final class " want "[[:space:]]*\\{" { inside = 1; next }
        inside && /^\}/ { inside = 0 }
        inside && /static const int/ { print }
    ' "$1" | grep -oE '=[[:space:]]*-?[0-9]+' | tr -d '= \t' | sort -n
}

dart_class_exists() {
    grep -qE "^abstract final class $2[[:space:]]*\{" "$1"
}

check_enums() {
    local header="$1" bindings="$ROOT/lib/src/ria/bindings.dart"
    if [[ ! -f "$header" ]]; then
        echo "No header at $header." >&2
        echo "Set RAW_IMAGES_API_DIR, or clone raw_images_api beside this checkout." >&2
        return 1
    fi
    local bad=0 pair c_enum dart_class hv dv hn
    for pair in "${ENUM_MAP[@]}"; do
        c_enum="${pair%%:*}"; dart_class="${pair##*:}"

        if ! header_enum_exists "$header" "$c_enum"; then
            echo "  GONE     $c_enum is no longer in the header, but $dart_class mirrors it" >&2
            bad=$((bad + 1)); continue
        fi
        if ! dart_class_exists "$bindings" "$dart_class"; then
            echo "  MISSING  $dart_class mirrors $c_enum but is not in bindings.dart" >&2
            bad=$((bad + 1)); continue
        fi

        hv="$(header_enum_values "$header" "$c_enum")"
        hn="$(header_enum_names "$header" "$c_enum")"
        if [[ "$(wc -l <<<"$hn")" -ne "$(wc -l <<<"$hv")" ]]; then
            echo "  IMPLICIT $c_enum has an enumerator without an explicit '= n';" >&2
            echo "           give it one so it can be checked." >&2
            bad=$((bad + 1)); continue
        fi

        dv="$(dart_class_values "$bindings" "$dart_class")"
        if [[ "$hv" != "$dv" ]]; then
            echo "  DRIFT    $c_enum -> $dart_class" >&2
            echo "           header: $(tr '\n' ' ' <<<"$hv")" >&2
            echo "           dart:   $(tr '\n' ' ' <<<"$dv")" >&2
            bad=$((bad + 1)); continue
        fi
    done
    if (( bad )); then
        echo >&2
        cat >&2 <<'MSG'
Enum values in bindings.dart do not match raw_images_api.h.

These are passed across FFI as plain ints. A value that has shifted does not
fail to compile and does not throw — the C side acts on a different case than
the Dart side named, so it surfaces as the wrong filter, the wrong error, or
the wrong pixel format.

Reconcile lib/src/ria/bindings.dart against the header, then re-run.
MSG
        return 1
    fi
    echo "All ${#ENUM_MAP[@]} mirrored enums match the header."
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
    --enums)   check_enums "${2:-$DEFAULT_HEADER}" ;;
    --symbols) check_symbols "${2:-$DEFAULT_LIB}" ;;
    "")
        check_stamp "$DEFAULT_HEADER"
        check_enums "$DEFAULT_HEADER"
        check_symbols "$DEFAULT_LIB"
        ;;
    *)
        sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's:^# \?::'
        exit 1
        ;;
esac
