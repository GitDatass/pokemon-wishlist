// Batch eBay-AU-sold valuation over queries.json, one browser session, incremental save.
//
// Usage: node ebay_batch.cjs [options]
//   --queries F : input file (default queries.json)
//   --out F     : output file (default ebay_results.json)
//   --n 5       : comps feeding each median (default 5)
//   --profile P : persistent browser profile dir (default ./ebay-profile)
//   --headless  : run without a visible window (more likely to be blocked)
//
// queries.json is an array of either plain strings or objects:
//   [ "Swinub 165/159",
//     { "row": "charizard-sir", "q": "Charizard ex 199/165 English", "coll": true } ]
//   row  : your own label for the card (defaults to the query)
//   coll : collision set (EN/JP share numbering) - downloads thumbnails for visual classification
//
// Results stream to the output file after every card, so an interrupted run keeps its progress.
// Run `node ebay_login.cjs` first - eBay gates sold listings behind a signed-in session.
// Requires: npm install playwright && npx playwright install chromium
const { chromium } = require('playwright');
const fs = require('fs');
const https = require('https');
const path = require('path');

const argv = process.argv.slice(2);
const flags = {};
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) flags[argv[i].slice(2)] = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : true;
}
const DIR = process.cwd();
const QFILE = path.resolve(DIR, flags.queries && flags.queries !== true ? flags.queries : 'queries.json');
const OUT = path.resolve(DIR, flags.out && flags.out !== true ? flags.out : 'ebay_results.json');
const THUMBS = path.resolve(DIR, 'thumbs');
const N = parseInt(flags.n, 10) || 5;
const HEADLESS = !!flags.headless;
const PROFILE = path.resolve(DIR, flags.profile && flags.profile !== true ? flags.profile : 'ebay-profile');

if (!fs.existsSync(QFILE)) {
  console.error(`No queries file at ${QFILE}. Create it as a JSON array of query strings or {row,q,coll} objects.`);
  process.exit(1);
}
const queries = JSON.parse(fs.readFileSync(QFILE, 'utf8')).map(entry =>
  typeof entry === 'string' ? { row: entry, q: entry, coll: false } : { row: entry.row || entry.q, q: entry.q, coll: !!entry.coll }
);

const LOT_RE = /\b(lot|lots|bundle|joblot|job lot|playset|complete set|master set|choose|pick|singles|\d+\s*cards|cards!|x\s?\d{2,})\b/i;
const GRADED_RE = /\b(psa|cgc|bgs|ace|graded|gem mt|gem mint\s*10|\bslab\b)\b/i;
const NONAU_RE = /from\s+(china|japan|united states|usa|hong kong|singapore|united kingdom|germany|korea|taiwan|canada|new zealand|thailand|malaysia|philippines)/i;
const WALL_RE = /Sign in or Register|Security measure|Error Page|Pardon Our Interruption|checking your browser/i;
const MONTHS = { jan:0, feb:1, mar:2, apr:3, may:4, jun:5, jul:6, aug:7, sep:8, oct:9, nov:10, dec:11 };

