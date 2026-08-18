# GitHub Copilot & xAI Grok — per-user subscription-quota research

Investigated 2026-08-18 on this machine. Same question shape as the Antigravity
research: for each provider, is there a **pollable per-user subscription quota** (local
credential + endpoint, no org-admin, no paid API key) a dashboard can hit every ~20 min?

---

## VERDICTS

### GitHub Copilot — **YES (verified live on this machine).**
- **Mechanism:** read the `gho_` OAuth token from `~/.config/github-copilot/apps.json`,
  `GET https://api.github.com/copilot_internal/user` with `Authorization: token <gho_…>`.
  Response contains `quota_snapshots` (`premium_interactions`, `chat`, `completions`), each
  with `percent_remaining`, `remaining`, `entitlement`, plus a top-level
  `quota_reset_date` (first of the month). This is the exact shape the dashboard needs.
- **Caveat:** the endpoint is **undocumented/internal** (GitHub explicitly declines to offer
  a *supported* public individual-usage API — see §Copilot-4). It works today and is what
  VS Code / CodexBar / openusage use, but it can change without notice. No org-admin, no
  paid key — the editor's own token is enough.
- **This machine's account is a legacy "individual" plan** → `premium_interactions` has
  `has_quota:false, entitlement:0`; only `chat` (200) and `completions` (2000) are live. A
  modern Pro/Pro+ account returns `premium_interactions.entitlement` = 300 / 1500. Code must
  pick the lane where `has_quota:true`.

### xAI Grok — **PARTIAL (pollable, but nothing installed here, and not the chat-message limit).**
- **Mechanism (if the Grok CLI is installed + `grok login` done):** token from
  `~/.grok/auth.json` →
  `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` with
  `Authorization: Bearer <token>` + `x-xai-token-auth: xai-grok-cli`. Returns
  `creditUsagePercent`, `onDemandUsed/onDemandCap`, reset from `currentPeriod.end`.
- **Three blockers:** (1) **Not installed on this machine** — no `~/.grok`, no Grok app, no
  CLI. Zero to poll until the user installs Grok Build CLI and logs in with a SuperGrok /
  X Premium+ subscription. (2) The clean RPC (`x.ai/billing` over `grok agent stdio`) is
  **disabled server-side** (`-32601 Method not found` in grok 0.1.210); only the REST
  fallback works. (3) What's pollable is the **Grok Code/CLI monthly credit pool**, *not*
  the SuperGrok **chat** message allowance (the "~100–150 msgs / 4h" everyone quotes). Those
  chat rolling-window limits have **no** per-user endpoint reachable with a plain token —
  the grok.com gRPC-web billing call needs a browser Web-Key-Exchange keypair + cookies.
- **Bottom line:** a real pollable source exists and matches our pattern, but it's
  contingent on the coding CLI being present and only reports coding-credit %, not chat %.

---

## GitHub Copilot — details

### Copilot-1. Quota model (official)
Premium-request monthly allowances, reset **on the 1st of each month** regardless of billing
date: **Free 50, Pro 300, Pro+ 1500** (Business 300/user, Enterprise 1000/user). Billing for
premium requests started 2025-06-18 on GitHub.com. Overage $0.04/request. All plans move to
usage-based "GitHub AI Credits" on 2026-06-01.
Sources: <https://docs.github.com/en/copilot/concepts/billing/copilot-requests>,
<https://github.blog/news-insights/company-news/github-copilot-is-moving-to-usage-based-billing/>,
<https://github.blog/news-insights/company-news/changes-to-github-copilot-individual-plans/>.

### Copilot-2. Per-user endpoint — VERIFIED LIVE
`GET https://api.github.com/copilot_internal/user`, header `Authorization: token <gho_…>`
(plus `Editor-Version` / `User-Agent`, cosmetic). Real response on this machine (secrets and
sku/tracking fields stripped):

```json
{ "login": "Kamilkov", "copilot_plan": "individual",
  "quota_reset_date": "2026-09-01", "quota_reset_date_utc": "2026-09-01T00:00:00.000Z",
  "quota_snapshots": {
    "chat":                 {"has_quota": true,  "entitlement": 200,  "remaining": 200,  "percent_remaining": 100.0},
    "completions":          {"has_quota": true,  "entitlement": 2000, "remaining": 2000, "percent_remaining": 100.0},
    "premium_interactions": {"has_quota": false, "entitlement": 0,    "remaining": 0,    "percent_remaining": 0.0}
  }}
```

