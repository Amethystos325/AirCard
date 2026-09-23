import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
const result = spawnSync(process.execPath, [resolve('node_modules/@tauri-apps/cli/tauri.js'), 'build', ...process.argv.slice(2), '--', '--locked'], { stdio: 'inherit' });
process.exit(result.status ?? 1);
