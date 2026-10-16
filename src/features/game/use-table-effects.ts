import { useEffect, useRef, useState } from 'react'
import type { CardCatalog } from '@/features/cards/catalog'
import type { GameView } from './game-service'

export type PlayerEffect = {
  id: number
  kind: 'damage' | 'heal' | 'hit' | 'death' | 'revive'
  /** PV perdidos ou recuperados (dano e cura). */
  amount?: number
}

/** Carta jogada mostrada em destaque no centro da tela. */
export type Spotlight = { id: number; code: string }

export type TableEffects = {
  byPlayer: ReadonlyMap<string, readonly PlayerEffect[]>
  spotlight: Spotlight | null
  /** Cartas que acabaram de entrar na minha mão (animam a compra). */
  drawnIds: ReadonlySet<string>
  /** Muda quando alguém compra do baralho principal (o monte "pula"). */
  deckDrawKey: number
}

/** Quanto tempo cada efeito fica na tela. */
export const EFFECT_MS = 1600
const SPOTLIGHT_MS = 1800

const HIT_CATEGORIES = new Set(['attack', 'chaos', 'sabotage', 'ghost'])

let nextId = 1

/**
 * Compara a mesa anterior com a nova e gera efeitos passageiros. Só anima o
 * que mudou depois que a tela abriu: recarregar a página não repete nada.
 * Usa apenas dados públicos da mesa (e a minha própria mão).
 */
export function useTableEffects(game: GameView, catalog: CardCatalog): TableEffects {
  const previous = useRef<GameView | null>(null)
  const [byPlayer, setByPlayer] = useState<Map<string, PlayerEffect[]>>(new Map())
  const [spotlight, setSpotlight] = useState<Spotlight | null>(null)
  const [drawnIds, setDrawnIds] = useState<ReadonlySet<string>>(new Set())
  const [deckDrawKey, setDeckDrawKey] = useState(0)

  useEffect(() => {
    const before = previous.current
    previous.current = game
    if (!before || before.gameId !== game.gameId || game.version <= before.version) return

    const later = (ms: number, fn: () => void) => window.setTimeout(fn, ms)

    // Efeitos por jogador -------------------------------------------------------
    const fresh: [string, PlayerEffect][] = []
    const add = (playerId: string, kind: PlayerEffect['kind'], amount?: number) =>
      fresh.push([playerId, { id: nextId++, kind, amount }])

    const old = new Map(before.participants.map((player) => [player.id, player]))
    for (const player of game.participants) {
      const was = old.get(player.id)
      if (!was) continue
      if (was.alive && !player.alive) add(player.id, 'death')
      else if (!was.alive && player.alive) add(player.id, 'revive')
      const delta = player.hp - was.hp
      // Na morte a vida vai a 0 e na volta sobe para 6: o efeito já diz isso.
      if (was.alive && player.alive && delta < 0) add(player.id, 'damage', -delta)
      if (was.alive && player.alive && delta > 0) add(player.id, 'heal', delta)
    }

    const lastSeq = before.events.at(-1)?.seq ?? 0
    const newEvents = game.events.filter((event) => event.seq > lastSeq)
    const played = newEvents.filter((event) => event.kind === 'card_played').at(-1)
    if (played && typeof played.payload.cardCode === 'string') {
      const code = played.payload.cardCode
      const card = catalog.get(code)
      setSpotlight({ id: nextId++, code })
      later(SPOTLIGHT_MS, () => setSpotlight(null))
      const targets = Array.isArray(played.payload.targets)
        ? (played.payload.targets as { playerId?: unknown }[])
        : []
      if (card && HIT_CATEGORIES.has(card.category)) {
        for (const target of targets) {
          if (typeof target.playerId === 'string') add(target.playerId, 'hit')
        }
      }
    }

    if (fresh.length > 0) {
      const ids = new Set(fresh.map(([, effect]) => effect.id))
      setByPlayer((current) => withEffects(current, fresh))
      later(EFFECT_MS, () => setByPlayer((current) => withoutEffects(current, ids)))
    }

    // Compra --------------------------------------------------------------------
    const known = new Set([...before.myHand, ...before.myGhostHand].map((card) => card.instanceId))
    const drawn = [...game.myHand, ...game.myGhostHand]
      .map((card) => card.instanceId)
      .filter((id) => !known.has(id))
    if (drawn.length > 0) {
      setDrawnIds(new Set(drawn))
      later(EFFECT_MS, () => setDrawnIds(new Set()))
    }
    if (game.mainDeckCount < before.mainDeckCount) setDeckDrawKey((key) => key + 1)
    // Os timers não são cancelados de propósito: cancelar cortaria os efeitos
    // quando a próxima versão chega no meio deles.
  }, [game, catalog])

  return { byPlayer, spotlight, drawnIds, deckDrawKey }
}

function withEffects(current: Map<string, PlayerEffect[]>, fresh: [string, PlayerEffect][]) {
  const next = new Map(current)
  for (const [playerId, effect] of fresh)
    next.set(playerId, [...(next.get(playerId) ?? []), effect])
  return next
}

function withoutEffects(current: Map<string, PlayerEffect[]>, ids: ReadonlySet<number>) {
  const next = new Map<string, PlayerEffect[]>()
  for (const [playerId, effects] of current) {
    const kept = effects.filter((effect) => !ids.has(effect.id))
    if (kept.length > 0) next.set(playerId, kept)
  }
  return next
}
