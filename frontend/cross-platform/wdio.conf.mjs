import { resolve, dirname, join } from 'node:path';
import { mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
const application = process.env.AIRCARD_E2E_BINARY || resolve(`src-tauri/target/release/DittoCard${process.platform === 'win32' ? '.exe' : ''}`);
async function waitForBackendExit() {
  const backendPath = join(dirname(application), 'backend').replaceAll('\\', '/').toLowerCase();
  const deadline = Date.now() + 60000;
  while (Date.now() < deadline) {
    const output = process.platform === 'win32'
      ? execFileSync(join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe'), ['-NoProfile', '-NonInteractive', '-Command', "Get-CimInstance Win32_Process -Filter \"Name = 'aircard-backend.exe'\" | Select-Object -ExpandProperty CommandLine"], { encoding: 'utf8', windowsHide: true })
      : execFileSync('/bin/ps', ['-axo', 'command='], { encoding: 'utf8' });
    if (!output.replaceAll('\\', '/').toLowerCase().includes(backendPath)) return;
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  throw new Error('Test backend did not exit; refusing to overwrite its runtime files.');
}
export const config = {
  onPrepare() { mkdirSync(resolve('test-results'), { recursive: true }); },
  onComplete: waitForBackendExit,
  runner: 'local', framework: 'mocha', specs: ['./e2e/**/*.mjs'], maxInstances: 1,
  logLevel: 'warn', reporters: ['spec'], mochaOpts: { timeout: 60000 },
  services: [['@wdio/tauri-service', { driverProvider: 'embedded', captureBackendLogs: true }]],
  capabilities: [{ browserName: 'tauri', 'tauri:options': {
    application,
  } }],
};
