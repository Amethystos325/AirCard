import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], clearScreen: false, build: { target: 'es2022' }, server: { port: 1420, strictPort: true }, test: { environment: 'jsdom', setupFiles: './src/test-setup.ts', exclude: ['node_modules/**', 'e2e/**', 'src-tauri/**'] } });
