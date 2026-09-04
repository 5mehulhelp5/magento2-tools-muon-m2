#!/usr/bin/env node
// smoke-browser.mjs — minimal headless-browser driver for Phase 6B smoke suites.
//
// Selects the first available backend at startup:
//   1. Playwright (`npx playwright`) — preferred
//   2. Puppeteer  (`npx puppeteer`)
//   ...and nothing else. A bare `google-chrome` / `chromium` binary is NOT a backend: the
//   raw-CDP rung that used one was deleted for fake-passing every suite (see the exit-78
//   block). `context`'s tools.headless_browser probe mirrors this exactly.
//
// Commands (one-shot, stateless; admin auth is established by admin-login, which SAVES the
// session cookies to a file the later commands re-load via --admin-cookie-file). There is no
// --token flag — auth is cookie-file based:
//
//   admin-login        --url=https://…/admin --user=… --pass=…  [--admin-path=/admin]
//                                [--save-cookies=path | --admin-cookie-file=path]  [--screenshot=path]
//   stores-config-walk --url=…  --admin-cookie-file=…  --sections=a/b/c,d/e/f  [--admin-path=/admin]
//   grid               --url=…  --admin-cookie-file=…  --route=/{admin}/...  --filter=key:val
//   visit              --url=…  [--admin-cookie-file=… | --customer-cookie-file=…]
//                                --route=/…  [--click=selector]  [--screenshot=path]
//   customer-flow      --url=…  --email=…  --pass=…  [--out-dir=…]
//   cleanup            --url=…  --admin-cookie-file=…  --customer-email=…  [--admin-path=/admin]
//                       (navigates to the filtered customer grid only — does NOT delete)
//
// Both Playwright and Puppeteer backends are supported (the Puppeteer page is adapted to the
// Playwright API used below). With "Add Secret Key to URLs" enabled (Magento default), direct
// admin GETs may redirect — statuses are reported for triage, not treated as hard failures.
//
// Output: a single JSON line on stdout.
// Exit codes:
//   0  — command succeeded with no findings
//   1  — command completed but recorded one or more findings
//   78 — no headless-browser backend available (skill skips browser suites)
//   64 — bad CLI usage

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];

if (!cmd) {
  process.stderr.write("usage: smoke-browser.mjs <command> [--key=value ...]\n");
  process.exit(64);
}

const backend = await pickBackend();
if (backend === null) {
  emit({ ok: false, error: "no headless browser backend available", code: 78 });
  process.exit(78);
}

try {
  switch (cmd) {
    case "admin-login":         await adminLogin(backend, args); break;
    case "stores-config-walk":  await storesConfigWalk(backend, args); break;
    case "grid":                await gridProbe(backend, args); break;
    case "visit":               await visit(backend, args); break;
    case "customer-flow":       await customerFlow(backend, args); break;
    case "cleanup":             await cleanup(backend, args); break;
    default:
      emit({ ok: false, error: `unknown command: ${cmd}` });
      process.exit(64);
  }
} catch (err) {
  emit({ ok: false, error: String(err?.stack || err) });
  process.exit(1);
}

// ---------- backend selection ----------

async function pickBackend() {
  if (hasCommand("npx", ["playwright", "--version"])) {
    try {
      const pw = await tryImport("playwright");
      if (pw) return { kind: "playwright", lib: pw };
    } catch { /* fall through */ }
  }
  if (hasCommand("npx", ["puppeteer", "--version"])) {
    try {
      const pp = await tryImport("puppeteer");
      if (pp) return { kind: "puppeteer", lib: pp };
    } catch { /* fall through */ }
  }
  // Deliberately no Chrome/Chromium binary rung. The raw-CDP path that consumed it was
  // deleted (see the exit-78 block below), and nothing handles kind:"cdp" any more — so
  // returning one here only made a bare Chrome install *look* like a usable backend.
  return null;
}

function hasCommand(bin, argv) {
  const r = spawnSync(bin, argv, { stdio: "ignore", timeout: 5000 });
  return r.status === 0;
}