Each snapshot also has `overage_count`, `overage_permitted`, `quota_remaining` (float),
`unlimited`, `quota_reset_at`, `credits_used`, `timestamp_utc`. `percent_remaining` +
`quota_reset_date` = everything the gauge needs. **This is per-user and needs no org scope.**

The response also advertises `endpoints.api = https://api.individual.githubcopilot.com`.
There is a token-exchange endpoint (`GET /copilot_internal/v2/token` → short-lived Copilot
bearer) used for the completions service, but it is **not** needed for quota — the raw `gho_`
token reads `/copilot_internal/user` directly.

### Copilot-3. Local filesystem (this machine)
- `~/.config/github-copilot/apps.json` — **the credential.** One entry keyed
  `github.com:Ov23liV9UpD7Rnfnskm3` with `{user:"Kamilkov", oauth_token:"gho_…"(40 chars),
  githubAppId}`. This is the token that works above. (Older Copilot builds used `hosts.json`
  with the same schema; this install uses `apps.json`.)
- Also present: `versions.json`, `copilot-eclipse.db`, `Kamilkov/pref.json` (prefs, no creds).
- `~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/` exists (chat
  agent caches, embeddings) — no separate token needed; the `apps.json` token is shared.
- Editors installed: VS Code, Cursor. No token in the keychain for this (it's a plaintext
  file, mode 600).

### Copilot-4. Prior art
- **steipete/CodexBar** — `docs/copilot.md`
  (<https://github.com/steipete/CodexBar/blob/main/docs/copilot.md>): reads the OAuth token,
  `GET https://api.github.com/copilot_internal/user`, `Authorization: token <…>`, displays
  `quota_snapshots.premium_interactions` percent (secondary: `chat`). Confirms "reset dates
  not provided" on older responses (this machine's response *does* include
  `quota_reset_date` now). Issue #1258 covers Business token-billed seats showing 0%.
- **robinebers/openusage** (+ fork **Noisemaker111/openusage-opencode**
  `docs/providers/copilot.md`) — same endpoint/field set; exposes a local
  `127.0.0.1:6736/v1/usage` aggregator. <https://github.com/robinebers/openusage>
- GitHub's own position that no *supported* public individual API exists:
  <https://github.com/orgs/community/discussions/185848>.

### Copilot integration sketch (matches existing provider pattern)
```python
import json, os, time, urllib.request
from datetime import datetime, timezone

def fetch_copilot():
    apps = json.load(open(os.path.expanduser("~/.config/github-copilot/apps.json")))
    tok = next(iter(apps.values()))["oauth_token"]          # gho_… (or hosts.json on older installs)
    req = urllib.request.Request(
        "https://api.github.com/copilot_internal/user",
        headers={"Authorization": f"token {tok}",
                 "Editor-Version": "vscode/1.90",
                 "User-Agent": "GithubCopilot/1.0"})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    snaps = d.get("quota_snapshots", {})
    # prefer premium_interactions when the plan actually has it, else chat
    snap = snaps.get("premium_interactions")
    if not (snap and snap.get("has_quota")):
        snap = snaps.get("chat") or snaps.get("completions")
    reset = d.get("quota_reset_date_utc")                   # "2026-09-01T00:00:00.000Z"
    reset_ts = datetime.fromisoformat(reset.replace("Z", "+00:00")).timestamp() if reset else None
    return {"pct_used": round(100 - snap["percent_remaining"], 1),
            "remaining": snap["remaining"], "entitlement": snap["entitlement"],
            "window": "monthly", "reset": reset_ts, "plan": d.get("copilot_plan")}

# self-check: assert 0 <= fetch_copilot()["pct_used"] <= 100
```
Skipped: the `v2/token` exchange (not needed for quota) and Business/Enterprise seat handling.
Add when a Business seat (token-billed, entitlement 0 but real usage) needs the AI-credits
counter — CodexBar #1258.

---

## xAI Grok — details

### Grok-5. Subscription tiers & limits (official-ish)
- **SuperGrok** $30/mo, **X Premium+** $40/mo, **SuperGrok Heavy** (higher). Chat limits are
  **rolling-window fair-use, unpublished**: ~100–150 messages / 4h (Heavy ~250/4h), ~200
  image/video gens/24h; xAI does **not** publish exact numbers and throttles dynamically.
  Sources: <https://x.ai/api> (tiers), and secondary summaries
  <https://jingrey.com/ai-tech/grok-supergrok-usage-limits/>,
  <https://www.datastudios.org/post/grok-supergrok-paid-features-grok-4-5-access-higher-weekly-limits-multi-agent-reasoning-media-g>.
  xAI's own docs stress caps are governed by unpublished fair-use policy — **so there is no
  authoritative "X of Y messages" number to render even if we could poll it.**
