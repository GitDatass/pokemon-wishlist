// eBay AU SOLD-listings card valuation - single card.
//
// Usage: node ebay_sold.cjs "<search query>" [options]
//   query      : typed into eBay, e.g. "Swinub 165/159"
//   --must "R" : regex the TITLE must match; defaults to the collector number in the query
//   --n 5      : how many recent comps feed the median (default 5)
//   --profile P: persistent browser profile dir (default ./ebay-profile)
//   --headless : run without a visible window (more likely to be blocked)
//   --json     : print raw JSON only
//   --fixture F: parse a saved local HTML file instead of hitting eBay (for testing
//                the filters/median offline, or re-parsing a page you saved by hand)
//
// Run `node ebay_login.cjs` first - eBay gates sold listings behind a signed-in session.
// Requires: npm install playwright && npx playwright install chromium
const { chromium } = require('playwright');
const path = require('path');

const argv = process.argv.slice(2);
const flags = {};
const positional = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) flags[argv[i].slice(2)] = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : true;
  else positional.push(argv[i]);
}
const query = positional[0];
if (!query) {
  console.error('Usage: node ebay_sold.cjs "<search query>" [--must "<regex>"] [--n 5] [--profile ./ebay-profile] [--headless] [--json]');
  process.exit(1);
}
const N = parseInt(flags.n, 10) || 5;
const JSON_ONLY = !!flags.json;
const HEADLESS = !!flags.headless;
const PROFILE = path.resolve(process.cwd(), flags.profile && flags.profile !== true ? flags.profile : 'ebay-profile');
const FIXTURE = flags.fixture && flags.fixture !== true ? path.resolve(process.cwd(), flags.fixture) : null;

let mustMatch = flags.must;
if (!mustMatch || mustMatch === true) {
  const m = query.match(/\d{1,3}\s*\/\s*\d{1,3}/);      // collector number like 165/159
  mustMatch = m ? m[0].replace(/\s+/g, '') : query;
}
const mustRe = new RegExp(String(mustMatch).replace(/[/]/g, '\\s*/\\s*'), 'i');

const LOT_RE = /\b(lot|lots|bundle|joblot|job lot|playset|complete set|master set|choose|pick|singles|\d+\s*cards|cards!|x\s?\d{2,})\b/i;
const GRADED_RE = /\b(psa|cgc|bgs|ace|graded|gem mt|gem mint\s*10|\bslab\b)\b/i;
const NONAU_RE = /from\s+(china|japan|united states|usa|hong kong|singapore|united kingdom|germany|korea|taiwan|canada|new zealand|thailand|malaysia|philippines)/i;
// eBay's anti-bot / sign-in walls. Hitting one means ZERO results for the wrong reason.
const WALL_RE = /Sign in or Register|Security measure|Error Page|Pardon Our Interruption|checking your browser/i;

const nkw = encodeURIComponent(query).replace(/%20/g, '+');
// LH_Sold + LH_Complete = sold listings; _sop=13 = ended most recently; LH_PrefLoc=1 = Australian sellers only
const url = 'https://www.ebay.com.au/sch/i.html?_nkw=' + nkw + '&LH_Sold=1&LH_Complete=1&_sop=13&LH_PrefLoc=1';

// language cues in a title: Japanese script, JP/EN keywords, JP set codes
function langByTitle(t) {
  if (/[぀-ヿ㐀-鿿ｦ-ﾟ]/.test(t)) return 'JP';
  if (/\b(japanese|japan|jpn)\b/i.test(t)) return 'JP';
  if (/\bsv\d[a-z]\b/i.test(t)) return 'JP';                       // JP set codes like sv2a
  if (/\b(english|eng)\b/i.test(t)) return 'EN';
  if (/illustration rare|ultra rare|special illustration|hyper rare|double rare/i.test(t)) return 'EN';
  return 'UNKNOWN';
}

