import { expect, test } from '@playwright/test'

const PASSWORD = 'resenha123'

test('rota protegida manda para o login', async ({ page }) => {
  await page.goto('/lobby')
  await expect(page).toHaveURL(/\/login$/)
})

test('senha errada mostra erro amigável', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill('teste1')
  await page.getByLabel('Senha', { exact: true }).fill('senha-errada')
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page.getByRole('alert')).toContainText('Usuário ou senha incorretos.')
})

test('usuário inexistente mostra o mesmo erro', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill('ninguem')
  await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page.getByRole('alert')).toContainText('Usuário ou senha incorretos.')
})

test('login, F5 mantém a sessão e logout volta ao login', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill(' Teste1 ')
  await page.getByLabel('Senha', { exact: true }).fill(PASSWORD)
  await page.getByRole('button', { name: 'Entrar' }).click()

  await expect(page).toHaveURL(/\/lobby$/)
  await expect(page.getByRole('heading', { name: 'E aí, Teste Um!' })).toBeVisible()

  await page.reload()
  await expect(page.getByRole('heading', { name: 'E aí, Teste Um!' })).toBeVisible()

  await page.getByRole('button', { name: /Teste Um/ }).click()
  await page.getByRole('menuitem', { name: 'Sair' }).click()
  await expect(page).toHaveURL(/\/login$/)
})

test('logout numa aba encerra a sessão na outra', async ({ context }) => {
  const first = await context.newPage()
  await first.goto('/login')
  await first.getByLabel('Usuário').fill('teste2')
  await first.getByLabel('Senha', { exact: true }).fill(PASSWORD)
  await first.getByRole('button', { name: 'Entrar' }).click()
  await expect(first).toHaveURL(/\/lobby$/)

  const second = await context.newPage()
  await second.goto('/lobby')
  await expect(second.getByRole('heading', { name: 'E aí, Teste Dois!' })).toBeVisible()

  await first.getByRole('button', { name: /Teste Dois/ }).click()
  await first.getByRole('menuitem', { name: 'Sair' }).click()

  await expect(second).toHaveURL(/\/login$/)
})
