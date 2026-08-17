# Kimi

OpenUsage monitors the two Kimi Code accounts configured by the CLI as separate groups. Each group
shows its rolling 5-hour and 7-day Code quota.

- Credentials come from the official Kimi Code CLI under `~/.kimi-code` (or `KIMI_CODE_HOME`).
- OpenUsage resolves `default_model` through its `[models.*].provider` entry. That account is marked as
  primary and supplies the card's account and plan, matching the channel the CLI currently uses.
- Managed OAuth reads `credentials/kimi-code.json`; when its short-lived access token expires,
  OpenUsage refreshes it through Kimi's OAuth service and atomically writes the rotated access and
  refresh tokens back for the CLI. A separate static `type = "kimi"` provider reads its own `api_key`.
  Both are queried when configured.
- The groups are labeled **Kimi 官方订阅** and **Kimi 拼车key**. A missing, expired, or rejected
  credential remains visible with an explicit unavailable state.
- The plan label uses Kimi's official name for the usage API membership level (for example,
  `LEVEL_ADVANCED` appears as **Allegro**).
- OpenUsage calls `GET https://api.kimi.com/coding/v1/usages`; OAuth refresh calls use
  `POST https://auth.kimi.com/api/oauth/token`.
- Each account's two meters use the same remaining-quota fields and reset times as Kimi's quota UI. This API
  currently reports whole-number percentages; Kimi's membership page may show additional decimals.
- Kimi's monthly total is served by a browser-session-only endpoint, so it is not shown from CLI
  credentials.
- The provider is detected and enabled automatically when a usable local credential exists.

Kimi Code subscription usage is separate from the Moonshot Open Platform API balance. Refresh the
affected credential when one account group reports that it is unavailable.
