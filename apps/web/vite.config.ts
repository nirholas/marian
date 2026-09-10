import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  resolve: {
    alias: {
      '@marian/sdk': resolve(__dirname, '../../packages/sdk/src/index.ts'),
      '@data': resolve(__dirname, '../../data'),
    },
  },
  server: { port: 5273, strictPort: false },
  build: { target: 'es2022', sourcemap: true },
});
