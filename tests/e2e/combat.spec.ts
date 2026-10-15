import { expect, test, type Page } from '@playwright/test'
import {
  activePage,
  expectNoHorizontalOverflow,
  gameIdFrom,
  giveCard,
  playerPage,
  setHp,
} from './support.ts'

const USERS = { teste7: 'Teste Sete', teste8: 'Teste Oito', teste9: 'Teste Nove' } as const
type Username = keyof typeof USERS

test('ataque, defesa e golpe fatal entre três navegadores', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.setTimeout(90_000)
  const options = { ...contextOptions, ...testInfo.project.use }
  const byUser = new Map<Username, Page>()
  for (const username of Object.keys(USERS) as Username[]) {
    byUser.set(username, await playerPage(browser, username, options))
  }
  const pages = [...byUser.values()]
  const host = byUser.get('teste7')!

  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  await byUser.get('teste8')!.goto(`/entrar/${code}`)
  await byUser.get('teste9')!.goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  for (const page of pages) await expect(page).toHaveURL(/\/jogo\//)

  const gameId = gameIdFrom(host)
  const attacker = await activePage(pages)
  const [attackerUser] = [...byUser].find(([, page]) => page === attacker)!
  const others = [...byUser].filter(([, page]) => page !== attacker)
  const [targetUser, target] = others[0]!
  const [, bystander] = others[1]!

  // Cenário: atacante com Falou Merda, alvo com Inimiga do Banho.
  giveCard(gameId, attackerUser, 'ATK-01')
  giveCard(gameId, targetUser, 'DEF-02')
  for (const page of pages) await page.reload()

  await attacker.getByRole('button', { name: 'Ver Falou Merda' }).first().click()
  await attacker.getByRole('button', { name: new RegExp(USERS[targetUser]) }).click()
  await attacker.getByRole('button', { name: 'Jogar Falou Merda' }).click()

  // Todos veem a jogada pendente; só o alvo decide.
  await expect(bystander.getByTestId('pending-banner')).toContainText(
    `Aguardando resposta de ${USERS[targetUser]}`,
  )
  await expect(bystander.getByTestId('reaction-dialog')).toHaveCount(0)
  const dialog = target.getByTestId('reaction-dialog')
  await expect(dialog).toContainText('atacou você!')
  await expect(dialog).toContainText('3 de dano em você')
  await expectNoHorizontalOverflow(target)
  await dialog.getByRole('button', { name: 'Usar Inimiga do Banho' }).first().click()

  await expect(dialog).toHaveCount(0)
  for (const page of pages) {
    await expect(page.getByTestId('event-log')).toContainText('reagiu com Inimiga do Banho')
    await expect(page.getByTestId('pending-banner')).toHaveCount(0)
  }
  await expect(
    bystander.getByTestId('table-player').filter({ hasText: USERS[targetUser] }),
  ).toContainText('16/16 PV')
  await expect(attacker.getByTestId('actions-left')).toHaveText('Ações: 1/2')

  // Golpe fatal: o alvo aceita e vira fantasma para todos.
  setHp(gameId, targetUser, 3)
  giveCard(gameId, attackerUser, 'ATK-02')
  for (const page of pages) await page.reload()

  await attacker.getByRole('button', { name: 'Ver Não Vou Levar Numa Boa' }).first().click()
  await attacker.getByRole('button', { name: new RegExp(USERS[targetUser]) }).click()
  await attacker.getByRole('button', { name: 'Jogar Não Vou Levar Numa Boa' }).click()

  await expect(dialog).toContainText('Esse golpe é fatal.')
  await dialog.getByRole('button', { name: 'Aceitar 3 de dano' }).click()

  for (const page of pages) {
    await expect(
      page.getByTestId('table-player').filter({ hasText: USERS[targetUser] }),
    ).toContainText('Fantasma')
  }
  await expect(bystander.getByTestId('event-log')).toContainText(
    `${USERS[targetUser]} foi eliminado por ${USERS[attackerUser]} e virou fantasma.`,
  )
  await expect(target.getByRole('heading', { name: /Suas cartas do Além/ })).toBeVisible()

  // Sem ações sobrando, a carta explica por que não dá para jogar.
  giveCard(gameId, attackerUser, 'ATK-01')
  await attacker.reload()
  await expect(attacker.getByTestId('actions-left')).toHaveText('Ações: 2/2')
  await attacker.getByRole('button', { name: 'Ver Falou Merda' }).first().click()
  await expect(attacker.getByRole('dialog')).toContainText('Você já usou as 2 ações deste turno.')
  await attacker.keyboard.press('Escape')

  await host.getByRole('button', { name: 'Encerrar partida' }).click()
  await host.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
