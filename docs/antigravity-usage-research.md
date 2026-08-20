# Google Antigravity — per-model usage/quota research

Investigated 2026-08-18 on this machine (Antigravity IDE installed and signed in).

## Summary answer

**Yes — there is a clean, pollable local data source, and it is the best option by far.**

Antigravity's bundled Go **language server** runs a local HTTP (Connect-RPC) server on
`127.0.0.1`. It exposes an unauthenticated-from-localhost RPC,
`RetrieveUserQuotaSummary`, that returns exactly the per-model-family quota the IDE's
own usage panel shows: a **weekly** bucket and a **5-hour** bucket per model group, each
with a `remainingFraction` (0..1) and a `resetTime`. No Google OAuth, no token refresh —
the running language server already holds the credentials; you just POST to it with the
CSRF token from its own process arguments.

Verified live on this machine — real response (redacted counts are real):

```json
{"response":{"groups":[
  {"displayName":"Gemini Models",
   "description":"Models within this group: Gemini Flash, Gemini Pro",
   "buckets":[
     {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly",
      "remainingFraction":0.99549574,"resetTime":"2026-08-25T09:01:50Z",
      "description":"...it will fully refresh in 6 days, 23 hours."},
     {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h",
      "remainingFraction":0.9729743,"resetTime":"2026-08-18T14:01:50Z"}]},
  {"displayName":"Claude and GPT models",
   "description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
   "buckets":[
     {"bucketId":"3p-weekly","window":"weekly","remainingFraction":1,"resetTime":"..."},
     {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"resetTime":"..."}]}
]}}
```

Note the granularity: quota is **per model *group*, not per individual model**. "Gemini
Flash + Gemini Pro" share one weekly + one 5-hour pool; Claude/GPT-OSS share another. So
you can show "Gemini pool 99.5% left, resets in 7d" — you cannot get a separate number
for `gemini-3.7-flash` vs `gemini-pro`, because Antigravity itself doesn't track them
separately. This matches the official rate-limit model (one shared quota, consumed
proportionally to token cost).

**Why not the endpoint the dashboard already uses:** `cloudcode-pa …
:retrieveUserQuota` (the former `fetch_gemini` path in `dashboard.py`, retired and
removed 2026-08-20) is the
gemini-cli / Gemini Code Assist quota — REQUEST-count buckets for the CLI, a different
product. It 403s for Antigravity's quota because gemini-cli's public OAuth client isn't
authorized for it (verified: 403 PERMISSION_DENIED using the existing
`refresh_gemini_token` token against `:retrieveUserQuotaSummary`). Antigravity's quota
lives behind Antigravity's own signed-in credentials, reachable only through the local
language server (or by replicating its full OAuth, which is far more work). Use the local
RPC.

---

## 1. Local state on macOS

