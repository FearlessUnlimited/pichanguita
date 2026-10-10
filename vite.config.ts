/// <reference types="vitest/config" />
import { resolve } from 'node:path'
import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Base configurable: '/pichanguita/' en GitHub Pages, '/' con dominio propio.
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  return {
    base: env.VITE_BASE || '/',
    plugins: [react(), tailwindcss()],
    build: {
      rollupOptions: {
        input: {
          app: resolve(import.meta.dirname, 'index.html'),
          organizadores: resolve(import.meta.dirname, 'organizadores/index.html'),
          canchas: resolve(import.meta.dirname, 'canchas/index.html'),
          privacidad: resolve(import.meta.dirname, 'privacidad/index.html'),
        },
      },
    },
    test: {
      include: ['tests/**/*.test.ts'],
      testTimeout: 30000,
      hookTimeout: 60000,
    },
  }
})