function parseSold(c) { const m = c.match(/Sold\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})/i); if (!m) return null; return new Date(Date.UTC(+m[3], MONTHS[m[2].toLowerCase()], +m[1])); }
function parsePrice(s) { const m = s.replace(/,/g, '').match(/([\d.]+)/); return m ? parseFloat(m[1]) : null; }
function clean(t) { return t.replace(/\n?Opens in a new window or tab/gi, '').replace(/^NEW LISTING/i, '').trim(); }
function median(a) { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); const m = Math.floor(s.length / 2); return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; }
function langByTitle(t) {
  if (/[぀-ヿ㐀-鿿ｦ-ﾟ]/.test(t)) return 'JP';
  if (/\b(japanese|japan|jpn)\b/i.test(t)) return 'JP';
  if (/\bsv\d[a-z]\b/i.test(t)) return 'JP';
  if (/\b(english|eng)\b/i.test(t)) return 'EN';
  if (/illustration rare|ultra rare|special illustration|hyper rare|double rare/i.test(t)) return 'EN';
  return 'UNKNOWN';
}
function dl(url, dest) {
  return new Promise(res => {
    try {
      const f = fs.createWriteStream(dest);
      https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, r => {
        if (r.statusCode !== 200) { f.close(); fs.unlink(dest, () => {}); return res(false); }
        r.pipe(f); f.on('finish', () => f.close(() => res(true)));
      }).on('error', () => { f.close(); fs.unlink(dest, () => {}); res(false); });
    } catch { res(false); }
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: HEADLESS, channel: HEADLESS ? undefined : 'chromium',
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
    locale: 'en-AU', timezoneId: 'Australia/Sydney', viewport: { width: 1400, height: 1000 },
  });
  const page = ctx.pages()[0] || await ctx.newPage();
  await page.goto('https://www.ebay.com.au/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  for (const s of ['#gdpr-banner-accept', 'button[aria-label*="Accept"]']) {
    const b = await page.$(s); if (b) { try { await b.click({ timeout: 2000 }); } catch {} }
  }
  await sleep(1500);

  const results = [];
  let consecutiveWalls = 0;

  for (let i = 0; i < queries.length; i++) {
    const { row, q, coll } = queries[i];
    const num = (q.match(/\d{1,3}\s*\/\s*\d{1,3}/) || [q])[0].replace(/\s+/g, '');
    const mustRe = new RegExp(num.replace(/[/]/g, '\\s*/\\s*'), 'i');
    const nkw = encodeURIComponent(q).replace(/%20/g, '+');
    const url = 'https://www.ebay.com.au/sch/i.html?_nkw=' + nkw + '&LH_Sold=1&LH_Complete=1&_sop=13&LH_PrefLoc=1';
    const rec = { row, q, url, valueAU: null, n: 0, thin: true, walled: false, langCounts: {}, comps: [], note: '' };

    try {
      let items = [];
      let title = '';
      let walled = false;
      for (let attempt = 1; attempt <= 3; attempt++) {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
        await sleep(2200);
        title = await page.title();
        items = await page.evaluate(() => {
          const out = [];
          document.querySelectorAll('.su-card-container, li.s-item').forEach(li => {
            const g = sels => { for (const s of sels) { const e = li.querySelector(s); if (e && e.innerText.trim()) return e.innerText.trim(); } return ''; };
            const t = g(['.s-card__title', '.s-item__title', '[class*="title"]']);
            const p = g(['.s-card__price', '.s-item__price', '[class*="price"]']);
            if (!t || !p) return;
            const cap = g(['.s-card__caption', '.s-item__caption', '.POSITIVE', '[class*="caption"]']);
            const full = li.innerText.replace(/\s+/g, ' ').trim();
            const a = li.querySelector('a[href*="/itm/"]'); const im = li.querySelector('img');
            out.push({ title: t, price: p, cap, full, link: a ? a.href.split('?')[0] : '', img: im ? (im.src || im.getAttribute('data-src') || '') : '' });
          });
          return out;
        });
        walled = WALL_RE.test(title);
        if (!walled) break;
        await sleep(4000 * attempt);
      }

      if (walled) {
        rec.walled = true;
        rec.note = `BLOCKED ("${title}")`;
        consecutiveWalls++;
        // three cards in a row blocked means the session is dead - stop rather than
        // grind through the list writing zeros that look like real "no comps" answers
        if (consecutiveWalls >= 3) {
          results.push(rec);
          fs.writeFileSync(OUT, JSON.stringify(results, null, 2));
          console.error('');
          console.error(`ABORTED at card ${i + 1}/${queries.length} - eBay blocked 3 searches in a row ("${title}").`);
          console.error('Your signed-in session has expired. Fix and re-run:');
          console.error('  node ebay_login.cjs' + (flags.profile ? ` --profile ${flags.profile}` : ''));
          console.error(`Partial results for the first ${results.length - 1} cards are saved in ${OUT}.`);
          await ctx.close();
          process.exit(2);
        }
      } else {
        consecutiveWalls = 0;

        let cands = items.map(it => ({
          title: clean(it.title),
          priceAU: parsePrice(it.price),
          soldRaw: (it.cap.match(/Sold[^\n]*/i) || [''])[0],
          soldDate: parseSold(it.cap) || parseSold(it.full),
          link: it.link,
          img: (it.img || '').replace(/s-l\d+\.(webp|jpg|jpeg|png)/i, 's-l500.jpg'),
          lang: langByTitle(it.title),
          isLot: LOT_RE.test(it.title), isGraded: GRADED_RE.test(it.title),
          nonAU: NONAU_RE.test(it.full), exact: mustRe.test(it.title),
        })).filter(p => p.exact && !p.isLot && !p.isGraded && !p.nonAU && p.priceAU && p.soldDate)
          .sort((a, b) => b.soldDate - a.soldDate)
          .slice(0, 10);

        // collision sets: pull thumbnails so a vision pass can classify EN vs JP by eye
        if (coll) {
          const safe = String(row).replace(/[^\w]+/g, '_');
          const cdir = path.join(THUMBS, safe);
          fs.mkdirSync(cdir, { recursive: true });
          for (let k = 0; k < cands.length; k++) {
            if (!cands[k].img) continue;
            const dest = path.join(cdir, String(k).padStart(2, '0') + '.jpg');
            cands[k].thumb = (await dl(cands[k].img, dest)) ? dest : '';
          }
        }

        const prices = cands.slice(0, N).map(p => p.priceAU);
        rec.valueAU = median(prices);
        rec.n = prices.length;
        rec.thin = prices.length < 3;
        rec.langCounts = cands.reduce((o, p) => { o[p.lang] = (o[p.lang] || 0) + 1; return o; }, {});
        rec.comps = cands.map(p => ({
          title: p.title, priceAU: p.priceAU, soldISO: p.soldDate.toISOString().slice(0, 10),
          lang: p.lang, link: p.link, thumb: p.thumb || '',
        }));
        const mixed = Object.keys(rec.langCounts).filter(l => l !== 'UNKNOWN').length > 1;
        rec.note = `parsed ${items.length}, kept ${cands.length}`
          + (rec.thin ? ' [THIN]' : '')
          + (mixed ? ' [MIXED EN/JP - verify]' : '')
          + (coll ? ' [collision set]' : '');
      }
    } catch (e) {
      rec.note = 'ERROR ' + String(e).slice(0, 120);
    }

    results.push(rec);
    fs.writeFileSync(OUT, JSON.stringify(results, null, 2));
    const val = rec.valueAU != null ? 'A$' + rec.valueAU.toFixed(2) : '?';
    const warn = (rec.walled || rec.thin || rec.note.startsWith('ERROR')) ? rec.note : '';
    process.stdout.write(`[${i + 1}/${queries.length}] ${row} -> ${val} (n=${rec.n}) ${warn}\n`);

    // pacing with jitter - removing this gets you soft-blocked with silent empty results
    await sleep(2000 + Math.floor(Math.random() * 1500));
  }

  await ctx.close();

  const priced = results.filter(r => r.valueAU != null);
  const thin = priced.filter(r => r.thin);
  const walled = results.filter(r => r.walled);
  const total = priced.reduce((a, r) => a + r.valueAU, 0);
  console.log('');
  console.log(`DONE. ${priced.length}/${results.length} priced` + (thin.length ? `, ${thin.length} thin` : '') + (walled.length ? `, ${walled.length} BLOCKED` : '') + '.');
  console.log(`Total (priced rows only): A$${total.toFixed(2)}`);
  if (walled.length) console.log('Blocked rows are NOT "worth nothing" - re-run them after `node ebay_login.cjs`.');
  console.log('Wrote ' + OUT);
})();
