import { spawnSync } from 'node:child_process';
import { resolve, join } from 'node:path';
import { cpSync, mkdirSync, rmSync } from 'node:fs';
const root = resolve('..');
const python = process.env.AIRCARD_PYTHON || join(root, '.tmp/windows-prototype-py312', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
const destination = resolve('src-tauri/binaries');
const output = ['--noconfirm', '--clean', '--distpath', join(root, 'build/desktop-backend'), '--workpath', join(root, 'build/pyinstaller')];
const args = process.platform === 'darwin'
  ? ['-m', 'PyInstaller', ...output, resolve('scripts/aircard-backend.macos.spec')]
  : ['-m', 'PyInstaller', ...output, '--name', 'aircard-backend', '--onedir', '--specpath', join(root, 'build'), '--hidden-import', 'pymobiledevice3.services.afc', '--hidden-import', 'pymobiledevice3.lockdown', '--hidden-import', 'pymobiledevice3.usbmux', '--hidden-import', 'pefile', join(root, 'desktop_backend.py')];
const result = spawnSync(python, args, { cwd: root, stdio: 'inherit' });
if (result.status !== 0) process.exit(result.status || 1);
if (process.platform === 'darwin') {
  // PyInstaller rewrites Mach-O load commands even for binaries listed as data.
  // Copy the signed helper only after PyInstaller completes to keep its links
  // to the macOS system frameworks intact.
  const bin = join(root, 'build/desktop-backend/aircard-backend/_internal/bin');
  mkdirSync(bin, { recursive: true });
  cpSync(join(root, 'build/airtraffic_host'), join(bin, 'airtraffic_host'));
}
mkdirSync(destination, { recursive: true });
const target = resolve(destination, 'backend');
if (target !== join(root, 'desktop', 'src-tauri', 'binaries', 'backend')) throw new Error('Invalid packaging destination');
rmSync(target, { recursive: true, force: true });
cpSync(join(root, 'build/desktop-backend/aircard-backend'), target, { recursive: true, force: true });
