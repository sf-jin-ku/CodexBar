---
summary: "Vercel AI Gateway team credits through its API, or personal budgets through an existing CLI login."
read_when:
  - Setting up or modifying the Vercel AI Gateway provider
---

# Vercel AI Gateway

Enable **Vercel AI Gateway** in Settings → Providers and enter an AI Gateway API key, or set
`AI_GATEWAY_API_KEY` for the CLI. The key is saved in CodexBar's local config file when entered in Settings.
Use `codexbar usage --provider vercel --source api` to fetch it.

## Personal budget with Vercel CLI

No additional access token needs to be copied into CodexBar. Install Vercel CLI and sign in with
`vercel login`, then enter the target **Team ID** (`team_...`) in the provider's settings. In automatic
mode, setting a team ID selects the personal-budget source instead of the API-key balance source.
Leave it blank to keep the existing API-key behavior. The Gateway API key is not required for CLI budgets.

For the CodexBar CLI, set `VERCEL_TEAM_ID` and use `codexbar usage --provider vercel --source cli`.
Explicit `--source api` always reads the Gateway key's team credits, even when a team ID is configured.

CodexBar runs read-only `vercel api` commands with JSON output:

- `/v2/user` identifies the signed-in CLI user.
- `/ai-gateway/budgets/list?teamId=...&scopeType=user` supplies that team's personal budgets.

The personal budget is matched by user ID, never by the first list entry or a display name. A custom
budget takes precedence over an inherited default. The card shows spend, limit, remaining personal
allowance, and the refresh cadence. Daily, weekly, and monthly budgets reset at UTC boundaries;
weekly budgets reset on Monday. A cumulative (`none`) budget has no reset date.

When no active personal budget exists, CodexBar says so without inventing a usage percentage or spend.
CLI login, permission, and parsing failures remain visible instead of falling back to unrelated team credits.
The CLI source describes the signed-in user in the selected team; it does not infer the owner of a Gateway key.
It works with CLI versions that support `vercel api --raw --non-interactive`, even without the newer
`vercel ai-gateway` subcommand. Every team role except Contributor can read budgets.

Only keys with **User** spend attribution count toward this personal budget. A key created by a person
can still have **Team** attribution. Team and key budgets, and the team's credit balance, can stop requests
before the personal allowance runs out. BYOK spend does not count toward these budgets.

Synthetic personal-budget examples in light and dark appearances:

![Personal budget in light appearance](screenshots/vercel-personal-budget.png)
![Personal budget in dark appearance](screenshots/vercel-personal-budget-dark.png)

## Team credits with an API key

The bundled JavaScript plugin reads `GET https://ai-gateway.vercel.sh/v1/credits` with bearer authentication.
It displays the key's **team-wide remaining USD balance** and **lifetime USD spend**, from the documented
`balance` and `total_used` decimal strings. Zero and negative balances are preserved. Missing or malformed
values fail the refresh; they do not become zero. The shared HTTP host bounds requests and retries transient failures.

This endpoint has no spending limit or reset date, so this source shows amounts without a percentage bar,
reset countdown, or billing-period estimate. The API-key source does not use Vercel CLI credentials.
Select the appropriate team's API key to change its scope. Neither source imports browser cookies,
reads Keychain directly, changes budgets, makes inference requests, or uses the metered Custom Reporting API.

Sources: [REST credit API](https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance),
[usage semantics](https://vercel.com/docs/ai-gateway/observability-and-spend/usage), and
[reporting pricing](https://vercel.com/docs/ai-gateway/observability-and-spend/custom-reporting#pricing).
Personal budgets: [budget semantics](https://vercel.com/docs/ai-gateway/observability-and-spend/budgets),
[list budgets API](https://vercel.com/docs/rest-api/ai-gateway/list-ai-gateway-budgets), and
[spend attribution](https://vercel.com/docs/ai-gateway/authentication-and-byok/api-keys#spend-attribution).