async function tryImport(name) {
  // A bare `import(name)` resolves relative to THIS file, i.e. the skill's own directory inside
  // the toolchain checkout — where playwright is not installed. Projects install it in their own
  // node_modules, so that lookup failed and pickBackend() fell through to a false
  // "no headless browser backend available" (exit 78) on boxes where the browser works fine.
  //
  // Try the skill-relative path first (a globally installed lib still resolves), then the
  // project's, resolved from the invocation cwd upward.
  try {
    const lib = normaliseBrowserModule(await import(name));

    if (lib) return lib;
  } catch { /* fall through to the project lookup */ }

  try {
    // Everything needed is imported here rather than at module scope: this file's import block
    // varies between versions, and a missing top-level binding would throw a ReferenceError that
    // the catch below swallows -- reproducing the very false "no browser" verdict this fixes.
    const { createRequire } = await import("node:module");
    const { join } = await import("node:path");
    const { pathToFileURL } = await import("node:url");

    // createRequire walks up from this path, so a project that installs the browser anywhere
    // above the invocation cwd resolves.
    const req = createRequire(join(process.cwd(), "package.json"));

    const mod = await import(pathToFileURL(req.resolve(name)).href);

    // playwright and puppeteer ship CommonJS entry points. Imported dynamically, their exports
    // land under `.default`, so the namespace itself has no `chromium`/`launch` -- which surfaced
    // as "Cannot read properties of undefined (reading 'launch')" rather than as a resolution
    // failure. Hand back whichever shape actually carries the API.
    return normaliseBrowserModule(mod);
  } catch { return null; }
}

/**
 * Return the object that actually carries the browser API, ESM namespace or CJS default alike,
 * or null when neither shape does.
 *
 * Returning the module regardless would make a resolved-but-unusable package look like a working
 * backend, and pickBackend() would hand it to openPage() -- which is where the missing API
 * resurfaces as "Cannot read properties of undefined (reading 'launch')" instead of the honest
 * exit 78.
 */
function normaliseBrowserModule(mod) {
  if (mod?.chromium || mod?.launch) return mod;
  if (mod?.default?.chromium || mod?.default?.launch) return mod.default;

  return null;
}

/**
 * Click the first selector in `selectors` that is actually present, and report which one.
 *
 * A CSS selector list ("a, b, c") is NOT a priority list: Playwright and Puppeteer both resolve
 * it to the first match in DOCUMENT order, so a generic fallback that happens to sit higher in
 * the page beats the specific selector meant to take precedence. That is not academic on a Luma
 * storefront: the header search box is `<button type="submit">` and precedes every form, so a
 * `button[type="submit"]` fallback submits the SEARCH form instead of the login form and the
 * step "passes" having done nothing. Trying the selectors one at a time restores the intended
 * precedence, and a miss throws naming everything tried instead of clicking something random.
 */
async function clickFirst(page, selectors, what) {
  for (const sel of selectors) {
    if (await page.$(sel)) {
      await page.click(sel);
      return sel;
    }
  }
  throw new Error(`no ${what} found; tried: ${selectors.join("  |  ")}`);
}

// ---------- commands ----------

