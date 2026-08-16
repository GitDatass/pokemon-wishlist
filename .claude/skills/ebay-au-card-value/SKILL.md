---
name: ebay-au-card-value
description: Value trading cards (Pokemon, sports, TCG singles) at real Australian market prices using eBay.com.au SOLD listings. Use whenever someone asks what a card is worth, what to price a card at, what a slab or single sold for in Australia, or wants a whole list/collection valued in AUD. Triggers on "what's this card worth", "value this card", "AUD price", "eBay sold comps", "what did it sell for", "price my collection", "value these cards", "what should I list this at". Reads eBay AU sold+completed listings through the user's logged-in Chrome, filtered to Australian sellers, strips lots/bundles/graded/overseas noise, and returns the median of the most recent genuine comps with an explicit confidence flag.
---

# eBay AU Card Valuation

Turns a card name into a defensible **AUD** market value from real Australian
sold prices — not US prices converted, not asking prices, not TCGPlayer. The
number is the **median** of the most recent genuine single-card comps sold by
Australian sellers.

Be direct. Always state the sample size. If a value rests on fewer than 3
comps, say so loudly — a thin comp is a guess wearing a suit.

This is a **read-only valuation** skill: it tells you what a card is worth. It
does **not** edit any files. To write refreshed prices back into
`index.html` (`_EBAY_PRICES` / `_SELL_DATA`), use the sibling **`refresh-prices`**
skill — see *Relation to refresh-prices* at the bottom.

## Why this method

Australian card prices are their own market. They run meaningfully above US
prices on most singles because of freight, import cost, and thinner local
supply. So:

- **eBay AU sold listings** (`LH_Sold=1&LH_Complete=1`) are the only broad
  public record of what Australians actually paid.
- **Australian sellers only** (`LH_PrefLoc=1`) — an item shipped from China or
  the US is priced in a different market. Including it drags the number down
  and misrepresents what a local buyer will pay.
- **Most recent first** (`_sop=13`) — card markets move on set rotation,
  reprints, and meta. A comp from 8 months ago is history, not price.

## Data channel — READ THIS FIRST

eBay AU **blocks unauthenticated automated access** to sold listings
(confirmed by smoke test 2026-08-14):

- `WebFetch` on the sold-search URL → **times out**.
- The in-app preview browser → **redirected to eBay sign-in**.
- Price aggregators (PriceCharting, SportsCardInvestor) → **403 / 405**.

The **only** channel that works on this machine is the user's own logged-in
**Chrome** via the `claude-in-chrome` tools — it carries their real eBay AU
session, so sold listings render fully. **Always use that channel.** Never
substitute `WebFetch`/aggregators for eBay sold data; they fail or return the
wrong basis (US-market / asking prices).

> There is no local Node/Python runtime on this machine, so the bundled
> Playwright scripts in `scripts/` do **not** run here. They are kept only as
> a future/portable alternative for a box that has Node — see *Offline batch
> alternative* at the bottom. The Chrome channel below is the live path.

If the user's Chrome isn't connected or isn't signed into eBay AU, **stop and
ask them to connect / sign in** — never enter their eBay credentials yourself.

## The flow (Chrome channel)

**Step 0 — Connect Chrome.** `list_connected_browsers` → `select_browser`.
Confirm a local browser is present and signed into eBay AU. Open a fresh tab
with `tabs_create_mcp` (don't hijack the user's existing tabs).

**Step 1 — Build the query.** Card name plus collector number is the
highest-signal query: `Swinub 165/159`. The number does most of the
disambiguation. For sealed product or numberless cards, use the exact product
name. For a known EN/JP collision set (e.g. SV 151), append `English` or
`Japanese`.

**Step 2 — Navigate and read.** Build the eBay AU sold URL:

```
https://www.ebay.com.au/sch/i.html?_nkw=<query>&LH_Sold=1&LH_Complete=1&LH_PrefLoc=1&_sop=13
```

`navigate` the Chrome tab to it, then `get_page_text` (or `read_page`) to read
the rendered results. If the page shows a sign-in wall, captcha, or zero
results, **skip and flag** — never guess a price (see *When it returns
nothing*).

**Step 3 — Parse each sold row:** title (+ subtitle if present),
`Sold <date>`, sold price (AU $), and offer type (`Buy It Now` / auction /
`Best Offer accepted` / `or Best Offer`).

**Step 4 — Filter** every result before it counts (see *What gets excluded*).
Tag each survivor `EN` / `JP` / `UNKNOWN` from title cues.

**Step 5 — Sort by actual `Sold <date>`.** eBay often injects a sponsored
listing at the very top out of order — trust the sold date, not page position.

**Step 6 — Take the N most recent survivors** (default N = 5), then report the
**median**, the mean, the count, and every comp used with its title, price,
and date. Scan the titles: if a comp is obviously the wrong card, wrong
variant (reverse holo vs regular, 1st edition, promo stamp), or a suspicious
outlier, drop it and say why.

**Step 7 — Report.** Lead with the value and sample size, then range, then any
caveat. Close any tab you opened (`tabs_close_mcp`) when done.

Example output to aim for:

