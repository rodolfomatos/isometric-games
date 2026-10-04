#!/usr/bin/env node
// Films a playthrough: drives the real game with real input, and records what it
// did.
//
// Everything else in this repository either counts pixels or reads a component
// tree. T097 is what that misses: `onInteract` was implemented by twelve entity
// files, reachable from no caller anywhere in `lib/`, and every door in the game
// was a drawing of a door. A widget test found it only after a browser walk
// sixteen times failed to go through one -- and the walk could not have gone
// through one, because thirteen of its sixteen hops were geometrically incapable
// of reaching a door (scripts/door_reachability.py).
//
// So: play the game, and write down every input and every frame. The trace is the
// primary artefact and the frames are the evidence for it. A playthrough you
// cannot replay is a screenshot with extra steps.
//
//   node scripts/browser_film.js <build-dir> <name> <click> <port>
//
// Steps come from FILM_STEPS, a JSON array of:
//   {"do": "drag", "dir": "east", "ms": 6000}   hold the virtual joystick
//   {"do": "key",  "key": "e", "ms": 200}       press an action key
//   {"do": "wait", "ms": 2000}
//
// Every step records a frame before and after, plus how many pixels changed, so
// "the party moved" and "the room changed" are two separate measurements rather
// than one vague claim.

const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
const name = process.argv[3] || 'film';
const click = process.argv[4] || '';
const port = Number(process.argv[5] || 8131);

const dir = path.join(__dirname, '..', 'build', 'film');
const STEPS = JSON.parse(process.env.FILM_STEPS || '[]');

// The virtual joystick's rest position, and how far to push it for each
// direction. These come from `make verify-browser`; the smaller viewport does not
// merely run slower, the click that starts the game lands somewhere else and the
// game never starts at all.
const JOY = { x: 86, y: 714, reach: 31 };
const DIR_VECTORS = {
  north: [0, -1], south: [0, 1], east: [1, 0], west: [-1, 0],
  northEast: [1, -1], northWest: [-1, -1], southEast: [1, 1], southWest: [-1, 1],
};

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml', '.wasm': 'application/wasm', '.otf': 'font/otf',
  '.ttf': 'font/ttf', '.woff2': 'font/woff2', '.bin': 'application/octet-stream',
  '.wav': 'audio/wav', '.ico': 'image/x-icon', '.map': 'application/json',
  '.symbols': 'text/plain', '.frag': 'text/plain', '.bin.json': 'text/plain',
};

function serve(dir) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      const rel = decodeURIComponent(req.url.split('?')[0]);
      let file = path.join(dir, rel === '/' ? 'index.html' : rel);
      if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
        if (fs.existsSync(path.join(file, 'index.html'))) {
          file = path.join(file, 'index.html');
        } else {
          res.writeHead(404);
          res.end('not found');
          return;
        }
      }
      res.writeHead(200, {
        'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      });
      fs.createReadStream(file).pipe(res);
    });
    server.listen(port, () => resolve(server));
  });
}

async function main() {
  fs.mkdirSync(dir, { recursive: true });
  const server = await serve(root);
  const browser = await chromium.launch({ args: ['--use-gl=swiftshader'] });
  const viewport = (process.env.VIEWPORT || '1280x800').split('x').map(Number);
  const page = await browser.newPage({
    viewport: { width: viewport[0], height: viewport[1] },
  });

  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(String(e)));

  const started = Date.now();
  const shot = async (tag) => {
    const file = path.join(dir, `${name}_${tag}.png`);
    await page.screenshot({ path: file });
    return path.basename(file);
  };

  await page.goto(`http://localhost:${port}/`, { waitUntil: 'load', timeout: 90000 });
  await page.waitForTimeout(5000);
  if (click) {
    const [cx, cy] = click.split(',').map(Number);
    await page.mouse.click(cx, cy);
  }
  const ph = page.locator('flt-semantics-placeholder').first();
  if (await ph.count().catch(() => 0)) {
    await ph.click({ force: true, timeout: 5000 }).catch(() => {});
  }
  // Long enough for the world to arrive before the first frame that counts.
  await page.waitForTimeout(Number(process.env.LOAD_MS || 14000));

  const log = [];
  let previous = await shot('000_start');
  log.push({
    step: 0, atMs: Date.now() - started, action: 'start',
    frame: previous, changedFrom: null,
  });

  for (const [i, step] of STEPS.entries()) {
    const tag = String(i + 1).padStart(3, '0');
    const ms = Number(step.ms || 2000);

    if (step.do === 'drag') {
      const v = DIR_VECTORS[step.dir];
      if (!v) throw new Error(`no joystick vector for ${step.dir}`);
      const [dx, dy] = v;
      // The joystick's reach is fixed, so a diagonal is the same push at 45
      // degrees. Normalising matters: a diagonal that is twice as long as a
      // cardinal is a different input, not a faster one.
      const len = Math.hypot(dx, dy) || 1;
      await page.mouse.move(JOY.x, JOY.y);
      await page.mouse.down();
      await page.mouse.move(
        JOY.x + (dx / len) * JOY.reach, JOY.y + (dy / len) * JOY.reach,
        { steps: 5 },
      );
      await page.waitForTimeout(ms);
      await page.mouse.up();
    } else if (step.do === 'key') {
      await page.keyboard.press(step.key);
      await page.waitForTimeout(ms);
    } else {
      await page.waitForTimeout(ms);
    }

    await page.waitForTimeout(Number(process.env.SETTLE_MS || 1200));
    const after = await shot(`${tag}_${step.do}_${step.dir || step.key || ''}`);
    log.push({
      step: i + 1,
      atMs: Date.now() - started,
      action: step.do,
      dir: step.dir || null,
      key: step.key || null,
      ms,
      frame: after,
      changedFrom: previous,
    });
    previous = after;
  }

  const report = {
    name,
    startedAt: new Date(started).toISOString(),
    totalMs: Date.now() - started,
    viewport: viewport.join('x'),
    steps: log,
    frames: log.length,
    errors: errors.slice(0, 10),
  };
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify(report, null, 2));

  console.log(`filmed ${log.length} step(s) in ${Math.round(report.totalMs / 1000)}s`);
  console.log(`wrote build/film/${name}.json and ${log.length} frames`);
  if (errors.length) console.log(`page errors: ${errors.length}`);

  await browser.close();
  server.close();
}

main().catch((e) => { console.error(e); process.exit(1); });