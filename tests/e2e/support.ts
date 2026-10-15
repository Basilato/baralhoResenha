import { expect, type Browser, type Page } from '@playwright/test'

export const PASSWORD = 'resenha123'

export async function login(page: Page, username: string) {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill(username)
  await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page).toHaveURL(/\/lobby$/)
}

/** Cada jogador num contexto próprio = navegador/sessão separados. */
export async function playerPage(browser: Browser, username: string, options = {}) {
  const context = await browser.newContext(options)
  const page = await context.newPage()
  await login(page, username)
  return page
}

/** Nenhuma tela pode rolar para o lado no celular. */
export async function expectNoHorizontalOverflow(page: Page) {
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  )
  expect(overflow, 'a página está mais larga que a tela').toBeLessThanOrEqual(0)
}