- (Separate product) the **pay-as-you-go xAI API** returns `x-ratelimit-remaining-requests` /
  `-reset` headers — but that's API-key spend, explicitly out of scope here.

### Grok-6. Per-user pollable endpoint
Yes, one exists for the **Grok coding CLI credit pool** (not chat). From CodexBar's
`docs/grok.md` (<https://github.com/steipete/CodexBar/blob/main/docs/grok.md>):
1. **Preferred, currently DISABLED:** `x.ai/billing` RPC over `grok agent stdio` (ACP
   JSON-RPC) → `monthlyLimit`, `usage.totalUsed`, `billingCycle.billingPeriodEnd`. Returns
   `-32601 Method not found` in grok 0.1.210 until xAI re-enables it.
2. **Working REST fallback:** `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`,
   headers `Authorization: Bearer <token from ~/.grok/auth.json>` +
   `x-xai-token-auth: xai-grok-cli` → `creditUsagePercent`, `onDemandUsed.val/onDemandCap.val`,
   reset `currentPeriod.end`. **Individual auth is sufficient; no org-admin.**
3. **Best-effort:** `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`
   (gRPC-web) — needs a browser Web-Key-Exchange keypair + cookies; not token-pollable, skip.

Honest limitation: (2) reports **coding-credit consumption %**, which is the closest thing to
a subscription gauge, but it is **not** the SuperGrok chat message allowance. There is **no**
plain-token endpoint for the chat rolling-window limits.

### Grok-7. Local filesystem (this machine)
**Nothing.** No `~/.grok`, `~/.config/grok`, `~/.xai`; no Grok/xAI app in `/Applications`;
`find ~` for `*grok*` returns nothing. The credential file `~/.grok/auth.json` (email,
team_id, plan-hint `auth_mode`; overridable via `GROK_HOME`) only appears after installing
the Grok Build CLI and running `grok login` with an active SuperGrok / X Premium+ sub.
Source for the path/flow: CodexBar `docs/grok.md`; kenryu42/pi-grok-cli
(<https://github.com/kenryu42/pi-grok-cli>); tetsuo-ai/agenc-core `docs/grok-oauth.md`.

### Grok-8. Prior art
- **steipete/CodexBar** `docs/grok.md` — the only mature implementation; the three
  mechanisms above. Provider requires `grok login` (SuperGrok OAuth/OIDC).
- **kenryu42/pi-grok-cli**, **tetsuo-ai/agenc-core** — reuse `~/.grok/auth.json` for
  subscription-auth Grok access (coding), confirming the credential path, but they consume
  the sub, they don't surface a quota gauge.

### Grok integration sketch (only if user installs Grok CLI + logs in)
```python
import json, os, urllib.request
from datetime import datetime

def fetch_grok():
    p = os.path.join(os.environ.get("GROK_HOME", os.path.expanduser("~/.grok")), "auth.json")
    if not os.path.exists(p):
        return {"state": "not_installed"}         # like Antigravity's "offline" branch
    tok = json.load(open(p)).get("access_token") or json.load(open(p)).get("token")
    req = urllib.request.Request(
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        headers={"Authorization": f"Bearer {tok}", "x-xai-token-auth": "xai-grok-cli"})
    d = json.load(urllib.request.urlopen(req, timeout=10))
    end = d.get("currentPeriod", {}).get("end")
    reset_ts = datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp() if end else None
    return {"pct_used": round(d.get("creditUsagePercent", 0), 1),
            "window": "monthly", "reset": reset_ts, "note": "coding-credit pool, not chat msgs"}
```
Skipped: the disabled `x.ai/billing` stdio RPC (wire it as the primary once xAI re-enables it
— CodexBar says no code change needed) and the cookie/WKE gRPC-web path. Ship the "not
installed" branch first, since that's this machine's actual state.

---

## Recommendation
- **Copilot: implement now.** Verified, one plaintext token file, one GET, clean
  `percent_remaining` + `quota_reset_date`. Best-in-class among the two. Only risk is the
  internal endpoint changing — cheap to detect (200 + `quota_snapshots` present).
- **Grok: defer / gate behind detection.** Add the `~/.grok/auth.json` "not installed"
  branch so it's a no-op until the user actually runs the Grok CLI; even then it shows
  coding-credit %, not the chat message allowance the user probably pictures. Not worth
  building the cookie/WKE path.
