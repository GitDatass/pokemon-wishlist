# eBay AU Card Valuation — Claude skill

Values trading cards at real **Australian** market prices from eBay.com.au SOLD listings.
Ask Claude "what's this card worth?" and it runs the comps properly instead of guessing.

## Install

Already installed in this project at `.claude/skills/ebay-au-card-value/`.

## Data channel — how it fetches comps here

eBay AU blocks signed-out and automated access to sold listings. On this
machine (no local Node/Python runtime) the skill reads comps through the
**user's own logged-in Chrome** via the `claude-in-chrome` tools — that
session carries the real eBay AU login, so sold listings render. If Chrome
isn't connected or signed into eBay AU, Claude will ask you to connect / sign
in; it never enters your credentials.

See `SKILL.md` for the full Chrome-channel flow and how this skill relates to
the sibling `refresh-prices` writer skill.

## Use

Just ask Claude naturally:

> what's Swinub 165/159 worth?
> value these 40 cards for me
> what should I list this Charizard at?

## Offline / portable alternative (needs Node — not this machine)

The `scripts/*.cjs` Playwright implementation is retained for a machine that
*does* have a Node 18+ runtime. It is **not runnable here**. On such a box:

```
npm install playwright && npx playwright install chromium
node scripts/ebay_login.cjs                   # one-time headed sign-in
node scripts/ebay_sold.cjs "Swinub 165/159"
node scripts/ebay_batch.cjs                   # bulk, reads queries.json
```

## What makes the number trustworthy

It's the **median of the 5 most recent genuine comps**, after throwing out:
lots and bundles, graded slabs, overseas sellers, wrong collector numbers, and anything
without a real sold price and date. It flags thin data (fewer than 3 comps) and mixed
English/Japanese results instead of quietly averaging two different markets together.

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | The methodology Claude follows |
| `scripts/ebay_login.cjs` | One-time eBay sign-in, saves the session |
| `scripts/ebay_sold.cjs` | Value one card |
| `scripts/ebay_batch.cjs` | Value a whole list from `queries.json` |

Prices are AUD and reflect the Australian market, which runs meaningfully above US prices
on most singles. Don't convert US comps — that's the whole point of this.
