#!/usr/bin/env node
// Simulações automatizadas com o motor de regras de verdade (Fase 10).
//
//   pnpm sim                         20 partidas, alternando 3, 5 e 8 jogadores
//   pnpm sim -- --games 60 --players 3,4,5,6,7,8 --seed 42
//   pnpm sim -- --report docs/BALANCEAMENTO.md
//
// Robôs fazem login com as contas de teste do seed (teste1…teste10) e jogam
// partidas inteiras pelas mesmas RPCs do app (submit_game_command), escolhendo
// alvos com as mesmas regras da tela (src/features/game/play-rules.ts).
// Depois de CADA jogada, admin_check_game_integrity confere a partida.
//
// Só para o banco local: lê .env.local (URL, chave pública, domínio) e
// .env.admin (secret key, para a checagem de integridade).

import { writeFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import { targetOptions, whyNotPlayable } from '../src/features/game/play-rules.ts'

// --- Opções -------------------------------------------------------------------

const args = process.argv.slice(2)
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`)
  return index >= 0 ? args[index + 1] : fallback
}
const GAMES = Number(option('games', '20'))
const SIZES = option('players', '3,5,8').split(',').map(Number)
const REPORT = option('report', null)
let seed = Number(option('seed', String(Date.now() % 1_000_000)))
const MAX_COMMANDS = 4000
const PASSWORD = 'resenha123'

const {
  VITE_SUPABASE_URL: URL,
  VITE_SUPABASE_PUBLISHABLE_KEY: KEY,
  VITE_AUTH_EMAIL_DOMAIN,
} = process.env
const { SUPABASE_SECRET_KEY } = process.env
if (!URL || !KEY || !VITE_AUTH_EMAIL_DOMAIN || !SUPABASE_SECRET_KEY) {
  console.error('Faltam variáveis: rode com --env-file=.env.local --env-file=.env.admin')
  process.exit(1)
}
if (!/127\.0\.0\.1|localhost/.test(URL)) {
  console.error('Simulação só roda no banco local.')
  process.exit(1)
}

// --- Aleatoriedade reproduzível (mulberry32) -----------------------------------

const firstSeed = seed
function random() {
  seed |= 0
  seed = (seed + 0x6d2b79f5) | 0
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}
const chance = (p) => random() < p
const pick = (list) => list[Math.floor(random() * list.length)]
function sample(list, count) {
  const copy = [...list]
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1))
    ;[copy[i], copy[j]] = [copy[j], copy[i]]
  }
  return copy.slice(0, count)
}

// --- Clientes -----------------------------------------------------------------

const admin = createClient(URL, SUPABASE_SECRET_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

const bots = new Map()
async function bot(username) {
  if (bots.has(username)) return bots.get(username)
  const client = createClient(URL, KEY, { auth: { persistSession: false } })
  const { data, error } = await client.auth.signInWithPassword({
    email: `${username}@${VITE_AUTH_EMAIL_DOMAIN}`,
    password: PASSWORD,
  })
  if (error) throw new Error(`login de ${username}: ${error.message}`)
  const entry = { username, client, userId: data.user.id }
  bots.set(username, entry)
  return entry
}

class RpcError extends Error {
  constructor(code, message) {
    super(`${code}: ${message}`)
    this.code = code
  }
}

async function rpc(client, name, params) {
  const { data, error } = await client.rpc(name, params)
  if (error) {
    // Erros do jogo chegam como P0001 com o código na mensagem.
    const code = error.code === 'P0001' ? error.message : `SQL_${error.code ?? 'ERRO'}`
    throw new RpcError(code, error.details || error.message)
  }
  return data
}

// --- Uma partida --------------------------------------------------------------

// Os robôs escolhem alvos com as mesmas regras da tela, que só orientam: o
// servidor valida de novo. Recusa de alvo é aceitável (e fica contada); qualquer
// outra recusa, ou erro SQL, indica bug e para a partida.
const EXPECTED_REJECTIONS = new Set(['INVALID_TARGET', 'NO_VALID_TARGET'])

async function playGame(size, catalog) {
  const users = sample(
    Array.from({ length: 10 }, (_, i) => `teste${i + 1}`),
    size,
  )
  const players = await Promise.all(users.map(bot))
  const host = players[0]

  // Fecha salas esquecidas destes robôs (limite de salas abertas por pessoa).
  for (const player of players) {
    const rooms = await rpc(player.client, 'list_my_rooms')
    for (const room of rooms ?? []) {
      if (room.isHost)
        await rpc(player.client, 'close_room', { p_game_id: room.id }).catch(() => {})
      else await rpc(player.client, 'leave_room', { p_game_id: room.id }).catch(() => {})
    }
  }

  const room = await rpc(host.client, 'create_room')
  const gameId = room.id
  const lobby = await rpc(host.client, 'get_room_view', { p_game_id: gameId })
  for (const player of players.slice(1))
    await rpc(player.client, 'join_room', { p_code: lobby.code })
  const ready = await rpc(host.client, 'get_room_view', { p_game_id: gameId })
  await rpc(host.client, 'start_game', { p_game_id: gameId, p_expected_version: ready.version })

  const started = Date.now()
  const stats = {
    size,
    gameId,
    commands: 0,
    rejections: {},
    turns: 0,
    deaths: 0,
    revivals: 0,
    hangoverDeaths: 0,
    cardsPlayed: 0,
    reactions: 0,
    rounds: 0,
    result: null,
    problems: [],
  }
  const seen = new Set()
  const byUserId = new Map(players.map((player) => [player.userId, player]))
  const view = (player) => rpc(player.client, 'get_game_view', { p_game_id: gameId })

  const record = (game) => {
    for (const event of game.events) {
      if (seen.has(event.seq)) continue
      seen.add(event.seq)
      if (event.kind === 'turn_started') stats.turns++
      if (event.kind === 'player_died') {
        stats.deaths++
        if (!event.payload.byPlayerId) stats.hangoverDeaths++
      }
      if (event.kind === 'player_revived') stats.revivals++
      if (event.kind === 'card_played') stats.cardsPlayed++
      if (event.kind === 'reaction_played') stats.reactions++
    }
    stats.rounds = game.round
  }

  const send = async (player, game, command) => {
    stats.commands++
    try {
      await rpc(player.client, 'submit_game_command', {
        p_game_id: gameId,
        p_expected_version: game.version,
        p_request_id: crypto.randomUUID(),
        p_command: command,
      })
    } catch (error) {
      if (!(error instanceof RpcError)) throw error
      // Anota a carta: recusa de alvo mostra onde a tela e o servidor discordam.
      const handCard =
        command.type === 'PLAY_CARD'
          ? [...game.myHand, ...game.myGhostHand].find(
              (item) => item.instanceId === command.cardInstanceId,
            )
          : null
      const key = handCard ? `${error.code} (${handCard.code})` : error.code
      stats.rejections[key] = (stats.rejections[key] ?? 0) + 1
      if (!EXPECTED_REJECTIONS.has(error.code)) {
        stats.problems.push(`recusa inesperada (${command.type}): ${error.message}`)
      }
      return false
    }
    const problems = await rpc(admin, 'admin_check_game_integrity', { p_game_id: gameId })
    if (problems.length > 0) {
      stats.problems.push(`integridade após ${command.type}: ${problems.join('; ')}`)
    }
    return true
  }

  while (stats.commands < MAX_COMMANDS && stats.problems.length === 0) {
    const overview = await view(host)
    record(overview)
    if (overview.status !== 'playing') {
      stats.result = overview.result
      break
    }

    const userOf = (playerId) => {
      const participant = overview.participants.find((item) => item.id === playerId)
      return participant && byUserId.get(participant.userId)
    }

    // Alguém precisa responder a uma jogada pendente?
    const waiting = overview.pendingAction?.responses.filter((response) => !response.responded)
    if (waiting?.length) {
      const responder = userOf(waiting[0].playerId)
      const game = await view(responder)
      const decision = game.myDecision
      if (!decision) {
        stats.problems.push('jogada pendente sem decisão para quem deve responder')
        break
      }
      await respond(responder, game, decision, send)
      continue
    }

    const active = userOf(overview.activePlayerId)
    const game = await view(active)
    await takeTurn(active, game, catalog, send)
  }

  if (!stats.result && stats.problems.length === 0) {
    stats.problems.push(`não terminou em ${MAX_COMMANDS} jogadas`)
  }
  stats.ms = Date.now() - started
  if (!stats.result) await rpc(host.client, 'close_room', { p_game_id: gameId }).catch(() => {})
  return stats
}

const CHOICE_ROLES = new Set(['actor_pick', 'target_discard', 'pass_pick', 'discard_pick'])

async function respond(player, game, decision, send) {
  if (CHOICE_ROLES.has(decision.role)) {
    const count = Math.min(decision.choiceCount ?? 1, decision.options.length)
    await send(player, game, {
      type: 'RESPOND',
      pendingActionId: decision.pendingActionId,
      response: 'CHOOSE',
      selectedCardIds: sample(decision.options, count).map((card) => card.instanceId),
    })
    return
  }
  const react = decision.eligibleCardIds.length > 0 && chance(0.7)
  await send(player, game, {
    type: 'RESPOND',
    pendingActionId: decision.pendingActionId,
    response: react ? 'REACT' : 'PASS',
    ...(react ? { cardInstanceId: pick(decision.eligibleCardIds) } : {}),
  })
}

async function takeTurn(player, game, catalog, send) {
  if (game.phase === 'ghost_decision') {
    await send(player, game, { type: chance(0.85) ? 'GHOST_REVIVE' : 'GHOST_STAY' })
    return
  }

  const me = game.participants.find((item) => item.id === game.myPlayerId)
  const hand = me.alive ? game.myHand : game.myGhostHand

  // Tenta jogar uma carta (às vezes o robô prefere guardar).
  if (chance(0.85)) {
    const candidates = sample(hand, hand.length)
    for (const handCard of candidates) {
      const card = catalog.get(handCard.code)
      if (!card || whyNotPlayable(card, game, true)) continue
      const { needed, eligible, emptyHanded } = targetOptions(card, game)
      const pool = eligible.filter((candidate) => !emptyHanded.has(candidate.id))
      if (pool.length < needed) continue
      const others = hand.filter((item) => item.instanceId !== handCard.instanceId)
      const swap = card.effectCode === 'swap_card'
      if ((card.discardCost || swap) && others.length === 0) continue
      const played = await send(player, game, {
        type: 'PLAY_CARD',
        cardInstanceId: handCard.instanceId,
        targetPlayerIds: sample(pool, needed).map((target) => target.id),
        discardCostCardId: card.discardCost ? pick(others).instanceId : null,
        ownSwapCardId: swap ? pick(others).instanceId : null,
      })
      if (played) return
      // Recusada: a mesa pode ter mudado; volta ao laço principal.
      return
    }
  }

  const limit = me.alive ? game.handLimit : game.ghostHandLimit
  const excess = Math.max(0, hand.length - limit)
  await send(player, game, {
    type: 'END_TURN',
    discardCardIds: sample(hand, excess).map((card) => card.instanceId),
  })
}

// --- Execução -----------------------------------------------------------------

const someone = await bot('teste1')
const catalogList = await rpc(someone.client, 'get_card_catalog', { p_set_version: '7.1' })
const catalog = new Map(catalogList.map((card) => [card.code, card]))

console.log(`Simulando ${GAMES} partidas (${SIZES.join('/')} jogadores, semente ${firstSeed})…`)
const results = []
for (let i = 0; i < GAMES; i++) {
  const size = SIZES[i % SIZES.length]
  const stats = await playGame(size, catalog)
  results.push(stats)
  const outcome = stats.result ? `${stats.result.reason}/${stats.result.criteria}` : 'SEM RESULTADO'
  console.log(
    `#${String(i + 1).padStart(3)} ${size}p  rodadas ${stats.rounds}  turnos ${stats.turns}  ` +
      `mortes ${stats.deaths}  voltas ${stats.revivals}  ${outcome}  ${(stats.ms / 1000).toFixed(1)}s` +
      (stats.problems.length ? `\n      PROBLEMA: ${stats.problems.join('\n      ')}` : ''),
  )
}

