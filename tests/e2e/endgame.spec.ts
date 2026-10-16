import { expect, test, type Page } from '@playwright/test'
import {
  activePage,
  backdateLastSeen,
  gameIdFrom,
  giveCard,
  makeGhost,
  playerPage,
  resetActions,
  setHp,
  setRevivalUsed,
  userAtSeat,
} from './support.ts'

const NAMES: Record<string, string> = {
  teste4: 'Teste Quatro',
  teste5: 'Teste Cinco',
  teste6: 'Teste Seis',
}
const HOST = 'teste4'

test('fantasma ressuscita, ausente é removido e o último vivo vence com revanche', async ({
  browser,
  contextOptions,
}, testInfo) => {
  test.skip(testInfo.project.name !== 'desktop', 'fluxo longo: roda só no desktop')
  test.setTimeout(120_000)
  const options = { ...contextOptions, ...testInfo.project.use }
  const pages = new Map<string, Page>()
  for (const username of Object.keys(NAMES)) {
    pages.set(username, await playerPage(browser, username, options))
  }
  const pageOf = (username: string) => pages.get(username)!
  const name = (username: string) => NAMES[username]!

  const host = pageOf(HOST)
  await host.getByRole('button', { name: 'Criar resenha' }).click()
  const code = (await host.getByTestId('room-code').getAttribute('data-code'))!
  await pageOf('teste5').goto(`/entrar/${code}`)
  await pageOf('teste6').goto(`/entrar/${code}`)
  await expect(host.getByTestId('seat')).toHaveCount(3)
  await host.getByRole('button', { name: /Começar/ }).click()
  for (const page of pages.values()) await expect(page).toHaveURL(/\/jogo\//)
  const gameId = gameIdFrom(host)

  // 1. Ressurreição: o lugar 2 vira fantasma com 2 fichas; na vez dele ganha a
  //    3ª e escolhe ressuscitar.
  const first = await activePage([...pages.values()])
  const ghostUser = userAtSeat(gameId, 2)
  makeGhost(gameId, ghostUser, 2)
  for (const page of pages.values()) await page.reload()

  await first.getByRole('button', { name: 'Encerrar turno' }).click()
  const ghost = pageOf(ghostUser)
  await expect(ghost.getByTestId('revive-choice')).toBeVisible()
  await expect(ghost.getByRole('button', { name: 'Encerrar turno' })).toBeDisabled()
  await ghost.getByRole('button', { name: 'Ressuscitar' }).click()

  await expect(ghost.getByRole('heading', { name: /Sua mão/ })).toBeVisible()
  await expect(ghost.getByTestId('my-hand-count')).toHaveText('3/7')
  await expect(first.getByTestId('event-log')).toContainText(
    `${name(ghostUser)} ressuscitou com 6 PV e 3 cartas!`,
  )
  await expect(
    first.getByTestId('table-player').filter({ hasText: name(ghostUser) }),
  ).toContainText('6/16 PV')

  // 2. Ausência: um jogador (que não é o host) fecha o navegador; depois de
  //    2 minutos sem sinal, o host remove.
  const absentUser = Object.keys(NAMES).find((u) => u !== HOST)!
  await pageOf(absentUser).context().close()
  pages.delete(absentUser)
  backdateLastSeen(gameId, absentUser, 5)
  await host.reload()
  const panel = host.getByTestId('table-player').filter({ hasText: name(absentUser) })
  await expect(panel.getByTestId('away')).toContainText('Sem conexão há 5 min')
  await panel.getByRole('button', { name: 'Remover (ausente)' }).click()
  await host.getByRole('button', { name: 'Remover', exact: true }).click()
  await expect(panel).toContainText('Desistiu')
  await expect(host.getByTestId('event-log')).toContainText('foi removido por ausência')

  // 3. Último vivo: entre os dois que restam, quem está na vez dá o golpe
  //    fatal e ninguém mais pode voltar.
  const remaining = [...pages.keys()]
  const attackerPage = await activePage(remaining.map(pageOf))
  const attackerUser = remaining.find((u) => pageOf(u) === attackerPage)!
  const victimUser = remaining.find((u) => u !== attackerUser)!
  const victim = pageOf(victimUser)
  setHp(gameId, victimUser, 3)
  setRevivalUsed(gameId, victimUser)
  giveCard(gameId, attackerUser, 'ATK-01')
  // Com uma defesa na mão, a vítima decide (não aceita sozinha).
  giveCard(gameId, victimUser, 'DEF-01')
  resetActions(gameId)
  for (const page of [attackerPage, victim]) await page.reload()

  await attackerPage.getByRole('button', { name: 'Ver Falou Merda' }).first().click()
  await attackerPage
    .getByRole('dialog')
    .getByRole('button', { name: new RegExp(name(victimUser)) })
    .click()
  await attackerPage.getByRole('button', { name: 'Jogar Falou Merda' }).click()
  await victim
    .getByTestId('reaction-dialog')
    .getByRole('button', { name: /Aceitar/ })
    .click()

  for (const page of [attackerPage, victim]) {
    await expect(page.getByTestId('result')).toContainText('Último vivo de pé')
    await expect(page.getByTestId('winners')).toContainText(name(attackerUser))
  }
  await expect(attackerPage.getByTestId('result')).toContainText('Você venceu!')

  // 4. Revanche: quem perdeu cria; o vencedor entra direto, sem código.
  await victim.getByRole('button', { name: 'Revanche' }).click()
  await expect(victim).toHaveURL(/\/sala\//)
  await attackerPage.getByRole('button', { name: 'Entrar na revanche' }).click()
  await expect(attackerPage).toHaveURL(victim.url())
  await expect(victim.getByTestId('seat')).toHaveCount(2)

  await victim.getByRole('button', { name: 'Encerrar sala' }).click()
  await victim.getByRole('button', { name: 'Encerrar', exact: true }).click()
})
