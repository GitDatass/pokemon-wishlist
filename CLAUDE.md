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

**How to debug it — `curl -I` IS the right tool** (correcting an earlier
note here): the browser renders the card-back regardless of status, but
`curl -sI <url>` shows the real **HTTP status code** — a 404 means the
set/number combo is invalid. The efficient sweep is: generate every card's
image URL exactly as the page does (replicate the inline `_SD` builder over
`SET_TCGDEX`/`SET_TCGID`, and call the `sellImg` logic for `_SELL_DATA`),
then `curl -sI` each and flag non-200s. One representative card per set
catches the whole class, since failures are almost always per-set. Cross-check
real IDs at https://pokemontcg.io/sets, https://api.tcgdex.net/v2/en/sets
(and `/ja/sets` for Japanese), or https://tcgplayer.com. Prefer moving a set
into `SET_TCGDEX` when TCGdex has it — it 404s properly so the trap can't recur.

**Two failure sub-types beyond a plain 404:**

- **Silent wrong-set (returns 200, wrong art).** A valid-but-wrong id maps to
  a *different* real set, so it renders fine but shows the wrong cards — a
  status check alone won't catch it. Verify the id actually belongs to the
  named set. Examples fixed: `Base Set 2` → `base2` was showing **Jungle**
  (correct is `base4`); `Crown Zenith: Galarian Gallery` → `swsh12pt5` showed
  base Crown Zenith (correct is `swsh12pt5gg`).
- **WOTC ids differ between CDNs.** pokemontcg.io numbers the old sets
  `base2`=Jungle, `base3`=Fossil, `base4`=Base Set 2, `base5`=Team Rocket —
  NOT the TCGdex-style names (`jungle`/`fossil`/`rocket`), which 404.

**Japanese-only sets** (Selling tab, `lang:'JP'`) use TCGdex's JP path:
`https://assets.tcgdex.net/ja/{serie}/{set}/{localId}/high.webp`, where
`serie` is a short code (`S`, `SV`, `M`) and `set`/`serie` come from
`api.tcgdex.net/v2/ja/sets` — match by card count + Japanese name. Handled in
`sellImg`'s `jpMap`. Note very new sets (e.g. Mega Brave `M1L`, MEGA Dream ex
`M2a`) have card records but no images yet — mapping is correct; art appears
when TCGdex uploads it.

**Fixed so far:**
- `Destined Rivals` `sv9`→`sv10` (unrelated real set); added to `SET_TCGDEX`.
- `Phantasmal Flames` was in neither map (silent card-back) → `SET_TCGDEX`
  `me02`. Plus a full sweep fixing ~19 set mappings across both tabs (WOTC
  base ids, trainer galleries, promos, base sets, JP sets — see the
  "Fix card images" commit).

**Known data issues (NOT code bugs — don't chase these as mapping bugs):**
- `Celebrations: Classic Collection` stores *original-set* numbers (e.g.
  `4/102` = Base Charizard); `cel25c` images 404 on the CDN regardless. Needs
  a per-card mapping.
- `Sun & Moon Base Set`: 18 cards have number `"N/A"` in the data.
- `McDonald's Promos 2023`: not hosted on any CDN.

If a similar report comes in, check that set's entry against its real
pokemontcg.io / TCGdex code (and watch for the silent-wrong-set sub-type)
before assuming it's a code bug — it's usually just a wrong ID.

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
