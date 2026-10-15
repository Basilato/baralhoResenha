import { expect, test, type Page } from '@playwright/test'
import { expectNoHorizontalOverflow, playerPage } from './support.ts'

/** Página do jogador que está na vez (a que mostra "Sua vez!"). */
async function activePage(pages: Page[]) {
  await expect
    .poll(async () => {
      const flags = await Promise.all(
        pages.map(
          async (page) => (await page.getByTestId('turn-status').textContent()) === 'Sua vez!',
        ),
      )
      return flags.filter(Boolean).length
    })
    .toBe(1)
  for (const page of pages) {
    if ((await page.getByTestId('turn-status').textContent()) === 'Sua vez!') return page
  }
  throw new Error('ninguém está na vez')
}

test('turnos passam em ordem, com compra, limite de 7 e histórico', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.setTimeout(90_000)
  const options = { ...contextOptions, ...testInfo.project.use }
  const host = await playerPage(browser, 'teste4', options)
  const second = await playerPage(browser, 'teste5', options)
  const third = await playerPage(browser, 'teste6', options)
  const pages = [host, second, third]

  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  await second.goto(`/entrar/${code}`)
  await third.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  for (const page of pages) await expect(page).toHaveURL(/\/jogo\//)

  // Só quem está na vez vê o botão de encerrar.
  const first = await activePage(pages)
  for (const page of pages) {
    await expect(page.getByRole('button', { name: 'Encerrar turno' })).toHaveCount(
      page === first ? 1 : 0,
    )
  }
  await expect(first.getByTestId('actions-left')).toHaveText('Ações: 0/2')
  await expect(first.getByTestId('event-log')).toContainText('Sua vez: você comprou 2 cartas.')
  await expectNoHorizontalOverflow(first)

  // Clique duplo: a jogada vale uma vez só.
  await first.getByRole('button', { name: 'Encerrar turno' }).dblclick()
  await expect(first.getByTestId('turn-status')).not.toHaveText('Sua vez!')
  const secondTurn = await activePage(pages)
  expect(secondTurn).not.toBe(first)
  await expect(secondTurn.getByTestId('my-hand-count')).toHaveText('7/7')
  // Ninguém pulou a vez: o terceiro ainda está esperando com 5 cartas.
  const waiting = pages.find((page) => page !== first && page !== secondTurn)!
  await expect(waiting.getByTestId('my-hand-count')).toHaveText('5/7')

  await secondTurn.getByRole('button', { name: 'Encerrar turno' }).click()
  await expect(secondTurn.getByTestId('turn-status')).not.toHaveText('Sua vez!')
  const thirdTurn = await activePage(pages)
  expect(thirdTurn).toBe(waiting)
  await thirdTurn.getByRole('button', { name: 'Encerrar turno' }).click()

  // Rodada 2: o primeiro volta com 9 cartas e precisa descartar 2.
  for (const page of pages)
    await expect(page.getByRole('heading', { name: 'Rodada 2 de 10' })).toBeVisible()
  expect(await activePage(pages)).toBe(first)
  await expect(first.getByTestId('my-hand-count')).toHaveText('9/7')
  const discardButton = first.getByRole('button', { name: 'Descartar 2 e encerrar' })
  await expect(discardButton).toBeDisabled()

  const hand = first.getByTestId('my-hand').getByRole('button')
  await hand.nth(0).click()
  await expect(discardButton).toBeDisabled()
  await hand.nth(1).click()
  await expect(discardButton).toBeEnabled()
  await discardButton.click()

  await expect(first.getByTestId('turn-status')).not.toHaveText('Sua vez!')
  await expect(first.getByTestId('my-hand-count')).toHaveText('7/7')
  await expect(second.getByTestId('main-discard-count')).toHaveText('2')
  // Descarte é público e aparece no histórico de todos.
  await expect(second.getByTestId('event-log')).toContainText('encerrou o turno e descartou')

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
