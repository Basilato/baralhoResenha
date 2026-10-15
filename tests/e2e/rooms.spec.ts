import { expect, test } from '@playwright/test'
import { playerPage } from './support.ts'

test('três pessoas entram, veem tudo em tempo real e o host inicia', async ({
  browser,
  contextOptions,
}, testInfo) => {
  const options = { ...contextOptions, ...testInfo.project.use }
  const host = await playerPage(browser, 'teste4', options)
  const second = await playerPage(browser, 'teste5', options)
  const third = await playerPage(browser, 'teste6', options)

  await host.getByRole('button', { name: 'Criar resenha' }).click()
  await expect(host).toHaveURL(/\/sala\//)
  const code = (await host.getByTestId('room-code').textContent())!.trim()
  expect(code).toMatch(/^[A-Z0-9]{6}$/)

  // Com menos de 3, o host não consegue começar.
  await expect(host.getByRole('button', { name: /Começar/ })).toBeDisabled()

  // Entra digitando o código (minúsculo) no lobby…
  await second.getByLabel('Código da sala').fill(code.toLowerCase())
  await second.getByRole('button', { name: 'Entrar', exact: true }).click()
  await expect(second).toHaveURL(host.url())

  // …e pelo link de convite.
  await third.goto(`/entrar/${code}`)
  await expect(third).toHaveURL(host.url())

  // O host vê os dois chegarem sem recarregar.
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await expect(host.getByText('Teste Seis')).toBeVisible()

  await second.getByRole('button', { name: 'Marcar como pronto' }).click()
  await expect(
    host.getByTestId('seat').filter({ hasText: 'Teste Cinco' }).getByText('Pronto'),
  ).toBeVisible()

  await host.getByRole('button', { name: /Começar \(3\/8\)/ }).click()

  for (const page of [host, second, third]) {
    await expect(page).toHaveURL(/\/jogo\//)
    await expect(page.getByTestId('table-player')).toHaveCount(3)
  }

  // F5 na mesa mantém a partida.
  await third.reload()
  await expect(third.getByTestId('table-player')).toHaveCount(3)

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
  await expect(host).toHaveURL(/\/lobby$/)
  await expect(second.getByText('Essa resenha acabou')).toBeVisible()
  await expect(third.getByText('Essa resenha acabou')).toBeVisible()
})

test('host remove um jogador e ele volta para o lobby', async ({
  browser,
  contextOptions,
}, testInfo) => {
  const options = { ...contextOptions, ...testInfo.project.use }
  const host = await playerPage(browser, 'teste7', options)
  const guest = await playerPage(browser, 'teste8', options)

  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').textContent())!.trim()

  await guest.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(2)

  await host.getByRole('button', { name: 'Remover Teste Oito' }).click()
  await host.getByRole('button', { name: 'Remover', exact: true }).click()

  await expect(host.getByTestId('seat')).toHaveCount(1)
  await expect(guest).toHaveURL(/\/lobby$/)
  await expect(guest.getByText('Você não está mais nesta sala.')).toBeVisible()

  await host.getByRole('button', { name: 'Encerrar sala' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
  await expect(host).toHaveURL(/\/lobby$/)
})

test('código errado mostra erro no lobby', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Usuário').fill('teste9')
  await page.getByLabel('Senha', { exact: true }).fill('resenha123')
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page).toHaveURL(/\/lobby$/)

  await page.getByLabel('Código da sala').fill('ZZZZZZ')
  await page.getByRole('button', { name: 'Entrar', exact: true }).click()
  await expect(page.getByText('Código não encontrado')).toBeVisible()
})
