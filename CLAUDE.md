# Daniel's Pokémon Wishlist — Project Notes

Single-file static site (`index.html`) hosted on GitHub Pages. No build step —
all data and logic live inline in one `<script>` block. Two tabs:

- **Missing Cards** — browses `_SD` (wishlist data), checkbox "claimed" tracking
  via `localStorage`, optional price badge sourced from `_EBAY_PRICES`.
- **Selling** — browses `_SELL_DATA` (cards for sale), always shows a price,
  image sourced via the `sellImg()` function.

## Card image sourcing — known failure pattern

Images come from two possible CDNs, chosen per-set:

1. **TCGdex** (`assets.tcgdex.net`) — set via the `SET_TCGDEX` map
   (`{id, p}` per set name). **Preferred** — 404s correctly on bad
   set/number combos.
2. **`images.pokemontcg.io`** — fallback via `SET_TCGID` map (set name →
   short id like `sv10`, `swsh9`, etc). Used only for sets not in
   `SET_TCGDEX`.

**The trap:** `images.pokemontcg.io` sometimes returns a *valid PNG* (the
official Pokémon card-back artwork) with an **HTTP 404 status** when a
set/number combo doesn't exist. Browsers render the image regardless of
status code, so `onerror` never fires and the broken fallback logic never
kicks in — the card just silently shows the generic Pokémon-logo card back
instead of erroring out visibly. Anyone reporting "some cards show a plain
Pokémon card back instead of the real art" is hitting this.

**How to debug it:** don't just check for broken images visually — verify
the actual set ID is correct. `curl` won't help either, since a 404 status
still returns image bytes; instead compare against the known-correct ID
(cross-check https://tcgplayer.com or https://pokemontcg.io/sets for the
real set code) or just prefer moving the set into `SET_TCGDEX` (TCGdex does
404 properly, so this class of bug can't recur there).

**Fixed so far:** `Destined Rivals` was mapped to `sv9` (wrong — that's a
different, unrelated real set) instead of `sv10`. Fixed in `SET_TCGID` and
also added to `SET_TCGDEX` so it no longer depends on the trap-prone CDN.

If a similar report comes in for another set, check that set's entry in
`SET_TCGID` against its real pokemontcg.io / TCGdex set code before assuming
it's a code bug — it's usually just a wrong ID.

## Pricing methodology

All prices are meant to be: **eBay Australia, average of the last 3 sold
listings, raw/ungraded English cards only**. English only — never price a
Japanese/other-language card and never use non-English sold comps. Do not use
current/asking listing prices — those run well above actual sold prices. Do
not include graded (PSA/BGS/CGC) sales in the average.

Prices live in two places depending on which tab a card appears in:

- **Missing Cards tab:** `_EBAY_PRICES` object, keyed by set name → card
  number → price (AUD, number). Optional — cards without an entry just show
  no price badge.
- **Selling tab:** the 7th element of each row in `_SELL_DATA`
  (`[set, num, name, lang, rarity, qty, price]`).

**Known-fixed mispricings (as of this session):**

| Set | Card # | Name | Was | Fixed to | Basis |
|---|---|---|---|---|---|
| Destined Rivals | 233/182 | Team Rocket's Nidoking ex | $37.80 | $155 | eBay AU sold + TCGPlayer/pokemonwizard ~$100–140 raw |
| Destined Rivals | 234/182 | Team Rocket's Crobat ex | $139.90 | $100 | ~$95–105 raw |
| Destined Rivals | 236/182 | Ethan's Adventure | $98.00 | $65 | ~$59–69 raw |
| Phantasmal Flames | 125/094 | Mega Charizard X ex | $3,081.77 | $1,100 | ~$1,050–1,180 raw (was ~3x too high) |

These were spot-checked manually via web search (TCGPlayer, pokemonwizard,
sportscardinvestor, eBay AU listings). **There is currently no automated
price-refresh pipeline** — prices are hardcoded and go stale. A good next
step is a script (run manually or on a schedule) that:

1. Iterates every card in `_EBAY_PRICES` / `_SELL_DATA`.
2. Queries eBay's sold-listings for `<card name> <set> <number> raw
   ungraded` filtered to Australia.
3. Averages the last 3 sold prices (skip graded, skip all non-English —
   English cards and comps only).
4. Writes the result back into the appropriate data structure.

When asked to "keep this updated" or build a pricing skill, this is the spec
to build against — average of last 3 eBay AU sold, raw/ungraded only.
