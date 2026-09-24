import { browser, $, expect } from '@wdio/globals';
describe('Installed desktop shell', () => {
  after(async () => {
    // Use the normal close path so Rust waits for a safe backend shutdown.
    // Return to the driver before the window and its connection disappear.
    await browser.tauri.execute(() => {
      setTimeout(() => { void window.__TAURI__.window.getCurrentWindow().close(); }, 100);
    });
  });
  it('loads the packaged backend, switches language and theme', async () => {
    await $('h1').waitForDisplayed();
    await $('summary').click();
    // The embedded driver changes native select values without dispatching change.
    // Dispatch the same DOM event used by the browser after choosing an option.
    await browser.execute(() => { const select = document.querySelector('select'); select.value = 'zh'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    await expect($('h1')).toHaveText('百变卡片');
    await expect($('h2')).toHaveText(expect.stringContaining('卡片'));
    await browser.execute(() => { const select = document.querySelector('select[aria-label="外观"]'); select.value = 'dark'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    await expect($('html')).toHaveAttribute('data-theme', 'dark');
    await browser.execute(() => { const select = document.querySelector('select[aria-label="语言"]'); select.value = 'en'; select.dispatchEvent(new Event('change', { bubbles: true })); });
    await expect($('h1')).toHaveText('Ditto Card');
    await expect($('main')).toHaveAttribute('aria-label', 'Cards');
    const result = await browser.tauri.execute(async () => {
      const api = window.__TAURI__;
      return await new Promise(async (resolve, reject) => {
        const id = 'smoke-' + crypto.randomUUID();
        const stop = await api.event.listen('backend-message', e => {
          if (e.payload.id === id) { stop(); resolve(e.payload); }
        });
        api.core.invoke('backend_send', { request: { v: 1, id, method: 'hello', params: {} } }).catch(reject);
      });
    });
    expect(result.ok).toBe(true);
    expect(result.result.protocol).toBe(1);
    await browser.saveScreenshot('./test-results/desktop-smoke.png');
  });
});