const MONTHS = { jan:0, feb:1, mar:2, apr:3, may:4, jun:5, jul:6, aug:7, sep:8, oct:9, nov:10, dec:11 };
function parseSold(cap) {
  const m = cap.match(/Sold\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})/i);
  if (!m) return null;
  return new Date(Date.UTC(+m[3], MONTHS[m[2].toLowerCase()], +m[1]));
}
function parsePrice(s) { const m = s.replace(/,/g, '').match(/([\d.]+)/); return m ? parseFloat(m[1]) : null; }
function clean(t) { return t.replace(/\n?Opens in a new window or tab/gi, '').replace(/^NEW LISTING/i, '').trim(); }
function median(a) {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y); const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
const money = v => v == null ? '?' : 'A$' + v.toFixed(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Shared by both scripts: pull the result cards out of a loaded search page.
async function scrapeResults(page) {
  return page.evaluate(() => {
    const countEl = document.querySelector('.srp-controls__count-heading, .result-count__count-heading');
    const out = [];
    document.querySelectorAll('.su-card-container, li.s-item').forEach(li => {
      const g = sels => { for (const s of sels) { const e = li.querySelector(s); if (e && e.innerText.trim()) return e.innerText.trim(); } return ''; };
      const title = g(['.s-card__title', '.s-item__title', '[class*="title"]']);
      const price = g(['.s-card__price', '.s-item__price', '[class*="price"]']);
      if (!title || !price) return;
      const cap = g(['.s-card__caption', '.s-item__caption', '.POSITIVE', '[class*="caption"]']);
      const full = li.innerText.replace(/\s+/g, ' ').trim();
      const a = li.querySelector('a[href*="/itm/"]');
      const im = li.querySelector('img');
      out.push({ title, price, cap, full, link: a ? a.href.split('?')[0] : '', img: im ? (im.src || im.getAttribute('data-src') || '') : '' });
    });
    return { countText: countEl ? countEl.innerText.trim() : '', items: out };
  });
}

(async () => {
  // fixture mode uses a throwaway browser; live mode uses the persistent signed-in profile.
  // Track the browser separately - closing only the context leaves the process hanging.
  let browser = null;
  let ctx;
  if (FIXTURE) {
    browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
    ctx = await browser.newContext({ locale: 'en-AU', timezoneId: 'Australia/Sydney' });
  } else {
    ctx = await chromium.launchPersistentContext(PROFILE, {
      headless: HEADLESS, channel: HEADLESS ? undefined : 'chromium',
      args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
      locale: 'en-AU', timezoneId: 'Australia/Sydney', viewport: { width: 1400, height: 1000 },
    });
  }
  const page = ctx.pages()[0] || await ctx.newPage();
  try {
    let raw = { countText: '', items: [] };
    let pageTitle = '';
    let walled = false;

    if (FIXTURE) {
      await page.goto('file://' + FIXTURE.replace(/\\/g, '/'), { waitUntil: 'domcontentloaded', timeout: 30000 });
      pageTitle = await page.title();
      raw = await scrapeResults(page);
    } else {
      // warm up on the homepage first - going straight to a sold search trips the wall more often
      await page.goto('https://www.ebay.com.au/', { waitUntil: 'domcontentloaded', timeout: 60000 });
      for (const sel of ['#gdpr-banner-accept', 'button[aria-label*="Accept"]']) {
        const b = await page.$(sel); if (b) { try { await b.click({ timeout: 2000 }); } catch {} }
      }
      await sleep(1500);

      for (let attempt = 1; attempt <= 3; attempt++) {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
        await sleep(2500);
        pageTitle = await page.title();
        raw = await scrapeResults(page);
        walled = WALL_RE.test(pageTitle);
        if (!walled) break;            // got through, or genuinely no results
        await sleep(4000 * attempt);   // back off and retry the wall
      }
    }

    if (walled) {
      console.error('');
      console.error(`BLOCKED by eBay: "${pageTitle}"`);
      console.error('');
      console.error('eBay gates sold listings behind a signed-in session. Fix:');
      console.error('  node ebay_login.cjs' + (flags.profile ? ` --profile ${flags.profile}` : ''));
      console.error('');
      console.error('If you already signed in, the session has probably expired - run it again.');
      console.error('Also avoid --headless; a visible window is far less likely to be blocked.');
      process.exitCode = 2;
      return;
    }

    const parsed = raw.items.map(it => ({
      title: clean(it.title),
      priceAU: parsePrice(it.price),
      soldRaw: (it.cap.match(/Sold[^\n]*/i) || [''])[0],
      soldDate: parseSold(it.cap) || parseSold(it.full),
      link: it.link,
      img: (it.img || '').replace(/s-l\d+/, 's-l500'),
      lang: langByTitle(it.title),
      isLot: LOT_RE.test(it.title),
      isGraded: GRADED_RE.test(it.title),
      nonAU: NONAU_RE.test(it.full),
      exact: mustRe.test(it.title),
    }));

    // keepers: exact card, not a lot, not graded, AU seller, has both price and sold date
    const keep = parsed
      .filter(p => p.exact && !p.isLot && !p.isGraded && !p.nonAU && p.priceAU && p.soldDate)
      .sort((a, b) => b.soldDate - a.soldDate);

    const top = keep.slice(0, N);
    const prices = top.map(p => p.priceAU);
    const med = median(prices);
    const mean = prices.length ? prices.reduce((a, b) => a + b, 0) / prices.length : null;
    const langCounts = keep.reduce((o, p) => { o[p.lang] = (o[p.lang] || 0) + 1; return o; }, {});
    const excludedGraded = parsed.filter(p => p.exact && p.isGraded).slice(0, 5)
      .map(p => ({ title: p.title, priceAU: p.priceAU, sold: p.soldRaw }));

    const result = {
      query, mustMatch: String(mustMatch), url, pageTitle, countText: raw.countText,
      totalParsed: parsed.length, keptComps: keep.length, usedForMedian: prices.length,
      medianAU: med, meanAU: mean,
      minAU: prices.length ? Math.min(...prices) : null,
      maxAU: prices.length ? Math.max(...prices) : null,
      thin: prices.length < 3,
      langByTitleCounts: langCounts,
      comps: keep.slice(0, 12).map(p => ({
        title: p.title, priceAU: p.priceAU, sold: p.soldRaw,
        soldISO: p.soldDate.toISOString().slice(0, 10), lang: p.lang, link: p.link, img: p.img,
      })),
      excludedGradedSample: excludedGraded,
    };

    if (JSON_ONLY) { console.log(JSON.stringify(result, null, 2)); return; }

    console.log('');
    console.log(`${query}  ->  ${money(med)}  (median of ${prices.length} AU sold)`);
    if (prices.length) console.log(`Range ${money(result.minAU)} - ${money(result.maxAU)}   mean ${money(mean)}`);
    if (!parsed.length) console.log('No results at all - check the query spelling, or the card may not sell in AU.');
    else if (result.thin) console.log(`!! THIN DATA (n=${prices.length}) - treat as an estimate, not a price.`);
    const langs = Object.keys(langCounts).filter(l => l !== 'UNKNOWN');
    if (langs.length > 1) console.log(`!! MIXED LANGUAGE ${JSON.stringify(langCounts)} - EN and JP are different markets; narrow the query.`);
    if (prices.length) {
      console.log('');
      console.log('Comps used:');
      top.forEach(p => console.log(`  ${money(p.priceAU).padEnd(10)} ${p.soldDate.toISOString().slice(0, 10)}  [${p.lang}]  ${p.title.slice(0, 80)}`));
    }
    if (excludedGraded.length) {
      console.log('');
      console.log(`Graded sales excluded (${excludedGraded.length} shown) - different market:`);
      excludedGraded.forEach(p => console.log(`  ${money(p.priceAU).padEnd(10)} ${p.title.slice(0, 80)}`));
    }
    console.log('');
    console.log(url);
  } catch (e) {
    console.error(JSON.stringify({ status: 'ERROR', error: String(e), url }, null, 2));
    process.exitCode = 1;
  } finally {
    await ctx.close();
    if (browser) await browser.close();
  }
})();
