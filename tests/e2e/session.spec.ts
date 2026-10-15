import { execSync } from 'node:child_process'
import { expect, test } from '@playwright/test'
import { login, PASSWORD } from './support.ts'

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
  // Muda o estado da conta teste10: roda uma vez só, fora do projeto celular.
  test.skip(({ isMobile }) => isMobile, 'altera estado compartilhado')

  test.afterEach(() => {
    execSync('pnpm -s users enable teste10', { stdio: 'ignore' })
  })

  test('derruba a sessão aberta e bloqueia novo login', async ({ page }) => {
    await login(page, 'teste10')

    execSync('pnpm -s users disable teste10', { stdio: 'ignore' })

    await page.reload()
    await expect(page).toHaveURL(/\/login$/)
    await expect(page.getByText('Esta conta está desativada')).toBeVisible()

    await page.getByLabel('Usuário').fill('teste10')
    await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
    await page.getByRole('button', { name: 'Entrar' }).click()
    await expect(page.getByRole('alert')).toContainText('Esta conta está bloqueada')
  })
})
