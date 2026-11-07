// Renders scene.js to a PNG. usage: node render.js out.png [size] [json overrides]
const { chromium } = require('playwright'); const fs = require('fs'); const path = require('path');
const out = process.argv[2], size = Number(process.argv[3] || 2048), opts = JSON.parse(process.argv[4] || '{}');
const root = __dirname, three = path.join(root, 'node_modules/three');
(async () => {
  const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const p = await b.newPage({ viewport: { width: size, height: size } });
  p.on('console', m => console.log('page:', m.text())); p.on('pageerror', e => console.log('error:', e.message));
  await p.route('http://icon.local/**', r => {
    const u = new URL(r.request().url()).pathname;
    const f = u.startsWith('/three/') ? path.join(three, u.slice(7)) : path.join(root, u);
    r.fulfill({ body: fs.readFileSync(f), contentType: f.endsWith('.js') ? 'text/javascript' : 'text/html' });
  });
  await p.route('http://icon.local/', r => r.fulfill({ contentType: 'text/html', body: `<!doctype html>
    <style>html,body{margin:0;background:transparent}canvas{display:block}</style>
    <script type="importmap">{"imports":{"three":"/three/build/three.module.js","three/addons/":"/three/examples/jsm/"}}</script>
    <script>window.ICON_SIZE=${size};Object.assign(window, ${JSON.stringify(opts)});</script>
    <script type="module" src="/scene.js"></script>` }));
  await p.goto('http://icon.local/');
  await p.waitForFunction(() => window.RENDERED, null, { timeout: 120000 });
  await p.locator('canvas').screenshot({ path: out, omitBackground: true });
  await b.close();
})();
