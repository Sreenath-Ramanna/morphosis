#!/usr/bin/env bash
# The one architectural rule the catalogue introduces, enforced.
#
#   Nothing outside lib/src/catalog/sqlite/ may import a SQLite package.
#
# That rule is the whole of the swap-out requirement in PLAN.md section 2. The
# contract suite checks that the interface behaves the same for every store;
# this checks that no caller has quietly reached past it. Both are needed: a
# single `import 'package:sqlite3/sqlite3.dart'` in a widget would satisfy every
# test and lose the requirement.
#
# Imports only — the string appears in prose in several files, and a comment
# explaining why the rule exists must not trip the rule.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# Matches `import 'package:sqlite3…'` and the export and conditional-import
# forms, with either quote.
PATTERN="^[[:space:]]*(import|export)[[:space:]]+['\"]package:sqlite3"

offenders=()
while IFS= read -r file; do
    case "$file" in
        ./lib/src/catalog/sqlite/*) continue ;;
    esac
    if grep -qE "$PATTERN" "$file"; then
        offenders+=("$file")
    fi
done < <(find ./lib -name '*.dart')

if (( ${#offenders[@]} )); then
    echo "SQLite is imported outside lib/src/catalog/sqlite/:" >&2
    for file in "${offenders[@]}"; do
        echo "  ${file#./}" >&2
        grep -nE "$PATTERN" "$file" | sed 's/^/      /' >&2
    done
    echo >&2
    echo "The catalogue is reached through CatalogStore. See PLAN.md section 2." >&2
    exit 1
fi

echo "SQLite is confined to lib/src/catalog/sqlite/."
