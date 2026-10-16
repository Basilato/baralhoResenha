import { defineConfig, devices } from '@playwright/test'

// Pré-requisito: Supabase local rodando (`pnpm db:start`) com o seed aplicado.
export default defineConfig({
  testDir: './tests/e2e',
  globalSetup: './tests/e2e/global-setup.ts',
  fullyParallel: true,
  retries: process.env.CI ? 2 : 0,
  // Até 9 navegadores por teste em paralelo: atualizações em tempo real podem
  // passar dos 5 s padrão quando a máquina está cheia.
  expect: { timeout: 10_000 },
  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
    // O tutorial abre sozinho no primeiro acesso; os testes começam com ele já
    // visto (tutorial.spec.ts testa o primeiro acesso de verdade).
    storageState: {
      cookies: [],
      origins: [
        {
          origin: 'http://localhost:5173',
          localStorage: [{ name: 'resenha:preferences', value: '{"tutorialSeen":true}' }],
        },
      ],
    },
  },
  projects: [
    { name: 'desktop', use: { ...devices['Desktop Chrome'] } },
    { name: 'celular', use: { ...devices['Pixel 7'] } },
  ],
  webServer: {
    command: 'pnpm dev --port 5173 --strictPort',
    url: 'http://localhost:5173',
    reuseExistingServer: !process.env.CI,
  },
})
