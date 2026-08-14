---
name: refresh-prices
description: Refresh Pokémon card prices in index.html from eBay Australia sold listings. Use when the user wants to update, re-price, or refresh card prices — for a single card, a whole set, or the entire wishlist/selling catalogue. Drives the user's logged-in Chrome to read eBay AU sold comps, filters to raw/ungraded English cards only, averages the last 3 sold, and writes back into _EBAY_PRICES / _SELL_DATA.
---

# Refresh prices

Update hardcoded card prices in `index.html` from **eBay Australia sold
listings**. The full rule-set — query, filters, averaging, write-back,
auto-apply policy — lives in `references/pricing-spec.md`. **Read it first
and follow it exactly.** This file describes the Claude-driven run.

## Data channel — READ THIS FIRST

eBay AU **blocks unauthenticated automated access** to sold listings. Proven
by smoke test 2026-08-14:

- `WebFetch` on the sold-search URL → **times out**.
- The in-app preview browser → **redirected to eBay sign-in**.
- Price aggregators (PriceCharting, SportsCardInvestor) → **403 / 405**.

The **only** channel that works is the user's own logged-in Chrome via the
`claude-in-chrome` tools — it carries their real eBay AU session, so sold
listings render fully. **Always use that channel.** Do not fall back to
`WebFetch`/aggregators for eBay sold data; they will fail or return the wrong
basis (US-market/asking prices).

If the user's Chrome isn't connected or isn't signed into eBay AU, stop and
ask them to connect / sign in — **never** enter their eBay credentials
yourself.

## Scope argument

`/refresh-prices <target>`:

- a card — `Team Rocket's Nidoking ex` or a number like `233/182`
- a set — `Destined Rivals`
- `all` — every priced card (confirm before a full sweep; it's many page loads)

If no target is given, ask which.

## Procedure

1. **Load the spec.** Read `references/pricing-spec.md`.
2. **Connect Chrome.** `list_connected_browsers` → `select_browser`. Confirm a
   local browser is present. Create a fresh tab with `tabs_create_mcp` (don't
   reuse the user's tabs).
3. **Resolve targets** in `index.html`:
   - Missing Cards: keys in `_EBAY_PRICES` (set → number → price), cross-ref
     names/numbers in `_SD`.
   - Selling: rows in `_SELL_DATA` (`[set, num, name, lang, rarity, qty, price]`).
   Capture each card's `set`, `number`, `name`, `lang`, current `price`, and
   which structure holds it.
4. **For each card:**
   a. Build the eBay AU sold URL (spec §2).
   b. `navigate` the Chrome tab to it, then `get_page_text` to read results.
      If the page shows a sign-in wall, captcha, or zero results, **skip and
      flag** — never guess a price (spec §8).
   c. Parse each sold row: title, `Sold <date>`, sold price (AU $), and the
      offer type (`Buy It Now` / auction / `Best Offer accepted` / `or Best
      Offer`).
   d. Apply the filters (spec §3) — drop graded, lots, fakes, wrong language,
      wrong card.
   e. **Sort by actual sold date** (a sponsored listing is often injected at
      the top out of order — trust the `Sold <date>`, not page position).
   f. Take the 3 most recent survivors, apply the Best-Offer-accepted
      adjustment (spec §3a), average, round (spec §4).
5. **Decide per card (spec §6):**
   - Within 50% of the old price AND ≥3 comps → **apply**.
   - >50% swing OR <3 comps → **hold for confirmation** (show why).
6. **Show a summary table** before writing:

   | Card | # comps | comps (AUD, dated) | old → new | Δ% | action |
   |---|---|---|---|---|---|

7. **Write back** (spec §5). `index.html` is minified — scope each edit to the
   correct set block / row and use `Edit` with enough surrounding context that
   the match is unique. Verify the old value is present before replacing.
8. **Append audit records** to `scripts/price-audit.log.jsonl` (spec §7),
   including the `channel` and the dated comps used.
9. **Clean up.** Close tabs you opened (`tabs_close_mcp`).
10. **Report:** applied / held (with reasons) / skipped. Don't commit or push
    unless the user asks.

## Guardrails

- Never enter the user's eBay credentials. If not signed in, ask them to.
- Never write a price from a page you couldn't parse cleanly.
- Never include graded (PSA/BGS/CGC/TAG/…) or non-English comps. English
  only — no Japanese/other-language sales, ever.
- Never do a global find/replace on a bare number key — collisions across
  sets will corrupt other cards' prices.

## Relation to the scheduled script

`scripts/refresh_prices.py` is the headless future runner for scheduling. It
encodes the **same** `pricing-spec.md` rules but assumes an HTTP channel it
does **not** yet have (eBay blocks it — see the data-channel note above). It
stays a documented artifact until a real headless channel exists (approved
eBay Marketplace Insights API, or a residential-proxy fetch). If you change
pricing behaviour, update the spec **and** keep the script's TODOs honest so
the two never silently drift.
