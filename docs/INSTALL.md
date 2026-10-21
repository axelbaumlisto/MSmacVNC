# Installing macVNC on this Mac

One rule: **there must be exactly one registered `macVNC.app` on the machine, and
its path is `/Applications/macVNC.app`.**

## Why this is not cosmetic

Every build bundle (`build-arm64`, `build-release-arm64`, `build-tsan`) and every
backup carries the same `CFBundleIdentifier`, `net.christianbeier.macVNC`.
LaunchServices registers each copy it sees, so:

- Privacy & Security lists the app several times and it is unclear which row is
  the real one;
- a Screen Recording / Accessibility grant attaches to a bundle the user never
  launches, and the installed app then comes up unable to capture;
- deleting "the duplicate" from that pane can revoke the grant that mattered.

## The only supported way to install

```bash
packaging/install_local.sh
```

It builds `build-release-arm64`, signs with the Developer ID identity (a stable
identity is what keeps the TCC grant across updates — an ad-hoc signature changes
with every rebuild), backs up the current app to `~/.macvnc-backups/`, installs,
unregisters every other macVNC bundle from LaunchServices, and launches the
result.

Never `ditto build-*/macVNC.app /Applications/`. That artefact is ad-hoc signed
and still links Homebrew dylibs.

## If duplicates appear anyway

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREG -dump 2>/dev/null | grep macVNC | grep -oE '/[^ ]*macVNC\.app' | sort -u
# expect exactly one line: /Applications/macVNC.app
$LSREG -u <every other path>
```

Keep backups in `~/.macvnc-backups/` rather than `$HOME` so Spotlight does not
index them as applications.
