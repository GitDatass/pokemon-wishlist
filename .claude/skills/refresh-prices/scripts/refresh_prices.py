#!/usr/bin/env python3
"""Refresh Pokemon card prices in index.html from eBay Australia sold listings.

Headless reference runner for the `refresh-prices` skill. It encodes the SAME
rules as ../references/pricing-spec.md -- read that file; it is the source of
truth. If pricing behaviour changes, change the spec AND this script AND
SKILL.md so the three never drift.

STATUS: reference implementation, NOT yet runnable unattended.
- CHANNEL BLOCKED: eBay AU blocks this urllib HTTP path (spec sec 0 -- it times
  out / redirects to sign-in). The working channel today is the user's
  logged-in Chrome, driven by the `refresh-prices` skill. This script stays a
  documented artifact until a real headless channel exists (approved eBay
  Marketplace Insights API key, or a residential-proxy fetch). `fetch()` and
  `parse_sold_html()` are the parts that must change when that happens.
- NOT IMPLEMENTED: the Best-Offer-accepted adjustment (spec sec 3a) and
  sorting by actual sold date. The skill runner applies both; encode them here
  before activating the script so the two runners don't drift. See
  BO_ACCEPTED_FACTOR below.
The stable parts (URL building, filtering, auto-apply policy, write-back, audit
log) are complete. Keep --dry-run on until a full sweep has been eyeballed.

Runtime: Python 3.9+ standard library only (urllib, re, json). No pip installs
required. Swapping urllib for `requests` + a real HTML parser (selectolax/bs4)
is the recommended hardening step.

Usage:
    python refresh_prices.py --target "Destined Rivals"      # a set
    python refresh_prices.py --target "233/182"              # one card
    python refresh_prices.py --target all --dry-run          # whole catalogue, no writes
    python refresh_prices.py --target all                    # auto-apply, flag outliers
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

# --- paths -----------------------------------------------------------------
SKILL_DIR = Path(__file__).resolve().parent.parent          # .claude/skills/refresh-prices
REPO_ROOT = SKILL_DIR.parent.parent.parent                  # repo root (holds index.html)
INDEX_HTML = REPO_ROOT / "index.html"
AUDIT_LOG = Path(__file__).resolve().parent / "price-audit.log.jsonl"

# --- policy (spec sec 6) ---------------------------------------------------
OUTLIER_SWING = 0.50        # >50% change vs stored price -> hold for confirmation
MIN_COMPS = 3               # fewer qualifying comps -> low confidence -> hold
FETCH_DELAY_S = 2.0         # be polite between requests
BO_ACCEPTED_FACTOR = 0.92   # spec sec 3a: haircut for "Best Offer accepted" comps.
                            # TODO: not yet applied in price_for() -- parse_sold_html
                            # must first capture each comp's offer type + sold date.

# --- filters (spec sec 3) --------------------------------------------------
RE_GRADED = re.compile(r"\b(psa|bgs|cgc|ace|sgc|beckett|graded|gem ?mt|gem mint)\b"
                       r"|(psa|bgs|cgc|sgc)\s*\d", re.I)
RE_LOT = re.compile(r"\b(lot|lots|bundle|playset|job ?lot|bulk|collection|x\s?\d+|\d+\s?cards)\b", re.I)
RE_FAKE = re.compile(r"\b(proxy|fake|custom|orica|art ?card|not real|replica)\b", re.I)
RE_JP = re.compile(r"\b(japanese|jpn|jp)\b", re.I)
RE_OTHER_LANG = re.compile(r"\b(korean|chinese|french|german|italian|spanish)\b", re.I)


def build_url(name: str, number: str) -> str:
    """eBay AU sold-listings search URL (spec sec 2)."""
    query = f"{name} {number}".strip()
    params = {
        "_nkw": query,
        "LH_Sold": "1",
        "LH_Complete": "1",
        "LH_PrefLoc": "1",   # located in Australia
        "_sop": "13",         # most recently ended first -> top rows are the last sold
    }
    return "https://www.ebay.com.au/sch/i.html?" + urllib.parse.urlencode(params)


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
        "Accept-Language": "en-AU,en;q=0.9",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def parse_sold_html(html: str) -> list[dict]:
    """Extract sold comps from an eBay AU sold-listings page.

    Returns [{title, price, sold_raw}] in page order (most-recent-first thanks
    to _sop=13). VERIFY THESE SELECTORS AGAINST LIVE MARKUP -- eBay changes them
    and may serve a bot-challenge page (detected by the caller when this returns
    []). This regex approach is deliberately dependency-free; prefer a real HTML
    parser when hardening.
    """
    if "s-item__title" not in html and "srp-results" not in html:
        return []  # challenge page / unexpected layout -> caller flags & skips
    comps: list[dict] = []
    # Each result card, roughly: title in .s-item__title, price in .s-item__price,
    # sold date in .s-item__caption--signal or POSITIVE / "Sold  <date>".
    items = re.split(r'class="s-item__wrapper', html)
    for chunk in items[1:]:
        title_m = re.search(r'class="s-item__title"[^>]*>(?:<span[^>]*>)?(.*?)</', chunk, re.S)
        price_m = re.search(r'class="s-item__price"[^>]*>(?:<span[^>]*>)?\s*AU\s*\$([\d,]+\.\d{2})', chunk, re.S)
        sold_m = re.search(r'Sold\s+([0-9]{1,2}\s+\w+\s+[0-9]{4})', chunk)
        if not title_m or not price_m:
            continue
        title = re.sub(r"<[^>]+>", "", title_m.group(1)).strip()
        if not title or title.lower() == "shop on ebay":
            continue
        comps.append({
            "title": title,
            "price": float(price_m.group(1).replace(",", "")),
            "sold_raw": sold_m.group(1) if sold_m else None,
        })
    return comps


def passes_filters(comp: dict, name: str, number: str, lang: str) -> bool:
    """True if the comp is a valid raw/ungraded, right-language, right-card sale."""
    title = comp["title"]
    if RE_GRADED.search(title) or RE_LOT.search(title) or RE_FAKE.search(title):
        return False
    # English only, always -- never accept Japanese or other non-English comps
    # (spec sec 1 & 3). Non-English *cards* are skipped upstream in main().
    if RE_JP.search(title) or RE_OTHER_LANG.search(title):
        return False
    # Right card: title must mention the collector number (full or bare) and
    # the distinctive name tokens.
    bare = number.split("/")[0].lstrip("0") or number.split("/")[0]
    num_ok = (number in title) or re.search(rf"\b0*{re.escape(bare)}\b", title)
    if not num_ok:
        return False
    tokens = [t for t in re.split(r"[^A-Za-z0-9]+", name) if len(t) > 2]
    name_ok = sum(1 for t in tokens if re.search(re.escape(t), title, re.I)) >= max(1, len(tokens) // 2)
    return bool(name_ok)


def price_for(name: str, number: str, lang: str) -> tuple[float | None, list[dict], str]:
    """Return (avg_price_or_None, comps_used, url) per spec sec 2-4."""
    url = build_url(name, number)
    try:
        html = fetch(url)
    except Exception as exc:  # noqa: BLE001 - flag & skip on any fetch error
        return None, [{"error": str(exc)}], url
    comps = [c for c in parse_sold_html(html) if passes_filters(c, name, number, lang)]
    used = comps[:MIN_COMPS]
    if not used:
        return None, [], url
    avg = round(sum(c["price"] for c in used) / len(used), 2)
    return avg, used, url


# --- index.html parsing / write-back (spec sec 5) --------------------------
def read_index() -> str:
    return INDEX_HTML.read_text(encoding="utf-8")


def load_ebay_prices(html: str) -> dict:
    """Parse the _EBAY_PRICES={...} object literal into a dict.

    It is JSON-shaped (double-quoted string keys, numeric values), so once the
    braces are isolated json.loads handles it.
    """
    m = re.search(r"_EBAY_PRICES\s*=\s*(\{)", html)
    if not m:
        raise ValueError("_EBAY_PRICES not found")
    start = m.end() - 1
    depth, i = 0, start
    while i < len(html):
        if html[i] == "{":
            depth += 1
        elif html[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return json.loads(html[start:i + 1])


def write_ebay_price(html: str, set_name: str, number: str, new_price: float) -> tuple[str, bool]:
    """Replace _EBAY_PRICES[set][number] scoped to the correct set block.

    Never a global replace -- short number keys collide across sets (spec sec 5).
    """
    sm = re.search(re.escape(json.dumps(set_name)) + r"\s*:\s*\{", html)
    if not sm:
        return html, False
    block_start = sm.end() - 1
    depth, i = 0, block_start
    while i < len(html):
        if html[i] == "{":
            depth += 1
        elif html[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = html[block_start:i + 1]
    key = json.dumps(number)
    pat = re.compile(re.escape(key) + r"\s*:\s*-?\d+(?:\.\d+)?")
    repl = f"{key}:{_num(new_price)}"
    new_block, n = pat.subn(repl, block, count=1)
    if n == 0:
        return html, False
    return html[:block_start] + new_block + html[i + 1:], True


def _num(v: float) -> str:
    """Match the site's minified number style: no trailing .0 for integers."""
    return str(int(v)) if float(v).is_integer() else str(v)


