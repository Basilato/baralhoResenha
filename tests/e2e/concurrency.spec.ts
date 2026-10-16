import { readFileSync } from 'node:fs'
import { expect, test } from '@playwright/test'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { giveCard, PASSWORD, sql } from './support.ts'

// Duas abas (ou dois cliques) disparando ao mesmo tempo, direto na API: o banco
// tem de aplicar cada jogada uma vez só e recusar a que chegou atrasada.
// Não usa navegador; roda só no projeto desktop.

const env = Object.fromEntries(
  readFileSync('.env.local', 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && line.includes('='))
    .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
)

async function signIn(username: string) {
  const client = createClient(env.VITE_SUPABASE_URL!, env.VITE_SUPABASE_PUBLISHABLE_KEY!, {
    auth: { persistSession: false },
  })
  const { error } = await client.auth.signInWithPassword({
    email: `${username}@${env.VITE_AUTH_EMAIL_DOMAIN}`,
    password: PASSWORD,
  })
  if (error) throw error
  return client
}

type View = {
  version: number
  activePlayerId: string
  myPlayerId: string
  round: number
  myHand: { instanceId: string; code: string }[]
  participants: { id: string; userId: string; hp: number; displayName: string }[]
  events: { seq: number; kind: string }[]
  myDecision: { pendingActionId: string } | null
}

const view = async (client: SupabaseClient, gameId: string) => {
  const { data, error } = await client.rpc('get_game_view', { p_game_id: gameId })
  if (error) throw error
  return data as View
}

const submit = (
  client: SupabaseClient,
  gameId: string,
  version: number,
  command: object,
  requestId: string = crypto.randomUUID(),
) =>
  client.rpc('submit_game_command', {
    p_game_id: gameId,
    p_expected_version: version,
    p_request_id: requestId,
    p_command: command,
  })

async function startGame(usernames: string[]) {
  const clients = await Promise.all(usernames.map(signIn))
  const host = clients[0]!
  const { data: room, error } = await host.rpc('create_room')
  if (error) throw error
  const gameId = (room as { id: string }).id
  const { data: lobby } = await host.rpc('get_room_view', { p_game_id: gameId })
  for (const client of clients.slice(1)) {
    const joined = await client.rpc('join_room', { p_code: (lobby as { code: string }).code })
    if (joined.error) throw joined.error
  }
  const { data: ready } = await host.rpc('get_room_view', { p_game_id: gameId })
  const started = await host.rpc('start_game', {
    p_game_id: gameId,
    p_expected_version: (ready as { version: number }).version,
  })
  if (started.error) throw started.error
  const views = await Promise.all(clients.map((client) => view(client, gameId)))
  const activeIndex = views.findIndex((item) => item.myPlayerId === item.activePlayerId)
  return {
    gameId,
    clients,
    views,
    activeIndex,
    close: () => host.rpc('close_room', { p_game_id: gameId }),
  }
}

const turnsStarted = (item: View) =>
  item.events.filter((event) => event.kind === 'turn_started').length

test.describe('concorrência', () => {
  test.beforeEach(() => {
    test.skip(test.info().project.name !== 'desktop', 'só API, sem navegador')
  })

  test('duas abas encerram o turno ao mesmo tempo: uma passa, a outra é recusada', async () => {
    const game = await startGame(['teste1', 'teste2', 'teste3'])
    const active = game.clients[game.activeIndex]!
    const before = game.views[game.activeIndex]!

    const results = await Promise.all([
      submit(active, game.gameId, before.version, { type: 'END_TURN' }),
      submit(active, game.gameId, before.version, { type: 'END_TURN' }),
    ])
    const ok = results.filter((result) => !result.error)
    const refused = results.filter((result) => result.error)
    expect(ok).toHaveLength(1)
    expect(refused).toHaveLength(1)
    expect(refused[0]!.error!.message).toBe('VERSION_CONFLICT')

    const after = await view(active, game.gameId)
    expect(turnsStarted(after)).toBe(turnsStarted(before) + 1)
    expect(after.activePlayerId).not.toBe(before.activePlayerId)
    await game.close()
  })

  test('o mesmo pedido enviado duas vezes ao mesmo tempo vale uma vez só', async () => {
    const game = await startGame(['teste4', 'teste5', 'teste6'])
    const active = game.clients[game.activeIndex]!
    const before = game.views[game.activeIndex]!
    const requestId = crypto.randomUUID()

    const results = await Promise.all([
      submit(active, game.gameId, before.version, { type: 'END_TURN' }, requestId),
      submit(active, game.gameId, before.version, { type: 'END_TURN' }, requestId),
    ])
    for (const result of results) expect(result.error).toBeNull()
    const replayed = results.map(
      (result) => (result.data as { replayed?: boolean }).replayed ?? false,
    )
    expect(replayed.sort()).toEqual([false, true])

    const after = await view(active, game.gameId)
    expect(turnsStarted(after)).toBe(turnsStarted(before) + 1)
    await game.close()
  })

  test('dois alvos respondem ao mesmo tempo: o dano sai uma vez para cada', async () => {
    const usernames = ['teste7', 'teste8', 'teste9']
    const game = await startGame(usernames)
    const attackerName = usernames[game.activeIndex]!
    const attacker = game.clients[game.activeIndex]!
    giveCard(game.gameId, attackerName, 'ATK-04') // 2 de dano em até 2 adversários
    sql(`update app_private.games set leader_player_id = null where id = '${game.gameId}';`)

    const before = await view(attacker, game.gameId)
    const card = before.myHand.find((item) => item.code === 'ATK-04')!
    const targets = before.participants.filter((player) => player.id !== before.myPlayerId)
    const played = await submit(attacker, game.gameId, before.version, {
      type: 'PLAY_CARD',
      cardInstanceId: card.instanceId,
      targetPlayerIds: targets.map((player) => player.id),
    })
    expect(played.error).toBeNull()

    const targetClients = game.clients.filter((_, index) => index !== game.activeIndex)
    const decisions = await Promise.all(targetClients.map((client) => view(client, game.gameId)))
    const results = await Promise.all(
      targetClients.map((client, index) =>
        submit(client, game.gameId, decisions[index]!.version, {
          type: 'RESPOND',
          pendingActionId: decisions[index]!.myDecision!.pendingActionId,
          response: 'PASS',
        }),
      ),
    )
    // Respostas simultâneas: uma pode chegar depois da outra mudar a versão.
    // A recusada tenta de novo, como o app faz ao recarregar a mesa.
    for (const [index, result] of results.entries()) {
      if (!result.error) continue
      expect(result.error.message).toBe('VERSION_CONFLICT')
      const fresh = await view(targetClients[index]!, game.gameId)
      const retry = await submit(targetClients[index]!, game.gameId, fresh.version, {
        type: 'RESPOND',
        pendingActionId: fresh.myDecision!.pendingActionId,
        response: 'PASS',
      })
      expect(retry.error).toBeNull()
    }

    const after = await view(attacker, game.gameId)
    for (const target of targets) {
      const now = after.participants.find((player) => player.id === target.id)!
      expect(now.hp).toBe(target.hp - 2)
    }
    expect(after.myDecision).toBeNull()
    await game.close()
  })
})
