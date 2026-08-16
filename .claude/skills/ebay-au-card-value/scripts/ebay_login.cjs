// One-time eBay AU sign-in. Opens a real browser window, waits for you to log in,
// then saves the session to a persistent profile the valuation scripts reuse.
//
// Usage: node ebay_login.cjs [--profile ./ebay-profile]
//
// eBay gates SOLD-listing search behind a signed-in session. Without this step the
// scrapers get "Sign in or Register" or "Security measure" and return zero comps.
// Re-run whenever the session expires (roughly monthly).
const { chromium } = require('playwright');
const path = require('path');

const argv = process.argv.slice(2);
const flags = {};
for (let i = 0; i < argv.length; i++) {
  if (argv[i].startsWith('--')) flags[argv[i].slice(2)] = (argv[i + 1] && !argv[i + 1].startsWith('--')) ? argv[++i] : true;
}
const PROFILE = path.resolve(process.cwd(), flags.profile && flags.profile !== true ? flags.profile : 'ebay-profile');

const TEST_URL = 'https://www.ebay.com.au/sch/i.html?_nkw=Pikachu+V+SWSH198&LH_Sold=1&LH_Complete=1&_sop=13&LH_PrefLoc=1';
const WALL_RE = /Sign in or Register|Security measure|Error Page|Pardon Our Interruption|checking your browser/i;
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  console.log('Profile: ' + PROFILE);
  const ctx = await chromium.launchPersistentContext(PROFILE, {
    headless: false, channel: 'chromium',
    args: ['--disable-blink-features=AutomationControlled', '--no-sandbox'],
    viewport: { width: 1280, height: 900 }, locale: 'en-AU', timezoneId: 'Australia/Sydney',
  });
  let closed = false;
  ctx.on('close', () => { closed = true; });
  const page = ctx.pages()[0] || await ctx.newPage();

  try {
    await page.goto('https://www.ebay.com.au/signin/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  } catch (e) {
    console.log('Initial navigation hiccup (window stays open): ' + String(e).slice(0, 100));
  }

  console.log('');
  console.log('  >> Sign in to eBay in the browser window that just opened.');
  console.log('  >> Waiting up to 12 minutes. Leave the window open.');
  console.log('');

  let signedIn = false;
  for (let i = 0; i < 144 && !closed; i++) {
    await sleep(5000);
    try {
      const greeting = await page.evaluate(() => {
        const e = document.querySelector('#gh-ug, .gh-identity, [data-testid="gh-user-greeting"]');
        return e ? e.textContent.trim() : '';
      }).catch(() => '');
      // signed out reads "G'day! Sign in or register"; signed in reads "G'day <name>" / "Hi <name>"
      if (/G'day|Hi\b|Hello\b/i.test(greeting) && !/sign in|register/i.test(greeting)) {
        console.log('Signed in as: ' + greeting.slice(0, 60));
        signedIn = true;
        break;
      }
    } catch { /* page mid-navigation, keep waiting */ }
  }

  if (closed) { console.log('Window closed before sign-in was confirmed. Nothing saved.'); process.exit(2); }
  if (!signedIn) { console.log('Timed out waiting for sign-in.'); await ctx.close(); process.exit(3); }

  console.log('Verifying sold-listings access...');
  let verified = false;
  for (let a = 1; a <= 3 && !verified; a++) {
    try {
      await page.goto(TEST_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
      await page.waitForSelector('.su-card-container, li.s-item', { timeout: 15000 }).catch(() => {});
      await sleep(2500);
      const title = await page.title();
      const n = await page.evaluate(() => document.querySelectorAll('.su-card-container, li.s-item').length);
      console.log(`  attempt ${a}: title="${title}" results=${n}`);
      if (n > 0 && !WALL_RE.test(title)) verified = true; else await sleep(5000);
    } catch (e) {
      console.log(`  attempt ${a} error: ` + String(e).slice(0, 90));
      await sleep(5000);
    }
  }

  await ctx.close();
  if (verified) {
    console.log('');
    console.log('LOGIN OK - sold-listing access confirmed. Profile saved to:');
    console.log('  ' + PROFILE);
    console.log('The valuation scripts will reuse it automatically.');
  } else {
    console.log('');
    console.log('Signed in, but sold search is still walled. Try again in a few minutes,');
    console.log('or browse a few sold listings manually in that window first to warm the session.');
    process.exit(4);
  }
})();