```
Swinub 165/159 — A$34 (median of 5 AU sold, most recent 12 Aug 2026)
Range: A$28–41 · all English, raw, AU sellers
```

## What gets excluded, and why

Filter each result case-insensitively against its title (+ subtitle):

| Excluded | Why |
|---|---|
| Lots, bundles, job lots, playsets, "20 cards", `x\d+` | Per-card price is unknowable from a lot total |
| PSA / CGC / BGS / ACE / SGC / Beckett / graded / slabs / "gem mint" | A graded card is a different asset — a PSA 10 can be 5–20× raw |
| Proxies, fakes, customs, orica, replicas | Not the real card |
| Listings shipping from overseas | Different market, different freight, distorts the AUD number |
| Titles missing the collector number | Wrong card, or a vague listing that can't be verified |
| No parseable price or sold date | Can't be a comp without both |

**Grading is a hard split.** Never blend a graded sale into a raw value or
vice versa. If someone asks about a slab, re-run the query with the grade in
it (`Charizard 4/102 PSA 9`) and value it against graded comps only. Note the
excluded graded sales so the user can see whether that's the more relevant
market.

## Language traps (Pokemon especially)

English and Japanese cards share collector numbers in some sets — SV 151 is
the notorious one, where `165/165` matches both, and they sell at very
different prices.

Tag each comp `EN` / `JP` / `UNKNOWN` from title cues: Japanese script, the
words japanese/japan/jpn, JP set codes like `sv2a`, versus English rarity
language like "illustration rare" or "double rare".

For a collision set:
1. Append `English` (or `Japanese`) to the query — filters most noise at the
   source.
2. If the surviving comps are a mixed EN/JP bag, the median is blending two
   markets and is **not trustworthy** — say so.
3. If titles are genuinely ambiguous, look at the card thumbnails in the
   Chrome tab (`read_page` / a screenshot) — JP cards are visually obvious.
   Classify by eye, then take the median of the correct-language subset only.

## Valuing a whole list

For more than a handful of cards, reuse the **one** Chrome tab and loop:
navigate → read → filter → record, one query at a time. Pace it — leave a
couple of seconds between searches so eBay doesn't throttle the session, and
if three searches in a row come back blocked, **stop and report** rather than
grinding out zeros that would read as genuine "no comps" answers.

Record results incrementally (e.g. to a scratch JSON) so a long run that dies
partway isn't lost.

## When it returns nothing

Distinguish three very different zeros — say which one it is:

- **Blocked by eBay** — sign-in wall / captcha / session expired. Ask the user
  to sign into eBay AU in Chrome. This is *not* a valuation.
- **No results at all** — the query is probably wrong. Check spelling and the
  collector number.
- **A real zero-comp result** — results existed but none survived the filters.
  The card may only sell in lots, only graded, or only from overseas. Say
  which.

## Accuracy rules

1. **Median, not mean.** One inflated sale shouldn't move the number. Report
   both; quote the median.
2. **n < 3 is a guess.** Say "thin data" and give the raw comps instead of a
   confident single figure.
3. **Never blend graded and raw.** Different assets.
4. **Never blend EN and JP.** Different markets.
5. **Date the value.** "A$34 as at 15 Aug" is honest; "A$34" implies a
   permanence that doesn't exist.
6. **Condition is invisible.** Sold titles rarely state condition reliably.
   These comps approximate a near-mint raw single; a played card is worth
   materially less — flag it when the answer matters.
7. **Zero results is information.** No AU sold comps usually means low-value
   bulk, or a wrong query. Check the query before concluding it's worthless.

## Relation to refresh-prices

Two skills, clean lanes — they do **not** duplicate scraping:

- **`ebay-au-card-value`** (this skill) — the **reader**. Ad-hoc "what's it
  worth?" lookups and whole-collection valuations. Returns a number; touches
  no files.
- **`refresh-prices`** — the **writer**. Updates the hardcoded prices in
  `index.html` (`_EBAY_PRICES` / `_SELL_DATA`), with an auto-apply / hold
  policy and an audit log.

Both read eBay AU sold data through the **same Chrome channel**, apply the
**same filters** (graded/lots/overseas/non-English/wrong-card), and use the
**same statistic** — the **median of the last 5** genuine comps. The shared
channel + filter + method rules live in
`../refresh-prices/references/pricing-spec.md` — treat that as the source of
truth and keep this skill aligned with it. The only difference is direction:
this skill reports the number; `refresh-prices` writes it into `index.html`.

## Offline batch alternative (needs Node — not this machine)

`scripts/ebay_login.cjs`, `scripts/ebay_sold.cjs`, and `scripts/ebay_batch.cjs`
are a self-contained Playwright implementation of the same method (median,
same filters, EN/JP tagging, incremental batch output). They require a local
Node 18+ runtime with Playwright installed and are **not runnable on this
machine** (no Node). They're retained for portability — on a box with Node:

```
npm install playwright && npx playwright install chromium
node scripts/ebay_login.cjs          # one-time headed sign-in
node scripts/ebay_sold.cjs "Swinub 165/159"
node scripts/ebay_batch.cjs          # reads queries.json
```

On **this** machine, ignore the scripts and use the Chrome channel above.
