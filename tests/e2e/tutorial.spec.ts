import { expect, test } from '@playwright/test'
import { login } from './support.ts'

test.describe('primeiro acesso', () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test('tutorial de 3 passos abre sozinho uma vez e volta pelo menu', async ({ page }) => {
    await page.goto('/login')
    await page.getByLabel('Usuário').fill('teste6')
    await page.getByLabel('Senha', { exact: true }).fill('resenha123')
    await page.getByRole('button', { name: 'Entrar' }).click()

    const tutorial = page.getByTestId('tutorial')
    await expect(tutorial).toContainText('Passo 1 de 3')
    await expect(tutorial).toContainText('Sobreviva à resenha')
    await tutorial.getByRole('button', { name: 'Próximo' }).click()
    await expect(tutorial).toContainText('Na sua vez')
    await tutorial.getByRole('button', { name: 'Voltar' }).click()
    await expect(tutorial).toContainText('Passo 1 de 3')
    await tutorial.getByRole('button', { name: 'Próximo' }).click()
    await tutorial.getByRole('button', { name: 'Próximo' }).click()
    await expect(tutorial).toContainText('Caiu? Vira fantasma')
    await expect(tutorial).toBeInViewport({ ratio: 1 })
    await tutorial.getByRole('button', { name: 'Bora jogar!' }).click()
    await expect(tutorial).toHaveCount(0)

    await page.reload()
    await expect(page.getByRole('heading', { name: /E aí/ })).toBeVisible()
    await expect(page.getByTestId('tutorial')).toHaveCount(0)

    await page.getByRole('button', { name: /Teste Seis/ }).click()
    await page.getByRole('menuitem', { name: 'Como jogar' }).click()
    await expect(page.getByTestId('tutorial')).toContainText('Passo 1 de 3')
    await page.getByRole('button', { name: 'Pular' }).click()
    await expect(page.getByTestId('tutorial')).toHaveCount(0)
  })
})

test('regras rápidas abrem na mesa sem sair da partida', async ({ browser }, testInfo) => {
  test.setTimeout(60_000)
  const options = testInfo.project.use
  const pages = await Promise.all(
    ['teste4', 'teste5', 'teste6'].map(async (username) => {
      const context = await browser.newContext(options)
      const page = await context.newPage()
      await login(page, username)
      return page
    }),
  )
  const host = pages[0]!
  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  for (const page of pages.slice(1)) await page.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  await expect(host).toHaveURL(/\/jogo\//)

  await host.getByRole('button', { name: 'Regras rápidas' }).click()
  const dialog = host.getByRole('dialog')
  await expect(dialog).toContainText('Limite de mão')
  await expect(dialog).toContainText('Sabotagem')
  await expect(dialog.getByRole('link', { name: 'Ver todas as cartas' })).toBeVisible()
  await host.keyboard.press('Escape')
  await expect(host).toHaveURL(/\/jogo\//)

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