# --- audit (spec sec 7) ----------------------------------------------------
def audit(record: dict) -> None:
    with AUDIT_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def decide(old: float | None, new: float | None, n_comps: int) -> tuple[bool, str | None]:
    """Auto-apply policy (spec sec 6). Returns (apply, flag)."""
    if new is None:
        return False, "no_price"
    if n_comps < MIN_COMPS:
        return False, "low_confidence"
    if old and old > 0 and abs(new - old) / old > OUTLIER_SWING:
        return False, "outlier_swing"
    return True, None


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh card prices from eBay AU sold listings.")
    ap.add_argument("--target", required=True, help='set name, card number/name, or "all"')
    ap.add_argument("--dry-run", action="store_true", help="compute and log, but do not write index.html")
    args = ap.parse_args()

    html = read_index()
    prices = load_ebay_prices(html)

    # Resolve targets from _EBAY_PRICES (Missing Cards). Selling-tab (_SELL_DATA)
    # support is a documented TODO -- same rules, different write-back target.
    targets: list[tuple[str, str]] = []  # (set_name, number)
    t = args.target
    if t.lower() == "all":
        targets = [(s, num) for s, block in prices.items() for num in block]
    elif t in prices:  # a set name
        targets = [(t, num) for num in prices[t]]
    else:              # a number, possibly across sets
        for s, block in prices.items():
            for num in block:
                if num == t or num.split("/")[0] == t:
                    targets.append((s, num))
    if not targets:
        print(f"No matching cards for target {t!r} in _EBAY_PRICES.", file=sys.stderr)
        return 2

    print(f"{len(targets)} card(s) to price.  dry-run={args.dry_run}")
    applied = held = skipped = 0
    for set_name, number in targets:
        old = prices[set_name][number]
        # NOTE: name/lang lookup from _SD is a TODO; using number as the query
        # seed works but name-qualified queries filter better. For now query by
        # number + set name for disambiguation.
        name = set_name  # placeholder until _SD name lookup is wired in
        new, comps, url = price_for(name, number, lang="")
        do_apply, flag = decide(old, new, len(comps))
        rec = {
            "ts": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "set": set_name, "number": number, "name": name, "url": url,
            "comps": comps, "old": old, "new": new,
            "delta_pct": (round((new - old) / old * 100, 1) if new and old else None),
            "applied": bool(do_apply and not args.dry_run), "flag": flag,
        }
        audit(rec)
        status = flag or ("apply" if do_apply else "skip")
        print(f"  {set_name} {number}: {old} -> {new}  [{status}]")
        if do_apply and not args.dry_run:
            html, ok = write_ebay_price(html, set_name, number, new)
            applied += 1 if ok else 0
        elif flag in ("outlier_swing", "low_confidence"):
            held += 1
        else:
            skipped += 1
        time.sleep(FETCH_DELAY_S)

    if not args.dry_run and applied:
        INDEX_HTML.write_text(html, encoding="utf-8")
    print(f"\nDone. applied={applied} held(flagged)={held} skipped={skipped}. "
          f"Audit: {AUDIT_LOG}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
