import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': path.resolve(import.meta.dirname, './src'),
    },
  },
  build: {
    rolldownOptions: {
      output: {
        // Bibliotecas grandes que mudam pouco ganham arquivos próprios: o hash
        // delas não muda a cada deploy, e quem já abriu o jogo usa o cache.
        // O resto (páginas, componentes) é dividido sozinho pelas rotas lazy.
        codeSplitting: {
          groups: [
            {
              name: 'react',
              test: /node_modules[\\/](?:\.pnpm[\\/][^\\/]+[\\/]node_modules[\\/])?(?:react|react-dom|scheduler|react-router)[\\/]/,
            },
            {
              name: 'supabase',
              test: /node_modules[\\/](?:\.pnpm[\\/][^\\/]+[\\/]node_modules[\\/])?(?:@supabase[\\/]|iceberg-js[\\/])/,
            },
          ],
        },
      },
    },
  },
})