async function adminLogin(backend, args) {
  const url = required(args, "url");
  const user = required(args, "user");
  const pass = required(args, "pass");
  const screenshot = args.screenshot;
  // The admin front name is configurable in Magento (default "admin"); S1 may have probed a
  // custom one. Use it instead of a hardcoded "/admin" for the success check (FI-9).
  const adminPath = normAdminPath(args["admin-path"]);

  const { page, close, consoleErrors, captureNetworkErrors, saveCookies } = await openPage(backend);
  const netErrors = captureNetworkErrors();
  try {
    await page.goto(url, { waitUntil: "networkidle", timeout: 30000 });
    await page.fill('input[name="login[username]"]', user);
    await page.fill('input[name="login[password]"]', pass);
    await Promise.all([
      page.waitForNavigation({ waitUntil: "networkidle", timeout: 30000 }).catch(() => {}),
      // Magento_Backend::admin/login_buttons.phtml renders `<button class="action-login
      // action-primary">` with NO type attribute. `button[type="submit"]` matches the attribute,
      // not the HTML default, so the old selector never matched the admin submit at all.
      clickFirst(page, [
        "#login-form button.action-login",
        "button.action-login.action-primary",
        '#login-form button[type="submit"]',
        "#login-form button",
      ], "admin login submit button"),
    ]);
    if (screenshot) await safeScreenshot(page, screenshot);
    const dashUrl = page.url();
    // Success = landed inside the admin area AND the login form is gone. Checking for the
    // form's absence is more robust than string-matching the URL (which broke on custom admin
    // front names and on secret-key redirects).
    const loginField = await page.$('input[name="login[username]"]').catch(() => null);
    const ok = dashUrl.includes(adminPath) && !loginField;
    const status = ok ? 200 : 401;
    // Persist cookies so the stateless S4–S6 commands can re-authenticate (FI-7). Without
    // this, --admin-cookie-file pointed at a file nobody wrote and those suites could not run.
    const cookieOut = args["save-cookies"] || args["admin-cookie-file"];
    if (ok && cookieOut && saveCookies) {
      try { await saveCookies(cookieOut); } catch { /* best-effort */ }
    }
    emit({
      ok: ok && consoleErrors.length === 0 && netErrors.length === 0,
      status,
      url: dashUrl,
      adminPath,
      cookiesSaved: ok && cookieOut ? cookieOut : null,
      consoleErrors,
      networkErrors: netErrors,
      screenshot: screenshot || null,
    });
    process.exit(ok && consoleErrors.length === 0 ? 0 : 1);
  } finally {
    await close();
  }
}

// Normalise an admin front name into a leading-slash path segment, defaulting to "/admin".
function normAdminPath(raw) {
  let p = (raw || "admin").trim().replace(/^\/+|\/+$/g, "");
  return "/" + (p || "admin");
}

async function storesConfigWalk(backend, args) {
  const url = required(args, "url");
  const cookieFile = required(args, "admin-cookie-file");
  const sections = required(args, "sections").split(",").filter(Boolean);
  const adminPath = normAdminPath(args["admin-path"]);

  const { context, page, close, consoleErrors } = await openPage(backend, { cookieFile });
  const results = [];
  try {
    for (const section of sections) {
      // NOTE: when "Add Secret Key to URLs" is enabled (Magento default), a direct GET to a
      // config section can redirect to the dashboard because it lacks the per-action key. A
      // 200 here is a real load; a 302/redirect to login/dashboard is reported as the status
      // and should be triaged rather than treated as a hard failure.
      const routeUrl = `${url.replace(/\/+$/, "")}${adminPath}/system_config/edit/section/${encodeURIComponent(section)}`;
      const resp = await page.goto(routeUrl, { waitUntil: "networkidle", timeout: 30000 });
      const status = resp ? resp.status() : 0;
      results.push({ section, status, consoleErrors: [...consoleErrors] });
      consoleErrors.length = 0;
    }
    emit({ ok: results.every(r => r.status >= 200 && r.status < 400), results });
    process.exit(results.every(r => r.status >= 200 && r.status < 400) ? 0 : 1);
  } finally {
    await close();
  }
}

async function gridProbe(backend, args) {
  const url = required(args, "url");
  const cookieFile = required(args, "admin-cookie-file");
  const route = required(args, "route");
  const filter = args.filter; // form key:val

  const { page, close, consoleErrors } = await openPage(backend, { cookieFile });
  try {
    const resp = await page.goto(`${url.replace(/\/+$/, "")}${route}`, {
      waitUntil: "networkidle",
      timeout: 30000,
    });
    const status = resp ? resp.status() : 0;
    let rowsBefore = await countGridRows(page);
    let rowsAfter = rowsBefore;
    let filterApplied = false;
    if (filter) {
      const [key, val] = filter.split(":");
      filterApplied = await applyGridFilter(page, key, val);
      if (filterApplied) {
        await page.waitForLoadState("networkidle", { timeout: 30000 }).catch(() => {});
        rowsAfter = await countGridRows(page);
      }
    }
    emit({
      ok: status >= 200 && status < 400 && consoleErrors.length === 0,
      status,
      rowsBefore,
      rowsAfter,
      filterApplied,
      consoleErrors,
    });
    process.exit(status >= 200 && status < 400 && consoleErrors.length === 0 ? 0 : 1);
  } finally {
    await close();
  }
}

