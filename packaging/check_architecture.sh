#!/bin/bash
# Guards ARCHITECTURE.md against drifting from the code: every module it names
# in bold must exist in src/, key design symbols must still be present, the
# document's ctest count must equal CMakeLists.txt, and the server core must
# not depend on the capture framework.
# A document that describes a previous design is worse than no document.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

# A bold run names a module only when it is a SINGLE token: "**MacVNCInput**",
# or several separated by slashes ("**NetworkAccess / NetworkCIDR**"). Bold
# PROSE always contains spaces ("**Teardown ordering**"), so splitting on
# slashes and requiring one whole token per part separates the two without a
# growing dictionary of English words - the previous rule split on every
# non-alphanumeric character, so each new bold phrase in the document invented
# a fake module and had to be appended to the skip-list by hand.
# What remains in the list is the handful of single-word bold prose.
SKIP='^(Lock|Screen|Keep|Bundle|Ordering|Teardown|Rule|True|False|Anything|Rectangles)$'
modules=$(grep -oE '\*\*[^*]+\*\*' src/ARCHITECTURE.md \
          | sed 's/\*\*//g' \
          | tr '/' '\n' \
          | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/:$//' \
          | grep -E '^[A-Z][A-Za-z0-9]{3,}$' | grep -Ev "$SKIP" | sort -u)

module_count=$(printf '%s\n' "$modules" | grep -c .)
if [ "$module_count" -lt 20 ]; then
  echo "module scan found only $module_count names - ARCHITECTURE.md unreadable or gutted"
  fail=1
fi
for name in $modules; do
  if ! compgen -G "src/$name.[hcmx]" >/dev/null; then
    echo "MISSING module named in ARCHITECTURE.md: $name"
    fail=1
  fi
done

# Design claims that must remain true. Checked against the DECLARATIONS in
# headers: a definition surviving in a .m file does not mean the seam is still
# published, which is what the document actually claims. Declaration-shaped,
# not a bare substring, so a stale comment cannot satisfy it.
check_declared() {
  if ! grep -Eq "(^|[^[:alnum:]_])$1[[:space:]]*\(|extern.*$1|@property.*$1" src/*.h 2>/dev/null; then
    echo "MISSING declaration claimed by ARCHITECTURE.md: $1"
    fail=1
  fi
}
# Every macVNC* identifier the DOCUMENT names in backticks must actually exist
# somewhere in src/. The hand-written list below is a stronger claim (those
# names must be PUBLISHED in a header); this is the blanket rule that stops the
# document from citing an API that was renamed or deleted - previously it could,
# because the checks only ever verified the script's own list.
for name in $(grep -oE '`macVNC[A-Za-z0-9]+' src/ARCHITECTURE.md | tr -d '`' | sort -u); do
  if ! grep -Eq "(^|[^[:alnum:]_])$name[[:space:]]*\(" src/*.h src/*.m src/*.c 2>/dev/null; then
    echo "ARCHITECTURE.md names an identifier that does not exist: $name"
    fail=1
  fi
done

check_declared macVNCCaptureAllowed        # core asks, never reads TCC
check_declared shouldStartServer           # one resolver owns the start decision
check_declared macVNCRegisterDefaults      # defaults live with their keys
check_declared macVNCCompositorSubmitFrame # compositing is its own module
check_declared macVNCCompositorSetScreen   # the compositor owns the screen pointer
check_declared macVNCSelectDisplays        # display choice is testable
check_declared macVNCResolveStartAdvice    # start-failure messaging is pure
check_declared macVNCCaptureSessionBuild   # the session owns ScreenCaptureKit
check_declared macVNCPlanAllowlist         # allowlist decisions are pure

# The document's own arithmetic: it claims a ctest target count, and prose
# counts drift (25 stayed while the real number moved past 28). Derived, not
# restated.
declared=$(grep -oE 'ctest` runs [0-9]+ targets' src/ARCHITECTURE.md | grep -oE '[0-9]+' | head -1)
# Count ACTIVE add_test lines: the python E2E one sits inside an OFF option.
# One add_test sits inside the OFF MACVNC_ENABLE_E2E option; subtract it so
# the enforced number matches what a plain `ctest` runs.
actual=$(( $(grep -c 'add_test(NAME' CMakeLists.txt) - $(grep -c 'if(MACVNC_ENABLE_E2E)' CMakeLists.txt) ))
if [ -n "$declared" ] && [ "$declared" != "$actual" ]; then
  echo "ARCHITECTURE.md claims $declared ctest targets, CMakeLists.txt has $actual"
  fail=1
fi

# Screen Recording status has exactly ONE reader in production code, and it is
# the preflight (never a prompt-capable API). This is the project's hardest
# permission requirement, so it is enforced, not documented.
# Count CALLS, not mentions: comments explaining the rule also name the API.
# Strip comments from every .m first.
stripped_dir=$(mktemp -d)
for f in src/*.m; do
  python3 packaging/strip_comments.py "$f" > "$stripped_dir/$(basename "$f")" || true
done
preflight_calls=$(cat "$stripped_dir"/*.m | grep -c 'CGPreflightScreenCaptureAccess()')
rm -rf "$stripped_dir"
if [ "$preflight_calls" -ne 1 ]; then
  echo "expected exactly 1 CGPreflightScreenCaptureAccess() call, found $preflight_calls"
  fail=1
fi
if grep -rq 'CGRequestScreenCaptureAccess' src/; then
  echo "src/ contains CGRequestScreenCaptureAccess - a prompt-capable API is forbidden here"
  fail=1
fi

# The server core must not depend on the capture framework: holding that
# dependency is what MacVNCCaptureSession is for. Checked against the code only,
# with comments stripped, so prose may still explain the rule. An empty
# strip result (script missing, file renamed) must FAIL, not pass vacuously:
# with the old no-pipefail pipeline it printed success while checking nothing.
core_code=$(python3 packaging/strip_comments.py src/mac.m)
if [ -z "$core_code" ]; then
  echo "strip_comments produced no output for src/mac.m - cannot check the capture-framework rule"
  fail=1
fi
if printf '%s' "$core_code" | grep -qE '(#(include|import)[[:space:]]*<ScreenCaptureKit|SCStream[A-Za-z]*|CMSampleBufferRef|CVPixelBufferRef)'; then
  echo "src/mac.m depends on ScreenCaptureKit again; it belongs in MacVNCCaptureSession"
  printf '%s' "$core_code" | grep -nE '(#(include|import)[[:space:]]*<ScreenCaptureKit|SCStream[A-Za-z]*|CMSampleBufferRef|CVPixelBufferRef)' || true
  fail=1
fi

[ $fail -eq 0 ] && echo "ARCHITECTURE.md matches the source"
exit $fail
