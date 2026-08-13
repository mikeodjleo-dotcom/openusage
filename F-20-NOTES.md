# F-20 — Kimi subscription display name

## Probe result

`GET https://api.kimi.com/coding/v1/usages`, called with the credential selected by
`KimiAuthStore`, returned HTTP 200. Its membership fragment contains only the machine level:

```json
{"user":{"membership":{"level":"LEVEL_ADVANCED"}}}
```

The logged-in Kimi Code console calls this read-only account endpoint:

```
POST https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription
```

Its response includes the customer-facing label at `subscription.goods.title`; the captured
response shape and console both identify the current subscription as:

```json
{"subscription":{"goods":{"title":"Allegro","membershipLevel":"LEVEL_ADVANCED"}}}
```

That web endpoint accepts the browser session only. Both existing `KimiAuthStore` credentials were
probed read-only and rejected there (HTTP 401): the configured API key is not a user token, and the
CLI OAuth token's signing method is not accepted. OpenUsage therefore must not read browser cookies
or add a second credential store.

## Change

- `KimiUsageMapper` maps `LEVEL_ADVANCED` to Kimi's official display name, `Allegro`.
- Unknown levels keep the previous human-readable fallback (`LEVEL_FUTURE` becomes `Future`).
- Added mapper regression coverage and documented the visible label.

## Verification

- `swift run --disable-sandbox openusage-cli brief --json --force` was attempted before the source
  change, but this Mac's Command Line Tools cannot compile `KeyboardShortcuts 3.0.1`: SwiftUI macro
  plugins `PreviewsMacros` and `SwiftUIMacros` are unavailable. The command did not produce a brief
  JSON baseline, so the requested before/after byte comparison and post-change real CLI result cannot
  be honestly claimed.
- The currently installed `/usr/local/bin/openusage` was run with the same command and reports
  `providers.kimi.plan = "Advanced"`; it is the pre-change binary, not evidence for this checkout.
- The same CLT limitation prevents the XCTest target from running. No separate `checks` executable
  target exists in this package; `Package.swift` exposes only `OpenUsage` and `openusage-cli`.

## Remaining handoff

- Rebuild with full Xcode (or a CLT toolchain that ships the SwiftUI macro plugins), then run
  `swift run openusage-cli brief --json --force`. Expect `providers.kimi.plan` to be `Allegro` and
  compare every non-Kimi provider object against a pre-change brief.
- If the installed `/usr/local/bin/openusage` still points at an older bundle, reinstall it through
  the app's CLI installer after the rebuilt app is launched.