async function visit(backend, args) {
  const url = required(args, "url");
  const route = required(args, "route");
  const click = args.click;
  const screenshot = args.screenshot;
  const cookieFile = args["admin-cookie-file"] || args["customer-cookie-file"];

  const { page, close, consoleErrors } = await openPage(backend, { cookieFile });
  try {
    const resp = await page.goto(`${url.replace(/\/+$/, "")}${route}`, {
      waitUntil: "networkidle",
      timeout: 30000,
    });
    const status = resp ? resp.status() : 0;
    let clicked = false;
    if (click) {
      try {
        await page.click(click, { timeout: 5000 });
        await page.waitForLoadState("networkidle", { timeout: 30000 }).catch(() => {});
        clicked = true;
      } catch { /* recorded below */ }
    }
    if (screenshot) await safeScreenshot(page, screenshot);
    emit({
      ok: status >= 200 && status < 400 && consoleErrors.length === 0 && (!click || clicked),
      status,
      url: page.url(),
      clicked,
      consoleErrors,
      screenshot: screenshot || null,
    });
    process.exit(status >= 200 && status < 400 && consoleErrors.length === 0 ? 0 : 1);
  } finally {
    await close();
  }
}

async function customerFlow(backend, args) {
  const url = required(args, "url");
  const email = required(args, "email");
  const pass = required(args, "pass");
  const outDir = args["out-dir"] || ".";
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });

  const steps = [];
  const { page, close, consoleErrors } = await openPage(backend);
  try {
    // register
    let resp = await page.goto(`${url.replace(/\/+$/, "")}/customer/account/create/`, { timeout: 30000 });
    await page.fill('input[name="firstname"]', "Smoke");
    await page.fill('input[name="lastname"]', "Tester");
    await page.fill('input[name="email"]', email);
    await page.fill('input[name="password"]', pass);
    await page.fill('input[name="password_confirmation"]', pass);
    await Promise.all([
      page.waitForNavigation({ timeout: 30000 }).catch(() => {}),
      // Scoped to the account form: an unscoped submit selector hits the header search button.
      clickFirst(page, [
        '#form-validate button[type="submit"]',
        ".form-create-account button.action.submit",
        '.form-create-account button[type="submit"]',
      ], "create-account submit button"),
    ]);
    steps.push({ step: "register", url: page.url(), consoleErrors: [...consoleErrors] });
    consoleErrors.length = 0;

    // logout
    await page.goto(`${url.replace(/\/+$/, "")}/customer/account/logout/`, { timeout: 30000 });
    steps.push({ step: "logout", url: page.url(), consoleErrors: [...consoleErrors] });
    consoleErrors.length = 0;

    // login
    await page.goto(`${url.replace(/\/+$/, "")}/customer/account/login/`, { timeout: 30000 });
    await page.fill('input[name="login[username]"]', email);
    await page.fill('input[name="login[password]"]', pass);
    await Promise.all([
      page.waitForNavigation({ timeout: 30000 }).catch(() => {}),
      // `#send2` is the id Magento_Customer::form/login.phtml puts on the submit button.
      clickFirst(page, [
        "#send2",
        'form.form-login button[type="submit"]',
        '.login-container button[type="submit"]',
      ], "customer login submit button"),
    ]);
    steps.push({ step: "login", url: page.url(), consoleErrors: [...consoleErrors] });
    consoleErrors.length = 0;

    // visit each My Account tab
    const tabs = [
      "/customer/account/",
      "/customer/account/edit/",
      "/customer/address/",
      "/sales/order/history/",
      "/downloadable/customer/products/",
      "/newsletter/manage/",
    ];
    for (const t of tabs) {
      resp = await page.goto(`${url.replace(/\/+$/, "")}${t}`, { timeout: 30000 });
      steps.push({ step: `visit ${t}`, status: resp ? resp.status() : 0, consoleErrors: [...consoleErrors] });
      consoleErrors.length = 0;
    }

    const ok = steps.every(s => (s.status === undefined || (s.status >= 200 && s.status < 400)) && s.consoleErrors.length === 0);
    emit({ ok, steps, throwawayEmail: email });
    process.exit(ok ? 0 : 1);
  } finally {
    await close();
  }
}

