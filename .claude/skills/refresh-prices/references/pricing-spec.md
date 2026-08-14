# Pricing spec — canonical rules

This file is the **single source of truth** for how a card's price is
computed. Both runners obey it verbatim:

- the **skill** (`SKILL.md`) — Claude-driven, used now via `WebFetch`;
- the **script** (`scripts/refresh_prices.py`) — headless, used later on a
  schedule.

If a rule changes, change it *here* and update both runners. Do not encode
pricing rules anywhere else.

## 0. Data channel (critical)

eBay AU **blocks unauthenticated automated access** to sold listings
(confirmed by smoke test 2026-08-14): `WebFetch` times out, the in-app
browser is redirected to sign-in, and price aggregators return 403/405.

The working channel is the **user's own logged-in Chrome** via the
`claude-in-chrome` tools — it carries their real eBay AU session, so sold
listings render. The skill runner uses that channel. Never substitute
`WebFetch` or an aggregator for eBay sold data — they fail or return the
wrong basis (US-market / asking prices).

The headless `scripts/refresh_prices.py` assumes an HTTP channel it does not
yet have; it stays a documented artifact until an approved eBay Marketplace
Insights API key or a residential-proxy fetch is wired in.

## 1. Basis

A card's price is: **eBay Australia, average of the last 3 sold listings,
raw/ungraded English cards only** — unless the card's `lang` field says
otherwise (e.g. `JP` → require Japanese comps instead of English).

- Sold/completed listings **only**. Never use active/asking prices — they
  run well above actual sold prices.
- Prices are AUD.
- Round the average to 2 decimal places.

## 2. Query construction

eBay AU sold-listings search URL:

```
https://www.ebay.com.au/sch/i.html?_nkw=<query>&LH_Sold=1&LH_Complete=1&LH_PrefLoc=1&_sop=13
```

| Param | Value | Why |
|---|---|---|
| `_nkw` | `<name> <number>` URL-encoded | the search terms |
| `LH_Sold` | `1` | sold listings |
| `LH_Complete` | `1` | completed listings |
| `LH_PrefLoc` | `1` | located in Australia |
| `_sop` | `13` | sort by **most recently ended** — so the top rows are the *last* sold |

`<number>` is the collector number (e.g. `233/182`). Include the set name in
the query only if a first pass returns too few / ambiguous comps.

## 3. Filter — a comp must pass ALL of these

Evaluated case-insensitively against each listing's title (+ subtitle if
present):

| Rule | REJECT the comp if the title matches |
|---|---|
| Graded | `\b(psa\|bgs\|cgc\|ace\|sgc\|beckett\|graded\|gem ?mt\|gem mint)\b` or a grade token like `psa\s*10`, `cgc\s*9\.5` |
| Lots / bundles | `\b(lot\|lots\|bundle\|playset\|job ?lot\|bulk\|collection\|x\s?\d+\|\d+\s?cards)\b` |
| Fakes / customs | `\b(proxy\|fake\|custom\|orica\|art ?card\|not real\|replica)\b` |
| Wrong language | if card `lang` is English/unset → REJECT `\b(japanese\|jpn\|jp\|korean\|chinese)\b`; if card `lang` is `JP` → REJECT comps that are NOT Japanese |
| Wrong card | REJECT unless title contains the collector **number** (`233/182` or bare `233`) AND the card's name tokens |

## 3a. Best-Offer-accepted adjustment

For a listing marked **"Best Offer accepted"**, eBay displays the seller's
**asking** price, not the (hidden) accepted offer — so the shown price
**overstates** the true sale. Accepted offers typically land a bit below ask.

Rule: multiply a "Best Offer accepted" comp's displayed price by
`BO_ACCEPTED_FACTOR` (default **0.92**, i.e. an 8% haircut) before it enters
the average. Record both the displayed and adjusted price in the audit.

- "Buy It Now", auction winning bids, and "or Best Offer" comps that sold at
  the listed price are **firm** — use them as-is.
- `0.92` is a starting heuristic, not measured. Calibrate it against a batch
  of cards where the real accepted price is known, and revisit.
- This affects the average only, never the filtering.

## 4. Average

1. From the surviving comps, take the **3 most recent** (list is already
   sorted most-recent-first by `_sop=13`).
2. Average them; round to 2 dp.
3. **Fewer than 3 survivors** → average what remains and mark the result
   `low_confidence` (see §6).

## 5. Write-back targets

Depends on which tab the card belongs to:

- **Missing Cards tab** → `_EBAY_PRICES[<set name>][<number>] = <price>`
  (number, AUD). Optional entry — a card may have had none before.
- **Selling tab** → the **7th** element of the card's row in `_SELL_DATA`
  (`[set, num, name, lang, rarity, qty, price]`).

`index.html` is a minified single line. Never do a global string replace on
`"<number>":<value>` — short number keys can collide across sets. Always
scope to the correct set/row first:

- **skill path:** locate the exact `"num":val` inside the target set's object
  and edit with enough surrounding context to be unique.
- **script path:** parse the object boundaries — find the set key, then the
  number key within that set's `{...}` — and replace only that value.

## 6. Auto-apply policy (default)

Write changes automatically, **except** these two cases, which pause for
human confirmation:

- **Outlier swing:** `abs(new - old) / old > 0.50` (>50% change vs. the
  currently stored price).
- **Low confidence:** fewer than 3 qualifying comps were found.

Everything else is applied without prompting.

## 7. Audit log

Every run appends a JSON record per card so a stale/odd price is traceable:

```json
{
  "ts": "<ISO8601>",
  "set": "Destined Rivals",
  "number": "233/182",
  "name": "Team Rocket's Nidoking ex",
  "url": "<eBay AU sold URL used>",
  "comps": [{"title": "...", "price": 152.5, "sold": "2026-08-10"}],
  "old": 37.8,
  "new": 155.0,
  "delta_pct": 310.1,
  "applied": true,
  "flag": null
}
```

Written to `scripts/price-audit.log.jsonl` (one JSON object per line).

## 8. Known hazards

- **Sign-in wall / captcha.** Even via the user's Chrome, eBay may show a
  sign-in prompt or challenge. If the page isn't the expected results list,
  or returns zero results, **skip that card and flag it** — never write a
  price from a page you couldn't parse cleanly.
- **Sponsored listing injected out of order.** eBay often puts a promoted
  listing at the very top regardless of its sold date. Always sort by the
  actual `Sold <date>` — don't take page position as recency.
- **"Best Offer accepted" overstates.** Displayed price is the ask, not the
  hidden accepted offer (see §3a).
- **eBay markup drift.** Reading rendered page text is brittle to layout
  changes; if parsing looks off, flag rather than guess.
- **The card-back trap** (see repo `CLAUDE.md`) is an *image* bug, unrelated
  to pricing — don't conflate them.
