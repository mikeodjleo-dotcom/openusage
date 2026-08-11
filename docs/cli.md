# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It never launches or leaves the
menu-bar app running. A normal provider read prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON with stable scalar limits and balances.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

## Agent brief

`brief` combines the current limits with Today / Yesterday / Last 30 Days spend and the full usage
trend. JSON keeps raw values for automation; Markdown is a compact prompt-ready summary. Omitting the
format defaults to JSON.

```sh
openusage brief --json
openusage brief --markdown
openusage brief --json --force
```

The JSON schema is `openusage.brief.v1`. Its `providers` object uses the same stable resource IDs as
`/v1/limits`. Provider entries include `account` when a human label such as an email is available and
`accountId` when the provider supplies a stable identity. `spend` contains period totals plus
per-account contributions, and `trends` contains the ordered daily token points keyed by provider ID.
The Markdown form contains account identity, current percentage limits, all three spend totals,
today's per-provider breakdown, and any refresh errors.

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. Account metadata comes only from the provider's existing local login or authenticated
userinfo response; credentials and tokens never enter the output. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. Credentials are used locally and never appear in the output.

A provider argument names providers by plain string matching, exactly like the
[local HTTP API](local-http-api.md): an exact provider ID names that provider, and a family ID
(`claude`, `codex`) names every account card of that family — with one account that's exactly the one
card, so existing usage keeps working unchanged as multi-account support arrives. The output envelope
contains every matched provider; an ID that names nothing exits with an error. There is no aliasing
or account-picking logic.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments or an unknown provider, and `4` when a
refresh or local read fails.