// --- Resumo -------------------------------------------------------------------

const summary = summarize(results)
console.log(`\n${summary}`)
if (REPORT) {
  writeFileSync(REPORT, report(summary))
  console.log(`Relatório salvo em ${REPORT}`)
}
const failed = results.filter((stats) => stats.problems.length > 0)
process.exitCode = failed.length > 0 ? 1 : 0

function avg(list, fn) {
  return list.length ? list.reduce((sum, item) => sum + fn(item), 0) / list.length : 0
}
function pct(part, total) {
  return total ? `${Math.round((part / total) * 100)}%` : '—'
}

function summarize(all) {
  const lines = []
  lines.push(
    '| Jogadores | Partidas | Rodadas (média) | Turnos | Jogadas | Cartas jogadas | Reações | Mortes | Mortes por Ressaca | Ressurreições | Fim por PV (rodada 10) | Último vivo | Todos caíram | Duração |',
  )
  lines.push('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
  for (const size of [...new Set(all.map((stats) => stats.size))].sort((a, b) => a - b)) {
    const group = all.filter((stats) => stats.size === size)
    const finished = group.filter((stats) => stats.result)
    const reason = (name) => finished.filter((stats) => stats.result.reason === name).length
    lines.push(
      `| ${size} | ${group.length} | ${avg(group, (s) => s.rounds).toFixed(1)} | ${avg(group, (s) => s.turns).toFixed(0)} | ` +
        `${avg(group, (s) => s.commands).toFixed(0)} | ${avg(group, (s) => s.cardsPlayed).toFixed(0)} | ` +
        `${avg(group, (s) => s.reactions).toFixed(1)} | ${avg(group, (s) => s.deaths).toFixed(1)} | ` +
        `${avg(group, (s) => s.hangoverDeaths).toFixed(1)} | ${avg(group, (s) => s.revivals).toFixed(1)} | ` +
        `${pct(reason('round_limit'), finished.length)} | ${pct(reason('last_alive'), finished.length)} | ` +
        `${pct(reason('all_dead'), finished.length)} | ${(avg(group, (s) => s.ms) / 1000).toFixed(1)}s |`,
    )
  }
  const problems = all.filter((stats) => stats.problems.length > 0)
  const rejections = {}
  for (const stats of all) {
    for (const [code, count] of Object.entries(stats.rejections)) {
      rejections[code] = (rejections[code] ?? 0) + count
    }
  }
  lines.push('')
  lines.push(`Partidas com problema: ${problems.length} de ${all.length}.`)
  lines.push(
    `Jogadas recusadas pelo servidor: ${
      Object.entries(rejections)
        .map(([code, count]) => `${code} ×${count}`)
        .join(', ') || 'nenhuma'
    }.`,
  )
  for (const stats of problems) lines.push(`- ${stats.gameId}: ${stats.problems.join('; ')}`)
  return lines.join('\n')
}

function report(table) {
  return `# Balanceamento — simulações automatizadas

Gerado por \`pnpm sim\` em ${new Date().toISOString().slice(0, 10)}: ${results.length} partidas com o motor de regras real (as mesmas RPCs do app), semente ${firstSeed}.

**Como os robôs jogam:** em cada turno, 85% de chance de jogar uma carta jogável (alvos escolhidos como na tela); reagem com 70% de chance quando têm defesa; fantasmas com 3 fichas ressuscitam com 85% de chance; descartam ao acaso. É um jogador "médio e distraído", não um estrategista: serve para medir ritmo e achar travamentos, não para decidir se uma carta é forte.

**Integridade:** depois de cada jogada, \`admin_check_game_integrity\` confere as 180 cartas, mãos, vida, fichas, fase e jogada pendente.

${table}

**Abandono:** os robôs não abandonam; remoção por ausência é coberta pelos testes e2e (endgame.spec.ts).
`
}
