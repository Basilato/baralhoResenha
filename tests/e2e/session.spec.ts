import { execSync } from 'node:child_process'
import { expect, test, type Page } from '@playwright/test'

const PASSWORD = 'resenha123'

async function login(page: Page, username: string) {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill(username)
  await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page).toHaveURL(/\/lobby$/)
}

test('sessão expirada que não renova volta para o login', async ({ page }) => {
  await login(page, 'teste1')

  // Simula token vencido com refresh token revogado.
  await page.evaluate(() => {
    const key = Object.keys(localStorage).find((k) => /^sb-.*-auth-token$/.test(k))
    if (!key) throw new Error('sessão não encontrada no localStorage')
    const session = JSON.parse(localStorage.getItem(key)!)
    session.expires_at = Math.floor(Date.now() / 1000) - 60
    session.refresh_token = 'revogado'
    localStorage.setItem(key, JSON.stringify(session))
  })

  await page.reload()
  await expect(page).toHaveURL(/\/login$/)
})

test.describe('conta desativada pelo administrador', () => {
  // Muda estado global da conta teste3: roda uma vez só, fora do projeto celular.
  test.skip(({ isMobile }) => isMobile, 'altera estado compartilhado')

  test.afterEach(() => {
    execSync('pnpm -s users enable teste3', { stdio: 'ignore' })
  })

  test('derruba a sessão aberta e bloqueia novo login', async ({ page }) => {
    await login(page, 'teste3')

    execSync('pnpm -s users disable teste3', { stdio: 'ignore' })

    await page.reload()
    await expect(page).toHaveURL(/\/login$/)
    await expect(page.getByText('Esta conta está desativada')).toBeVisible()

    await page.getByLabel('Usuário').fill('teste3')
    await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
    await page.getByRole('button', { name: 'Entrar' }).click()
    await expect(page.getByRole('alert')).toContainText('Esta conta está bloqueada')
  })
})