App support dir: `~/Library/Application Support/Antigravity IDE/` (the shipped IDE;
there is also a sibling `~/Library/Application Support/Antigravity/` from an earlier
build). CLI/bootstrap dirs: `~/.antigravity-ide/` and `~/.antigravity/` (each just holds
`bin/`, `extensions/`, `argv.json`). It is a VS Code fork of **Codeium/Windsurf lineage**
— the RPC namespaces are `exa.language_server_pb.*`, `exa.seat_management_pb.*`, etc.
(`exa` = Exafunction, Codeium's company).

Key file: `~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb`
(SQLite, table `ItemTable`). Relevant keys (values are protobuf wrapped in base64, not
JSON):

- `antigravityUnifiedStateSync.userStatus` — **the richest local snapshot.** Decodes to
  the signed-in profile plus a big repeated list of models: `Gemini 3.6 Flash (High/
  Medium/Low)`, `Gemini 3.5 Flash (...)`, etc., each with supported MIME types and a
  timestamp field. This is model *availability*, not live remaining quota — good for
  "which models exist", not for a live gauge.
- `antigravityUnifiedStateSync.modelCredits` — credits sentinel keys (`availableCredits`,
  `minimumCreditAmountForUsage`), values empty/near-empty on this Gemini-plan account.
- `antigravityUnifiedStateSync.oauthToken` — inner JSON is only
  `{"state":"signedIn","context":{...}}`. **No refresh token or access token stored here**
  in cleartext; the actual OAuth material is held by the language server process / OS
  keychain (`Antigravity IDE Safe Storage` genp item exists in the login keychain).
- Other `antigravityUnifiedStateSync.*` keys: `modelPreferences`, `userStatus`,
  `agentPreferences`, `browserPreferences`, `enterprisePreferences`, etc.

**Conclusion for §1:** the DB tells you *which* models/plan you have but is a stale
protobuf blob and does **not** contain a usable access token or a live-quota number. Don't
poll the DB for the gauge; poll the language server (below).

## 2. Where the UI's usage panel fetches from — the local RPC

The bundled language server binary:
`/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm`

`strings` on it confirms the quota plumbing (all first-party evidence):

- Connect-RPC method: `/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
- Underlying Google RPC + endpoint string: `.../v1internal:retrieveUserQuotaSummary`,
  proto `google.internal.cloud.code.v1internal.RetrieveUserQuota{Request,Response}`, with
  message types `QuotaSummaryGroup`, `QuotaSummaryBucket`, and fields `remaining_fraction`,
  `reset_time`, `bucket_id`, `window`.
- Upstream host comes from the process arg `--cloud_code_endpoint`
  (`https://cloudcode-pa.googleapis.com`, or `daily-cloudcode-pa.googleapis.com` for the
  daily channel). The language server is the authenticated proxy in front of it.

Running processes (from `ps`), two `language_server_macos_arm` instances, each with:
`--csrf_token <uuid> --extension_server_port <p> --app_data_dir antigravity-ide
--cloud_code_endpoint https://cloudcode-pa.googleapis.com`.

Listening ports come from `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` (several per process).
The quota RPC answers on one of them.

**Verified working call on this machine:**

```
POST http://127.0.0.1:<listen_port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
Headers: Content-Type: application/json
         X-Codeium-Csrf-Token: <uuid from --csrf_token>
         Connect-Protocol-Version: 1     # (works without it too, but send it)
Body:    {}
```

→ HTTP 200 + the JSON shown in the summary. Probing the wrong port/token gives 400/401,
so the discovery loop must try each listening port × each `--csrf_token` value until one
returns 200. (On this machine a token from one language-server PID validated against
another PID's port, so don't assume token↔port pairing — just cross-probe.)

Fallback RPCs the same server exposes (lower fidelity, same host/header pattern):
`GetUserStatus` (model quotas + prompt credits) and `GetCommandModelConfigs`.

## 3. Official Google docs on rate limits / tiers

- Plans / tiers: **https://antigravity.google/docs/plans** (also `antigravity.google/docs`).
- Google blog, higher limits for paid tiers:
  **https://blog.google/feed/new-antigravity-rate-limits-pro-ultra-subsribers/** — Pro/Ultra
  get the highest limits refreshing every 5 hours; Free gets a larger weekly-based limit.
- The model, confirmed by the live response's own `description`: *"Within each group,
  models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the
  cost of the tokens… The 5-hour limit smooths out aggregate demand… your weekly limit is
  tied to your individual tier."* This is why per-individual-model numbers don't exist —
  only per-group weekly + 5h.
- Community context on the dual-limit lockout behaviour (weekly baseline can lock you out
  even when the 5-hour bucket resets):
  https://discuss.ai.google.dev/t/google-ai-pro-antigravity-quota-shows-multi-day-lockouts-instead-of-5-hour-reset/130202
  and https://sanj.dev/post/google-antigravity-quota-problems-fix/

## 4. cloudcode-pa endpoint variants

From the binary's `strings`, the v1internal / prediction-service surface includes, beyond
the old `:retrieveUserQuota`:

- **`v1internal:retrieveUserQuotaSummary`** — the new one Antigravity uses (grouped
  weekly/5h buckets, `remainingFraction`). This is the material difference vs. the
  dashboard's former `:retrieveUserQuota` (per-model REQUEST-count buckets for gemini-cli).
