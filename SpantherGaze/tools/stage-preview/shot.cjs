const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] });
  const p = await b.newPage({ viewport: { width: 844, height: 390 }, deviceScaleFactor: 1 });
  p.on('pageerror', e => console.log('pageerror:', e.message));
  p.on('console', m => { if (m.type() === 'error') console.log('console:', m.text()); });
  for (const s of (process.argv[2] || 'moles,pond').split(',')) {
    await p.goto(`http://127.0.0.1:8766/index.html?s=${s}`);
    await p.waitForFunction(() => window.__ready === true, null, { timeout: 90000 });
    await p.screenshot({ path: `${s}.png` });
    console.log('shot', s);
  }
  await b.close();
})();
