import { execSync } from 'node:child_process'
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

/** Página do jogador que está na vez (a que mostra "Sua vez!"). */
export async function activePage(pages: Page[]) {
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

export function gameIdFrom(page: Page) {
  return new URL(page.url()).pathname.split('/').pop()!
}

// --- Preparação de cenários direto no banco local (só em testes) -------------

export function sql(query: string): string {
  return execSync(
    'docker exec -i supabase_db_baralho-da-resenha psql -U postgres -tA -v ON_ERROR_STOP=1',
    {
      input: query,
      encoding: 'utf8',
    },
  ).trim()
}

const playerOf = (gameId: string, username: string) =>
  `(select gp.id from app_private.game_players gp join public.profiles p on p.id = gp.user_id
    where gp.game_id = '${gameId}' and p.username = '${username}')`

/** Põe uma cópia da carta na mão do jogador. */
export function giveCard(gameId: string, username: string, code: string) {
  sql(`
    update app_private.game_cards
    set zone = 'player_hand', owner_player_id = ${playerOf(gameId, username)},
        pile_position = 1 + (select coalesce(max(pile_position), 0) from app_private.game_cards
                             where owner_player_id = ${playerOf(gameId, username)} and zone = 'player_hand')
    where id = (
      select id from app_private.game_cards
      where game_id = '${gameId}' and card_code = '${code}' and owner_player_id is null
        and zone in ('main_deck', 'main_discard')
      limit 1
    );`)
}

export function setHp(gameId: string, username: string, hp: number) {
  sql(`update app_private.game_players set hp = ${hp} where id = ${playerOf(gameId, username)};`)
}

export function resetActions(gameId: string) {
  sql(`update app_private.games set actions_used = 0 where id = '${gameId}';`)
}

/** Usuário (username) sentado no lugar indicado. */
export function userAtSeat(gameId: string, seat: number) {
  return sql(`select p.username from app_private.game_players gp join public.profiles p on p.id = gp.user_id
              where gp.game_id = '${gameId}' and gp.seat = ${seat};`)
}

export function seatOf(gameId: string, username: string) {
  return Number(
    sql(`select seat from app_private.game_players where id = ${playerOf(gameId, username)};`),
  )
}

/** Transforma em fantasma (mão principal vai para o descarte). */
export function makeGhost(gameId: string, username: string, tokens: number, revivalUsed = false) {
  sql(`
    update app_private.game_cards c
    set zone = 'main_discard', owner_player_id = null, pile_position = t.top + s.n
    from (select id, row_number() over () as n from app_private.game_cards
          where owner_player_id = ${playerOf(gameId, username)} and zone = 'player_hand') s,
         (select coalesce(max(pile_position), 0) as top from app_private.game_cards
          where game_id = '${gameId}' and zone = 'main_discard') t
    where c.id = s.id;
    update app_private.game_players set life_status = 'ghost', hp = 0, ghost_tokens = ${tokens},
      revival_used = ${revivalUsed} where id = ${playerOf(gameId, username)};`)
}

export function setRevivalUsed(gameId: string, username: string) {
  sql(
    `update app_private.game_players set revival_used = true where id = ${playerOf(gameId, username)};`,
  )
}

export function backdateLastSeen(gameId: string, username: string, minutes: number) {
  sql(`update app_private.game_players set last_seen_at = now() - interval '${minutes} minutes'
       where id = ${playerOf(gameId, username)};`)
}
