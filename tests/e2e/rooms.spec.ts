import { expect, test } from '@playwright/test'
import { expectNoHorizontalOverflow, playerPage } from './support.ts'

// Vários navegadores por teste: 30 s fica no limite quando a suíte roda em paralelo.
test.describe.configure({ timeout: 60_000 })

// Cópias do baralho principal na versão 7.1 (carta nova muda este número).
const MAIN_DECK = 180
/** Baralho depois de dar 5 cartas a cada um e o lugar 1 comprar as 2 do turno. */
const deckAfterDeal = (players: number) => String(MAIN_DECK - 5 * players - 2)

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
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  expect(code).toMatch(/^[A-Z0-9]{10}$/)

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
  await expectNoHorizontalOverflow(host)
  await expectNoHorizontalOverflow(second)

  await second.getByRole('button', { name: 'Marcar como pronto' }).click()
  await expect(
    host.getByTestId('seat').filter({ hasText: 'Teste Cinco' }).getByText('Pronto'),
  ).toBeVisible()

  await host.getByRole('button', { name: /Começar \(3\/8\)/ }).click()

  for (const page of [host, second, third]) {
    await expect(page).toHaveURL(/\/jogo\//)
    await expect(page.getByTestId('table-player')).toHaveCount(3)
    // Cada um vê as próprias cartas; dos outros, só a contagem. O lugar 1 já
    // comprou as 2 do primeiro turno (5 + 2).
    const myTurn = (await page.getByTestId('turn-status').textContent()) === 'Sua vez!'
    const expected = myTurn ? 7 : 5
    await expect(page.getByTestId('my-hand').getByRole('button')).toHaveCount(expected)
    await expect(page.getByTestId('my-hand-count')).toHaveText(`${expected}/7`)
    await expect(page.getByTestId('main-deck-count')).toHaveText(deckAfterDeal(3))
    await expect(page.getByTestId('ghost-deck-count')).toHaveText('20')
    await expect(page.getByTestId('cards-in-hand').filter({ hasText: '5' })).toHaveCount(2)
    await expect(page.getByTestId('cards-in-hand').filter({ hasText: '7' })).toHaveCount(1)
    await expect(page.getByText('16/16 PV')).toHaveCount(3)
    await expectNoHorizontalOverflow(page)
  }

  // Carta ampliada com o texto da regra.
  await host.getByTestId('my-hand').getByRole('button').first().click()
  await expect(host.getByRole('dialog').getByRole('article')).toBeInViewport({ ratio: 1 })
  await host.keyboard.press('Escape')

  // F5 na mesa mantém a partida e a mão.
  const handBefore = await third.getByTestId('my-hand').getByRole('button').count()
  await third.reload()
  await expect(third.getByTestId('table-player')).toHaveCount(3)
  await expect(third.getByTestId('my-hand').getByRole('button')).toHaveCount(handBefore)

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
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!

  await guest.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(2)

  await host.getByRole('button', { name: 'Remover Teste Oito' }).click()
  await host.getByRole('button', { name: 'Remover', exact: true }).click()

  await expect(host.getByTestId('seat')).toHaveCount(1)
  await expect(guest).toHaveURL(/\/lobby$/)
  await expect(guest.getByText('Você não está mais nesta sala.')).toBeVisible()

  // E5: removido não volta só com o código…
  await guest.goto(`/entrar/${code}`)
  await expect(guest.getByText('O host removeu você desta sala.', { exact: false })).toBeVisible()

  // …até o host liberar.
  await host.getByRole('button', { name: 'Permitir volta' }).click()
  await expect(host.getByRole('button', { name: 'Permitir volta' })).toHaveCount(0)
  await guest.goto(`/entrar/${code}`)
  await expect(guest).toHaveURL(host.url())
  await expect(host.getByTestId('seat')).toHaveCount(2)

  // E1: código novo invalida o anterior na hora.
  await host.getByRole('button', { name: 'Gerar código novo' }).click()
  await host.getByRole('button', { name: 'Gerar novo', exact: true }).click()
  await expect(host.getByTestId('room-code')).not.toHaveAttribute('data-code', code)
  const newCode = (await host.getByTestId('room-code').getAttribute('data-code'))!
  expect(newCode).toMatch(/^[A-Z0-9]{10}$/)
  // Membro também vê o código novo sem recarregar.
  await expect(guest.getByTestId('room-code')).toHaveAttribute('data-code', newCode)

  const outsider = await playerPage(browser, 'teste9', options)
  await outsider.goto(`/entrar/${code}`)
  await expect(outsider.getByText('Código não encontrado', { exact: false })).toBeVisible()

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

  await page.getByLabel('Código da sala').fill('ZZZZZ ZZZZZ')
  await page.getByRole('button', { name: 'Entrar', exact: true }).click()
  await expect(page.getByText('Código não encontrado')).toBeVisible()
})

test('mesa cheia: oito pessoas veem tudo ao vivo e a nona é recusada', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop', 'pesado: roda só no desktop')
  test.setTimeout(90_000)
  const options = { ...contextOptions, ...testInfo.project.use }

  const host = await playerPage(browser, 'teste1', options)
  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!

  const guests = await Promise.all(
    ['teste2', 'teste3', 'teste4', 'teste5', 'teste6', 'teste7', 'teste8'].map(async (name) => {
      const page = await playerPage(browser, name, options)
      await page.goto(`/entrar/${code}`)
      await expect(page).toHaveURL(/\/sala\//)
      return page
    }),
  )

  await expect(host.getByTestId('seat')).toHaveCount(8)
  await expect(guests[0]!.getByTestId('seat')).toHaveCount(8)
  await expect(host.getByText('8 de 8 lugares ocupados.')).toBeVisible()

  const ninth = await playerPage(browser, 'teste9', options)
  await ninth.goto(`/entrar/${code}`)
  await expect(ninth.getByText('A sala já está cheia (8 pessoas).')).toBeVisible()
  await expect(host.getByTestId('seat')).toHaveCount(8)

  await host.getByRole('button', { name: /Começar \(8\/8\)/ }).click()
  for (const page of [host, ...guests]) {
    await expect(page).toHaveURL(/\/jogo\//)
    await expect(page.getByTestId('table-player')).toHaveCount(8)
    await expect(page.getByTestId('main-deck-count')).toHaveText(deckAfterDeal(8))
  }

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
  await expect(guests[6]!.getByText('Essa resenha acabou')).toBeVisible()
})