async function cleanup(backend, args) {
  const url = required(args, "url");
  const cookieFile = required(args, "admin-cookie-file");
  const email = required(args, "customer-email");
  const adminPath = normAdminPath(args["admin-path"]);
  const { page, close } = await openPage(backend, { cookieFile });
  try {
    // This only NAVIGATES to the filtered customer grid — it does NOT delete the customer
    // (grid mass-delete needs the form key + secret key, which a direct GET cannot supply).
    // The emitted note says so; S9 acceptance text is downgraded to match (FI-10).
    await page.goto(`${url.replace(/\/+$/, "")}${adminPath}/customer/index/index?email=${encodeURIComponent(email)}`, { timeout: 30000 });
    emit({
      ok: true,
      deleted: false,
      note: "cleanup is best-effort: navigated to the filtered customer grid but did NOT delete. Remove the throwaway customer manually (or via a data fixture) and verify in admin.",
    });
    process.exit(0);
  } finally {
    await close();
  }
}

// ---------- browser open ----------

async function openPage(backend, opts = {}) {
  const consoleErrors = [];
  const networkErrorTaps = [];

  if (backend.kind === "playwright") {
    const browser = await backend.lib.chromium.launch({ headless: true });
    // ignoreHTTPSErrors is required, not optional: local Magento stacks are routinely served over
    // a self-signed cert, and without this every navigation fails ERR_CERT_AUTHORITY_INVALID.
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    if (opts.cookieFile && existsSync(opts.cookieFile)) {
      try {
        // ESM has no `require`; use the imported readFileSync (FI-7).
        const cookies = JSON.parse(readFileSync(opts.cookieFile, "utf8"));
        await context.addCookies(cookies);
      } catch { /* ignore */ }
    }
    const page = await context.newPage();
    page.on("console", msg => {
      if (msg.type() === "error") consoleErrors.push(msg.text());
    });
    page.on("pageerror", err => consoleErrors.push(String(err)));
    const captureNetworkErrors = () => {
      const errors = [];
      page.on("response", resp => { if (resp.status() >= 500) errors.push({ url: resp.url(), status: resp.status() }); });
      networkErrorTaps.push(errors);
      return errors;
    };
    return {
      context, page, consoleErrors, captureNetworkErrors,
      // Persist the post-login cookies so the stateless S4–S6 commands can re-auth (FI-7).
      saveCookies: async (path) => { writeFileSync(path, JSON.stringify(await context.cookies(), null, 2)); },
      close: async () => { await browser.close().catch(() => {}); },
    };
  }

  if (backend.kind === "puppeteer") {
    // Same self-signed-cert reason as the Playwright context above. Puppeteer renamed the option
    // in v22 (ignoreHTTPSErrors -> acceptInsecureCerts); pass both so either version honours it and
    // the other ignores an unknown key.
    const browser = await backend.lib.launch({
      headless: "new",
      ignoreHTTPSErrors: true,
      acceptInsecureCerts: true,
    });
    const rawPage = await browser.newPage();
    if (opts.cookieFile && existsSync(opts.cookieFile)) {
      try {
        const cookies = JSON.parse(readFileSync(opts.cookieFile, "utf8"));
        if (cookies.length) await rawPage.setCookie(...cookies);
      } catch { /* ignore */ }
    }
    rawPage.on("console", msg => { if (msg.type() === "error") consoleErrors.push(msg.text()); });
    rawPage.on("pageerror", err => consoleErrors.push(String(err)));
    // Adapt the Puppeteer page to the Playwright surface the commands use (FI-8): Puppeteer
    // has no page.fill()/waitForLoadState() and uses networkidle0, not networkidle.
    const page = adaptPuppeteerPage(rawPage);
    return {
      context: null, page, consoleErrors,
      captureNetworkErrors: () => { const e = []; rawPage.on("response", r => { if (r.status() >= 500) e.push({ url: r.url(), status: r.status() }); }); return e; },
      saveCookies: async (path) => { writeFileSync(path, JSON.stringify(await rawPage.cookies(), null, 2)); },
      close: async () => { await browser.close().catch(() => {}); },
    };
  }

  // No real browser-automation backend (Playwright or Puppeteer) is available.
  //
  // The previous raw-CDP fallback returned a fake page whose goto() always reported HTTP 200
  // and whose actions were no-ops — so EVERY browser smoke suite exited 0 (PASS) without a
  // browser ever running (FI-2). That is worse than not running: it reports green on red.
  //
  // Refuse to fake it. Emit an honest "skipped/unavailable" record and exit 78 so the caller
  // records the suite as NOT RUN (unverified), never as passed.
  emit({
    ok: false,
    skipped: true,
    reason:
      "No browser automation backend available. Install one in the project, e.g. " +
      "`npm i -D playwright && npx playwright install chromium` (or Puppeteer), then re-run. " +
      "The raw-CDP fallback was removed because it fake-passed smoke suites.",
  });
  process.exit(78);
}

