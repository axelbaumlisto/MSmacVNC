# macVNC GUI Network Picker Security — TDD Plan

## Goal

Add GUI-managed IPv4 network access policy without launchctl/env hacks and without Tailscale-specific CLI dependency.

Users choose active network connections / CIDRs that may connect. The server only sees resolved policy: bind IPv4 + client access mode + allowlist CIDRs.

## Non-goals v1

- IPv6 allowlist. Disable IPv6 listener in every mode.
- Hostname/DNS allowlist.
- Tailscale CLI integration.
- Selecting inactive networks without a current IPv4/CIDR.

## Security model

- `clientAccessMode` is explicit:
  - `allowList` — allow only `allowedClients` CIDRs; empty list is invalid/fail-closed.
  - `allowAllConfirmed` — allow all IPv4 clients; requires explicit GUI confirmation.
  - `failClosed` — open no listener.
- Empty `allowedClients` never silently means allow all unless `clientAccessMode=allowAllConfirmed`.
- Broad CIDRs (`0.0.0.0/0`, `100.64.0.0/10`) require explicit confirmation in GUI.
- Tailscale-like detection = `100.64.0.0/10` membership only; label as `CGNAT/Tailscale-like`, never silently broaden.
- Env overrides are resolved in one place only (`NetworkPolicyResolver`), and cannot silently weaken GUI policy. `mac.m` must not call `getenv()` for listen/allowlist.

## Architecture

### 1. `NetworkAccess` pure C

Files:
- `src/NetworkAccess.h`
- `src/NetworkAccess.c`
- `tests/test_network_access.c`

Responsibilities:
- parse IPv4 and IPv4/CIDR;
- parse allowlist text;
- match client IPv4 against allowlist;
- detect broad allow-all CIDRs;
- max 64 entries.

No Cocoa, LibVNCServer, getifaddrs, NSUserDefaults.

### 2. `NetworkCIDR` pure C

Files:
- `src/NetworkCIDR.h`
- `src/NetworkCIDR.c`
- `tests/test_network_cidr.c`

Responsibilities:
- derive `network/prefix` from IPv4 + netmask;
- reject invalid/non-contiguous masks;
- detect CGNAT/Tailscale-like IPv4 (`100.64.0.0/10`).

### 3. `NetworkPolicyResolver` pure C

Files:
- `src/NetworkPolicyResolver.h`
- `src/NetworkPolicyResolver.c`
- `tests/test_network_policy_resolver.c`

Inputs: plain structs representing persisted GUI state, optional env overrides, and selected/resolved network rows.

Outputs:
- bind address string;
- access mode;
- resolved allowlist string;
- envOverrideActive flag;
- fail-closed error string.

Rules:
- unknown mode fail-closed;
- selected/custom mode needs valid IPv4;
- allowList needs non-empty valid allowlist;
- allowAllConfirmed may use empty allowlist;
- empty `MACVNC_ALLOWED_CLIENTS` cannot clear non-empty GUI allowlist;
- resolver is the only env override owner.

### 4. Network inventory/model seam

Files optional:
- `src/NetworkInventory.h`
- `src/NetworkInventory.c`
- `tests/test_network_inventory.c`

Responsibilities:
- build GUI rows from injected interface snapshots;
- active IPv4 rows get derived CIDR;
- inactive rows are read-only/no CIDR;
- CGNAT/Tailscale-like rows are labeled/warned but not auto-broadened.

Actual `getifaddrs()` adapter may stay in AppDelegate, but deterministic row building must be testable.

### 5. Server (`mac.m`)

- Consumes resolved globals/structs only.
- Parses allowlist before `rfbInitServer`; fail closed on invalid.
- Disables IPv6 always in v1 (`ipv6port=0`).
- Rejects disallowed clients in `newClient` before auth/capture.

### 6. GUI (`AppDelegate.m`)

- Preferences shows port/password, listen mode, active network rows, inactive read-only rows if cheap, manual CIDR.
- Save validates via resolver before persisting.
- Copy address uses actual bind address.
- Status shows bind address/mode and whether allowlist/env override is active.
- First run/default migration must not silently expose all interfaces + allow all.

## TDD order

1. `NetworkAccess` tests: parser/matcher/broad-CIDR edge cases.
2. `NetworkCIDR` tests: CIDR math and CGNAT detection.
3. `NetworkPolicyResolver` tests: defaults, invalid modes, env precedence, allow-all confirmation, too-long values.
4. `NetworkInventory` tests: fake active/inactive rows and stale selected network behavior.
5. Server black-box tests:
   - invalid allowlist => no listener;
   - denied client closed before auth/capture log;
   - allowed client handshakes;
   - bind modes listen on expected IPv4;
   - IPv6 `::1` does not connect.
6. GUI implementation + manual smoke.
7. Developer-ID installed/notarized smoke with saved prefs and TCC.

## Verification

- `cmake --build ... -j`
- `ctest --test-dir ... --output-on-failure`
- explicit Python black-box tests if not registered in CTest
- `ctest -N` confirms new tests are included
- notarized installed app smoke after release build
