import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
  root: path.resolve(__dirname, 'renderer'),
  base: './', // Use relative paths for file:// protocol
  build: {
    outDir: path.resolve(__dirname, 'renderer-dist'),
    emptyOutDir: true,
  },
});
