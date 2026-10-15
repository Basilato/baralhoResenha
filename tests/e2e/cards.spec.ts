import { expect, test, type Page } from '@playwright/test'
import { activePage, gameIdFrom, giveCard, playerPage, resetActions, setHp } from './support.ts'

const USERS = { teste1: 'Teste Um', teste2: 'Teste Dois', teste3: 'Teste Três' } as const
type Username = keyof typeof USERS

async function handCount(page: Page) {
  const text = (await page.getByTestId('my-hand-count').textContent())!
  return Number(text.split('/')[0])
}

test('sabotagem com escolha privada, caos simultâneo e recuperação', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.setTimeout(120_000)
  const options = { ...contextOptions, ...testInfo.project.use }
  const byUser = new Map<Username, Page>()
  for (const username of Object.keys(USERS) as Username[]) {
    byUser.set(username, await playerPage(browser, username, options))
  }
  const pages = [...byUser.values()]
  const host = byUser.get('teste1')!

  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  await byUser.get('teste2')!.goto(`/entrar/${code}`)
  await byUser.get('teste3')!.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  for (const page of pages) await expect(page).toHaveURL(/\/jogo\//)

  const gameId = gameIdFrom(host)
  const actor = await activePage(pages)
  const [actorUser] = [...byUser].find(([, page]) => page === actor)!
  const others = [...byUser].filter(([, page]) => page !== actor)
  const [targetUser, target] = others[0]!
  const [, bystander] = others[1]!

  // 1. Terapia de Boteco: só quem jogou vê a mão do alvo.
  giveCard(gameId, actorUser, 'SAB-02')
  for (const page of pages) await page.reload()
  const targetHand = await handCount(target)

  await actor.getByRole('button', { name: 'Ver Terapia de Boteco' }).first().click()
  await actor
    .getByRole('dialog')
    .getByRole('button', { name: new RegExp(USERS[targetUser]) })
    .click()
  await actor.getByRole('button', { name: 'Jogar Terapia de Boteco' }).click()

  const targetDialog = target.getByTestId('reaction-dialog')
  await expect(targetDialog).toContainText('Só Evento Raro cancela')
  await targetDialog.getByRole('button', { name: 'Aceitar' }).click()

  const pick = actor.getByTestId('reaction-dialog')
  await expect(pick).toContainText(`Mão de ${USERS[targetUser]}`)
  await expect(pick.getByTestId('choice-options').getByRole('button')).toHaveCount(targetHand)
  await expect(bystander.getByTestId('reaction-dialog')).toHaveCount(0)
  await expect(bystander.getByTestId('pending-banner')).toContainText('Aguardando escolha de')
  await pick.getByTestId('choice-options').getByRole('button').first().click()
  await pick.getByRole('button', { name: /Descartar esta/ }).click()

  await expect(target.getByTestId('my-hand-count')).toHaveText(`${targetHand - 1}/7`)
  await expect(bystander.getByTestId('event-log')).toContainText(`${USERS[targetUser]} descartou`)

  // 2. Bucetada: todos escolhem ao mesmo tempo; nada sai antes de todos.
  resetActions(gameId)
  giveCard(gameId, actorUser, 'CAO-02')
  for (const page of pages) await page.reload()
  const before = new Map<Page, number>()
  for (const page of pages) before.set(page, await handCount(page))

  await actor.getByRole('button', { name: 'Ver Bucetada' }).first().click()
  await actor.getByRole('button', { name: 'Jogar Bucetada' }).click()

  for (const page of pages) {
    const dialog = page.getByTestId('reaction-dialog')
    await expect(dialog).toContainText('descarte 1 carta')
    await dialog.getByTestId('choice-options').getByRole('button').first().click()
    await dialog.getByRole('button', { name: /Descartar esta/ }).click()
    await expect(dialog).toHaveCount(0)
  }
  for (const page of pages) {
    // O autor também perdeu a própria Bucetada jogada.
    const expected = before.get(page)! - 1 - (page === actor ? 1 : 0)
    await expect(page.getByTestId('my-hand-count')).toHaveText(`${expected}/7`)
  }

  // 3. Recuperação: sem alvo, efeito na hora.
  resetActions(gameId)
  setHp(gameId, actorUser, 10)
  giveCard(gameId, actorUser, 'REC-01')
  for (const page of pages) await page.reload()
  await actor.getByRole('button', { name: 'Ver After do After' }).first().click()
  await actor.getByRole('button', { name: 'Jogar After do After' }).click()
  await expect(
    bystander.getByTestId('table-player').filter({ hasText: USERS[actorUser] }),
  ).toContainText('14/16 PV')
  await expect(bystander.getByTestId('event-log')).toContainText('recuperou PV (ficou com 14)')

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
