import { expect, test, type Page } from '@playwright/test'
import { activePage, gameIdFrom, giveCard, playerPage } from './support.ts'

const USERS = { teste4: 'Teste Quatro', teste5: 'Teste Cinco', teste6: 'Teste Seis' } as const
type Username = keyof typeof USERS

async function startTable(
  browser: Parameters<typeof playerPage>[0],
  options: Parameters<typeof playerPage>[2],
) {
  const byUser = new Map<Username, Page>()
  for (const username of Object.keys(USERS) as Username[]) {
    byUser.set(username, await playerPage(browser, username, options))
  }
  const pages = [...byUser.values()]
  const host = byUser.get('teste4')!
  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  await byUser.get('teste5')!.goto(`/entrar/${code}`)
  await byUser.get('teste6')!.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  for (const page of pages) await expect(page).toHaveURL(/\/jogo\//)

  const gameId = gameIdFrom(host)
  const attacker = await activePage(pages)
  const [attackerUser] = [...byUser].find(([, page]) => page === attacker)!
  const others = [...byUser].filter(([, page]) => page !== attacker)
  return { byUser, pages, host, gameId, attacker, attackerUser, others }
}

test('recarregar no meio de uma reação e voltar da queda de conexão', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.setTimeout(90_000)
  const table = await startTable(browser, { ...contextOptions, ...testInfo.project.use })
  const { attacker, attackerUser, gameId, others } = table
  const [targetUser, target] = others[0]!
  const [, bystander] = others[1]!

  giveCard(gameId, attackerUser, 'ATK-01')
  for (const page of table.pages) await page.reload()

  await attacker.getByRole('button', { name: 'Ver Falou Merda' }).first().click()
  await attacker.getByRole('button', { name: new RegExp(USERS[targetUser]) }).click()
  await attacker.getByRole('button', { name: 'Jogar Falou Merda' }).click()
  await expect(target.getByTestId('reaction-dialog')).toBeVisible()

  // O alvo recarrega: a decisão continua esperando por ele.
  await target.reload()
  await expect(target.getByTestId('reaction-dialog')).toContainText('3 de dano em você')
  await expect(bystander.getByTestId('pending-banner')).toContainText(USERS[targetUser])

  // Quem atacou cai da rede enquanto o alvo responde…
  await attacker.context().setOffline(true)
  await target
    .getByTestId('reaction-dialog')
    .getByRole('button', { name: /Aceitar 3 de dano/ })
    .click()
  await expect(bystander.getByTestId('event-log')).toContainText('sofreu 3')

  // …e, ao voltar, a mesa se acerta sozinha, sem recarregar.
  await attacker.context().setOffline(false)
  await expect(attacker.getByTestId('pending-banner')).toHaveCount(0, { timeout: 20_000 })
  await expect(
    attacker.getByTestId('table-player').filter({ hasText: USERS[targetUser] }),
  ).toContainText(/13\/16 PV/, { timeout: 20_000 })
  await expect(attacker.getByTestId('actions-left')).toHaveText('Ações: 1/2')

  await table.host.getByRole('button', { name: 'Encerrar partida' }).click()
  await table.host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})

test('troca de mão inteira sobrevive a recarregar', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.setTimeout(90_000)
  const table = await startTable(browser, { ...contextOptions, ...testInfo.project.use })
  const { attacker, attackerUser, gameId, others } = table
  const [targetUser, target] = others[0]!

  giveCard(gameId, attackerUser, 'REV-02')
  for (const page of table.pages) await page.reload()

  const handIds = async (page: Page) => {
    const cards = page.getByTestId('my-hand').locator('[data-instance]')
    await expect(cards.first()).toBeVisible()
    return (await cards.evaluateAll((items) =>
      items.map((item) => item.getAttribute('data-instance')),
    )) as string[]
  }

  const attackerBefore = await handIds(attacker)
  const targetBefore = await handIds(target)

  await attacker.getByRole('button', { name: 'Ver Lucboy & Laragirl' }).first().click()
  await attacker.getByRole('button', { name: new RegExp(USERS[targetUser]) }).click()
  await attacker.getByRole('button', { name: 'Jogar Lucboy & Laragirl' }).click()
  await expect(attacker.getByTestId('event-log')).toContainText('trocou a mão inteira')

  // Depois de recarregar, cada um tem exatamente a mão do outro (sem a REV-02 jogada).
  await attacker.reload()
  await target.reload()
  const attackerAfter = await handIds(attacker)
  const targetAfter = await handIds(target)
  expect([...attackerAfter].sort()).toEqual([...targetBefore].sort())
  expect(targetAfter).toHaveLength(attackerBefore.length - 1)
  expect(attackerBefore).toEqual(expect.arrayContaining(targetAfter))

  // E a ordem não muda com novas recargas (ids de instância estáveis).
  await attacker.reload()
  expect(await handIds(attacker)).toEqual(attackerAfter)

  await table.host.getByRole('button', { name: 'Encerrar partida' }).click()
  await table.host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
