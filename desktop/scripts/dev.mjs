import { spawn } from 'node:child_process';
import { resolve, delimiter } from 'node:path';
const env = { ...process.env, AIRCARD_PYTHON: process.env.AIRCARD_PYTHON || resolve('../.tmp/windows-prototype-py312', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python') };
env.PATH = `${resolve(process.env.USERPROFILE || process.env.HOME, '.cargo/bin')}${delimiter}${env.PATH}`;
const proc = spawn(process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm', ['tauri', 'dev'], { env, stdio: 'inherit', shell: process.platform === 'win32' });
proc.on('exit', code => process.exit(code ?? 1));
