#!/bin/bash
# Ledger-number collision check: every `NN. [tag]` header in
# OSTMAC-PATCHES.md must be unique, except the documented §54 pair
# (turn-md5 renumbered §53→§54 after region-recording took §54; kept
# per the wave-2 dup-17/19 precedent — see the numbering note on §54).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="$ROOT/rust/ost/OSTMAC-PATCHES.md"
DUPES="$(grep -oE '^[0-9]+\. \[' "$LEDGER" | sort -t. -k1,1n | uniq -c | awk '$1 > 1 {print $2}' | tr -d '.')"
ALLOWED="54"
FAIL=0
for n in $DUPES; do
  if [ "$n" != "$ALLOWED" ]; then
    echo "DUPLICATE ledger entry: §$n"
    FAIL=1
  fi
done
COUNT="$(grep -cE '^[0-9]+\. \[' "$LEDGER")"
if [ "$FAIL" -ne 0 ]; then
  echo "ledger-number check FAILED ($COUNT entries)"
  exit 1
fi
echo "ledger-number check OK ($COUNT entries; §54 x2 allowlisted, documented)"