- `google.cloud.businessaicode.v1beta|v1main.PredictionService/FetchQuotaStatus` and
  `businessaicode.googleapis.com/locations.fetchQuotaStatus` — a separate "business AI
  code" quota surface (enterprise/BwG), not needed here.
- Also present: `FetchAvailableModels`, `GenerateContent`, `SelfAssignLicense`,
  `SendTelemetry` under those services.

Calling `:retrieveUserQuotaSummary` **directly** against `cloudcode-pa.googleapis.com`
with the gemini-cli OAuth token returns **403 PERMISSION_DENIED** (verified). So the direct
cloud endpoint is not reachable with existing dashboard creds — the local language server
is the only practical door.

## 5. Community / source evidence (independent confirmation)

Multiple third-party tools already do exactly this — my filesystem findings match their
approach line-for-line:

- **steipete/CodexBar** — `docs/antigravity.md`
  (https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md): port discovery via
  `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>`; CSRF token from `--csrf_token` process flag;
  probe handshake `POST /exa.language_server_pb.LanguageServerService/GetUnleashData` with
  headers `X-Codeium-Csrf-Token` + `Connect-Protocol-Version: 1`; primary quota call
  `RetrieveUserQuotaSummary`, fallbacks `GetUserStatus` / `GetCommandModelConfigs`. Notes
  the CLI (`agy`) language server needs **no** token (no `--csrf_token` flag).
- **Henrik-3/AntigravityQuota** (https://github.com/Henrik-3/AntigravityQuota) —
  "automatically detects Antigravity's language server process, port, and auth token";
  per-OS process detection (`wmic` on Windows, unix tools on macOS/Linux).
- **robinebers/openusage** — `docs/providers/antigravity.md`
  (https://github.com/robinebers/openusage/blob/main/docs/providers/antigravity.md).
- **tingyi365/agy-quota** (https://github.com/tingyi365/agy-quota) — headless quota checker,
  JSON output, "no IDE required" (drives the `agy` CLI language server).
- **badrisnarayanan/antigravity-claude-proxy** — proxies Antigravity's models locally.
- Related bug thread noting the copy-of-gemini-quota trap (exactly the mistake to avoid):
  https://github.com/stablyai/orca/issues/9122

---

## Recommendation for the dashboard

Add a new provider `fetch_antigravity()` that talks to the **local language server**, not
to Google. It fits the existing "read local state, then call an API" pattern (same shape
as the Cursor provider). No new dependency — `subprocess` + `urllib` only.

Discovery + fetch (pseudocode, ~40 lines):

1. `pgrep -f language_server_macos_arm` (or parse `ps ax`), and for each PID grab its
   `--csrf_token <uuid>` from the args (may be absent for the `agy` CLI — then send no
   token).
2. For each PID, `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` → candidate `127.0.0.1:<port>`.
3. Cross-probe: for each (port, token), `POST
   http://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
   with `Content-Type: application/json`, `X-Codeium-Csrf-Token: <token>`,
   `Connect-Protocol-Version: 1`, body `{}`. First HTTP 200 wins; cache the port+token.
4. Parse `response.groups[].buckets[]`: show per group the **weekly** and **5h** buckets as
   `remainingFraction` (→ percentage) with `resetTime` for the countdown. Two gauges per
   group ("Gemini Models", "Claude and GPT models") mirrors the IDE panel and the board's
   existing rolling-reset marker.

Caveats to code around:
- If Antigravity isn't running, there's no server → report a clean "offline"/"not
  running" state, don't error (the process must be up; unlike the OAuth-file providers this
  one needs the app live).
- Don't pair token↔port; cross-probe (observed cross-PID token acceptance).
- `remainingFraction` is a fraction (1.0 = full), not a count. There is **no** per-
  individual-model number — display per group. Gemini 3.x Flash usage rolls into the
  "Gemini Models" pool.
- Ports and tokens change every app launch — always re-discover, cache only within a run.
