#!/usr/bin/env bash
# Reproduce a mutation kill: apply certora/mutations/<Contract>/<N>.sol over its
# @target source, run its @conf on its @rules, then restore the original source.
# Reading the verdict: the rule reported VIOLATED on the mutated source = mutant
# Killed (for a __satisfy twin the witness becomes UNSAT, also shown VIOLATED).
# The matching clean-source command is listed in the mutant's README block.
#
#   ./certora/mutations/run_mutation.sh <Contract> <N>
#   e.g. ./certora/mutations/run_mutation.sh LendMidnightRenewalCallback 16
set -u
cd "$(dirname "$0")/../.." || exit 1

CONTRACT="${1:-}"
N="${2:-}"
if [ -z "$CONTRACT" ] || [ -z "$N" ]; then
    echo "usage: $0 <Contract> <N>   (e.g. $0 LendMidnightRenewalCallback 16)"
    exit 1
fi
MUT="certora/mutations/$CONTRACT/$N.sol"
[ -f "$MUT" ] || { echo "error: $MUT not found"; exit 1; }

hdr() { sed -n "s/^ \* @$1:[[:space:]]*//p" "$MUT" | head -1; }
CONF="$(hdr conf)"
TARGET="$(hdr target)"
RULES="$(hdr rules | tr ',' ' ')"
if [ -z "$CONF" ] || [ -z "$TARGET" ] || [ -z "$RULES" ]; then
    echo "error: incomplete @conf/@target/@rules header in $MUT"
    exit 1
fi
[ -f "$CONF" ] || { echo "error: conf not found: $CONF"; exit 1; }
[ -f "$TARGET" ] || { echo "error: target not found: $TARGET"; exit 1; }
git diff --quiet -- "$TARGET" || { echo "error: $TARGET has local modifications; restore it before running"; exit 1; }

restore() {
    if [ -f "$TARGET.mutbak" ]; then
        cp "$TARGET.mutbak" "$TARGET" && rm -f "$TARGET.mutbak"
        echo "[run_mutation] restored $TARGET"
    fi
}
trap restore EXIT INT TERM

cp "$TARGET" "$TARGET.mutbak"
cp "$MUT" "$TARGET"
echo "[run_mutation] applied $MUT over $TARGET"
echo "[run_mutation] certoraRun $CONF --rule $RULES"
certoraRun "$CONF" --rule $RULES
status=$?

restore
trap - EXIT INT TERM
git diff --quiet -- "$TARGET" || { echo "error: $TARGET did not restore cleanly"; exit 1; }
echo "[run_mutation] done -- rule VIOLATED on the mutated source = mutant Killed"
exit $status
