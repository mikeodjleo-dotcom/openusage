# F-66 Evidence

## Endpoint and credential-channel discovery

- Kimi usage client endpoint: `GET https://api.kimi.com/coding/v1/usages`.
- OAuth requests add `X-Msh-Platform: kimi_code_cli` and the CLI device ID when present. Static-key
  requests use the same endpoint without the OAuth-only headers.
- Read-only inspection of the local CLI configuration on 2026-08-17 found:
  - `default_model = "kimi-code/k3"`
  - `[models."kimi-code/k3"].provider = "managed:kimi-code"`
  - `providers."managed:kimi-code".oauth` points to `oauth/kimi-code`
  - a separate `providers.kimi-code-key` contains the static key
- Therefore the current CLI-effective channel is managed OAuth, labeled **Kimi 官方订阅**. The static
  provider is labeled **Kimi 拼车key**. No credential value was copied into this document.

## Redacted response fixture

Source: captured `/coding/v1/usages` response already present in this worktree at
`Tests/OpenUsageTests/Fixtures/Kimi/usages-2026-08-17.json`. User ID is redacted; the response contains
no token or API key.

```json
{
  "user": {"userId":"<redacted-user-id>","membership":{"level":"LEVEL_ADVANCED"}},
  "usage": {
    "limit":"100","used":"3","remaining":"97",
    "resetTime":"2026-08-21T12:42:44.820647Z"
  },
  "limits":[{
    "window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
    "detail":{
      "limit":"100","used":"14","remaining":"86",
      "resetTime":"2026-08-17T04:42:44.820647Z"
    }
  }],
  "parallel":{"limit":"30"},
  "totalQuota":{},
  "authentication":{"method":"METHOD_ACCESS_TOKEN","scope":"FEATURE_CODING"},
  "subType":"TYPE_PURCHASE",
  "domain":"DOMAIN_NEXUS"
}
```

## Website comparison

Website truth anchor supplied for the official account at 2026-08-17 09:10 China time:

| Window | Website | Usage endpoint fixture | Mapping decision |
| --- | --- | --- | --- |
| 5-hour Code | 11.43%, resets 12:42 | integer 14%, resets 12:42 | map the 300-minute `limits[].detail`; prefer `remaining / limit` |
| 7-day Code | 2.29%, resets 2026-08-21 20:42 | integer 3%, same reset | map top-level `usage`; prefer `remaining / limit` |
| Monthly total | 20.21%, resets 2026-08-31 | `totalQuota` is empty | do not invent a monthly value |

The reset instants and window shapes match the website. The CLI endpoint fixture reports whole-number
quota values and was captured later than the 09:10 anchor, so it cannot reproduce the website's decimal
percentages exactly. The mapper preserves the endpoint value and records this precision difference
instead of manufacturing decimals. The endpoint exposes no usable monthly fields in this fixture.

## Output contract

The Kimi snapshot carries two account entries. Each entry contains:

- `account`: `Kimi 官方订阅` or `Kimi 拼车key`
- `isPrimary`: derived from `default_model -> models.*.provider`
- `availability`: `available`, `missingCredential`, `expiredCredential`, or `requestFailed`
- provider-returned identity and plan when available
- independent `session` and `weekly` resources with `resetsAt`

The legacy top-level account/plan point at the primary entry. Limits/brief JSON adds `entries`, and the
brief Markdown table renders each account separately. Missing or expired credentials remain visible as
an unavailable entry and as explicit red rows in the Kimi card.

## Tests and mutation evidence

- Kimi test methods present: 14.
- Coverage includes managed OAuth primary, static-key primary, both-account separation, missing static
  credential, expired OAuth credential, captured-response mapping, reset instants, JSON/Markdown entry
  output, remaining-over-stale-used precedence, and 5-hour window selection by metadata.
- Mutation guards are present for:
  - changing `detail` to `quotaDetail`, which must make the mapper test throw;
  - swapping the effective provider between managed OAuth and static key, which must flip `isPrimary`
    and `loadAuth()`.
- `swiftc -frontend -parse` passed for all changed Swift sources and the Kimi test file.
- `git diff --check` passed.
- The mutation suite could not be executed because the package could not finish compiling on this
  worker; no false green result is claimed.

## Build and local CLI

Attempt 1, repository default:

```text
swift test --filter KimiProviderTests
blocked before manifest: Swift 6.3.3 compiler / Swift 6.3.2 SDK mismatch, module cache denied
```

Attempt 2, caches redirected to `/tmp`, SwiftPM sandbox disabled, MacOSX 15.4 SDK selected:

```text
dependency compilation reached OpenUsage and compiled KimiProvider.swift / KimiUsageClient.swift /
KimiUsageMapper.swift without a Kimi-specific diagnostic, then failed on repository-wide macOS 26
SwiftUI APIs (`glassEffect`, `safeAreaBar`) and Observation macro expansion incompatibility.
```

The worker has no Xcode app/toolchain matching the installed macOS 26 SDK. No new `openusage-cli`
binary was linked, so `openusage kimi` / `openusage brief --json --force` could not be run against these
changes. Fleet tooling was not available in this worker and was skipped.

WORKER-BLOCKED matching Xcode/macOS 26 Swift toolchain unavailable; tests, build, mutation run, and local CLI evidence cannot complete
