#!/bin/bash
# Guards ARCHITECTURE.md against drifting from the code: every module it names
# in bold must exist in src/, and key design symbols must still be present.
# A document that describes a previous design is worse than no document.
set -u
cd "$(dirname "$0")/.."
fail=0

# Bold names that look like module identifiers (CamelCase, no spaces).
modules=$(grep -oE '\*\*[A-Za-z][A-Za-z0-9]+\*\*' src/ARCHITECTURE.md \
          | tr -d '*' | grep -E '^[A-Z]' | sort -u)
for name in $modules; do
  if ! compgen -G "src/$name.[hcm]" >/dev/null; then
    echo "MISSING module named in ARCHITECTURE.md: $name"
    fail=1
  fi
done

# Design claims that must remain true. Checked against the DECLARATIONS in
# headers: a definition surviving in a .m file does not mean the seam is still
# published, which is what the document actually claims.
check_declared() {
  if ! grep -rq "$1" src/*.h 2>/dev/null; then
    echo "MISSING declaration claimed by ARCHITECTURE.md: $1"
    fail=1
  fi
}
check_declared macVNCCaptureAllowed        # core asks, never reads TCC
check_declared shouldStartServer           # one resolver owns the start decision
check_declared macVNCRegisterDefaults      # defaults live with their keys
check_declared macVNCCompositorSubmitFrame # compositing is its own module
check_declared macVNCSelectDisplays        # display choice is testable
check_declared macVNCResolveStartAdvice    # start-failure messaging is pure
check_declared macVNCCaptureSessionStart   # capture streams are one unit

[ $fail -eq 0 ] && echo "ARCHITECTURE.md matches the source"
exit $fail
