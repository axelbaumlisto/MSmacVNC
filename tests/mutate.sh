#!/bin/bash
#
# Mutation runner.
#
# Why this exists as a script instead of an ad-hoc loop: the ad-hoc version
# ran the test binary straight after `cmake --build ... >/dev/null`, so a
# mutation that failed to COMPILE left the previous, passing binary in place
# and was reported as "SURVIVED". That reads as "the test is too weak" and
# sends you off strengthening a test that was fine - and worse, it can hide a
# broken tree: the same pattern once reported "all assertions passed" for code
# that did not build at all.
#
# Rules enforced here:
#   1. the pattern must exist in the file (a typo is an error, not a survivor);
#   2. the baseline must BUILD and PASS before anything is mutated;
#   3. a mutation that does not build is an ERROR, never a survivor;
#   4. the mutated file is given a strictly newer timestamp before building -
#      make compares mtimes at ONE-SECOND granularity, so a file mutated in
#      the same second as the previous compile was silently treated as up to
#      date and the STALE binary was tested. That is what made the first
#      mutation of a run always look like a survivor;
#   5. the source is always restored, including on interrupt - AND the restored
#      tree is rebuilt and re-verified, because leaving a mutant binary behind
#      turns the next unrelated test run into a mystery failure.
#
# Usage:
#   tests/mutate.sh <build-dir> <target> <source-file> <<'EOF'
#   pattern-to-find ==> replacement ==> description
#   ...
#   EOF
set -uo pipefail

BUILD_DIR=${1:?build dir}
TARGET=${2:?ctest/build target}
SOURCE=${3:?source file to mutate}
BINARY="$BUILD_DIR/$TARGET"

PRISTINE=$(mktemp)
cp "$SOURCE" "$PRISTINE"
restore() { cp "$PRISTINE" "$SOURCE"; rm -f "$PRISTINE"; }
trap restore EXIT INT TERM

build() { cmake --build "$BUILD_DIR" --target "$TARGET" -j >/tmp/mutate_build.log 2>&1; }

# make compares mtimes at one-second granularity, so a file written in the same
# second as the last compile looks up to date and is NOT rebuilt. Every build
# that follows a source edit must go through this.
rebuild() { sleep 1; touch "$SOURCE"; build; }

if ! build; then
    echo "ERROR: baseline does not build - fix the tree before mutating"
    tail -5 /tmp/mutate_build.log
    exit 1
fi
# Via sh -c so the shell's own "Abort trap" chatter about a deliberately
# failing child goes to /dev/null with it: a killed mutant is the GOOD case.
run_quietly() { sh -c "'$BINARY' >/dev/null 2>&1" >/dev/null 2>&1; }

if ! run_quietly; then
    echo "ERROR: baseline test does not pass - nothing to mutate against"
    exit 1
fi
echo "baseline: builds and passes"

failures=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Comments start with // - '#' is the first character of every C
    # preprocessor directive, and treating those as comments silently SKIPPED
    # mutations of #define lines while still reporting success.
    case "$line" in //*) continue ;; esac

    pattern=${line%%==>*}
    rest=${line#*==>}
    replacement=${rest%%==>*}
    description=${rest#*==>}
    # trim surrounding spaces
    pattern=$(printf '%s' "$pattern" | sed 's/^ *//; s/ *$//')
    replacement=$(printf '%s' "$replacement" | sed 's/^ *//; s/ *$//')
    description=$(printf '%s' "$description" | sed 's/^ *//; s/ *$//')

    if ! PATTERN="$pattern" REPLACEMENT="$replacement" SRC="$SOURCE" \
         PRIST="$PRISTINE" python3 -c '
import os, sys
pattern = os.environ["PATTERN"]
text = open(os.environ["PRIST"]).read()
if pattern not in text:
    sys.exit(3)
open(os.environ["SRC"], "w").write(text.replace(pattern, os.environ["REPLACEMENT"], 1))
'; then
        echo "ERROR  $description"
        echo "       pattern not found: $pattern"
        failures=$((failures + 1))
        continue
    fi

    mutated_at=$(date +%s)
    if ! rebuild; then
        # A mutation stopped by a static assertion is killed at COMPILE time,
        # which is the strongest possible kill: the configuration cannot even
        # be built. Distinguish that from a pattern that simply broke the code.
        if grep -qi 'static.assert' /tmp/mutate_build.log; then
            echo "killed    $description (compile-time guard)"
        else
            echo "ERROR  $description"
            echo "       mutation does not compile (would have been a false survivor)"
            failures=$((failures + 1))
        fi
        cp "$PRISTINE" "$SOURCE"
        continue
    fi
    if [ "$(stat -f %m "$BINARY")" -lt "$mutated_at" ]; then
        echo "ERROR  $description"
        echo "       test binary is older than the mutation - stale build"
        failures=$((failures + 1))
        cp "$PRISTINE" "$SOURCE"
        continue
    fi

    if run_quietly; then
        echo "SURVIVED  $description"
        failures=$((failures + 1))
    else
        echo "killed    $description"
    fi
    cp "$PRISTINE" "$SOURCE"
done

# Leave the tree verified, not merely restored.
if ! rebuild; then
    echo "ERROR: restored source does not build"
    exit 1
fi
if ! run_quietly; then
    echo "ERROR: restored source does not pass - the tree is NOT clean"
    exit 1
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures mutation(s) survived or errored"
    exit 1
fi
echo "all mutations killed"