// Wrap a Puppeteer page so the command code (written against the Playwright API) runs
// unchanged: add fill()/waitForLoadState() and translate Playwright's "networkidle" wait
// state to Puppeteer's "networkidle0" (FI-8).
function adaptPuppeteerPage(page) {
  const normalize = (opts) =>
    (opts && opts.waitUntil === "networkidle") ? { ...opts, waitUntil: "networkidle0" } : opts;
  const origGoto = page.goto.bind(page);
  page.goto = (url, opts) => origGoto(url, normalize(opts));
  const origWaitNav = page.waitForNavigation.bind(page);
  page.waitForNavigation = (opts) => origWaitNav(normalize(opts));
  page.fill = async (sel, val) => {
    await page.waitForSelector(sel, { timeout: 30000 });
    await page.$eval(sel, (el) => { el.value = ""; });
    await page.type(sel, String(val));
  };
  page.waitForLoadState = async (_state, opts) => {
    try { await page.waitForNetworkIdle(opts || {}); } catch { /* older puppeteer: no-op */ }
  };
  return page;
}

// ---------- helpers ----------

async function safeScreenshot(page, path) {
  try {
    const dir = dirname(path);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    await page.screenshot({ path, fullPage: true });
  } catch { /* ignore */ }
}

async function countGridRows(page) {
  try {
    return await page.evaluate(() => {
      const tbody = document.querySelector("table.data-grid tbody, table.admin__data-grid-table tbody");
      return tbody ? tbody.querySelectorAll("tr").length : 0;
    });
  } catch { return -1; }
}

async function applyGridFilter(page, key, val) {
  try {
    // Use page.fill(selector) — works on both backends (the Puppeteer adapter provides it).
    // ElementHandle.fill() is Playwright-only and crashed Puppeteer (FI-8).
    for (const sel of [`input[name="${key}"]`, `input[data-bind*="${key}"]`]) {
      if (await page.$(sel)) {
        await page.fill(sel, String(val));
        await page.keyboard.press("Enter");
        return true;
      }
    }
    return false;
  } catch { return false; }
}

function required(args, key) {
  if (args[key] === undefined || args[key] === "") {
    emit({ ok: false, error: `missing --${key}` });
    process.exit(64);
  }
  return args[key];
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv) {
  const out = { _: [] };
  for (const a of argv) {
    if (a.startsWith("--")) {
      const eq = a.indexOf("=");
      if (eq === -1) out[a.slice(2)] = "true";
      else out[a.slice(2, eq)] = a.slice(eq + 1);
    } else out._.push(a);
  }
  return out;
}
