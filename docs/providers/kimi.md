# Kimi

OpenUsage tracks Kimi Code's rolling session and weekly quota in the dashboard and menu bar.

- Credentials come from the official Kimi Code CLI under `~/.kimi-code` (or `KIMI_CODE_HOME`).
- A configured Kimi Code API key is preferred; a fresh CLI OAuth credential is the fallback.
- OpenUsage calls `GET https://api.kimi.com/coding/v1/usages` and never stores the credential.
- The provider is detected and enabled automatically when a usable local credential exists.

Kimi Code subscription usage is separate from the Moonshot Open Platform API balance. Expired OAuth
credentials surface as a login error; run `kimi login` or configure a current Kimi Code API key.
