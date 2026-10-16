import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { CardCatalog, CardDefinition } from '@/features/cards/catalog'
import type { GameEvent, GameView, Participant } from './game-service'
import { EFFECT_MS, useTableEffects } from './use-table-effects'

const player = (id: string, hp: number, alive = true): Participant => ({
  id,
  userId: `u-${id}`,
  displayName: id,
  avatarPath: null,
  seat: 1,
  isHost: false,
  hp,
  maxHp: 18,
  alive,
  cardsInHand: 5,
  ghostCardsInHand: 0,
  ghostTokens: 0,
  revivalUsed: false,
  knockouts: 0,
})

const view = (version: number, overrides: Partial<GameView> = {}): GameView =>
  ({
    gameId: 'g1',
    version,
    participants: [player('a', 18), player('b', 18)],
    myHand: [{ instanceId: 'c1', code: 'ATK-01' }],
    myGhostHand: [],
    mainDeckCount: 100,
    events: [],
    ...overrides,
  }) as GameView

const attack = { code: 'ATK-01', category: 'attack' } as CardDefinition
const catalog: CardCatalog = new Map([['ATK-01', attack]])

const played = (seq: number, targets: string[]): GameEvent => ({
  seq,
  kind: 'card_played',
  actorPlayerId: 'a',
  payload: { cardCode: 'ATK-01', targets: targets.map((playerId) => ({ playerId })) },
  at: '',
})

function setup(first: GameView) {
  return renderHook(({ game }) => useTableEffects(game, catalog), {
    initialProps: { game: first },
  })
}

describe('useTableEffects', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('não anima nada ao abrir a mesa', () => {
    const { result } = setup(view(5, { events: [played(1, ['b'])] }))
    expect(result.current.byPlayer.size).toBe(0)
    expect(result.current.spotlight).toBeNull()
    expect(result.current.drawnIds.size).toBe(0)
  })

  it('dano, cura e golpe por jogador, que somem depois', () => {
    const { result, rerender } = setup(
      view(1, { participants: [player('a', 10), player('b', 18)] }),
    )
    rerender({
      game: view(2, {
        participants: [player('a', 14), player('b', 15)],
        events: [played(1, ['b'])],
      }),
    })
    expect(result.current.byPlayer.get('a')).toMatchObject([{ kind: 'heal', amount: 4 }])
    expect(
      result.current.byPlayer
        .get('b')
        ?.map((effect) => effect.kind)
        .sort(),
    ).toEqual(['damage', 'hit'])
    expect(result.current.spotlight?.code).toBe('ATK-01')

    act(() => vi.advanceTimersByTime(EFFECT_MS))
    expect(result.current.byPlayer.size).toBe(0)
  })

  it('morte e ressurreição sem número de dano', () => {
    const { result, rerender } = setup(
      view(1, { participants: [player('a', 2), player('b', 0, false)] }),
    )
    rerender({ game: view(2, { participants: [player('a', 0, false), player('b', 6)] }) })
    expect(result.current.byPlayer.get('a')).toMatchObject([{ kind: 'death' }])
    expect(result.current.byPlayer.get('b')).toMatchObject([{ kind: 'revive' }])
  })

  it('cartas compradas e o monte que diminui', () => {
    const { result, rerender } = setup(view(1))
    rerender({
      game: view(2, {
        mainDeckCount: 98,
        myHand: [
          { instanceId: 'c1', code: 'ATK-01' },
          { instanceId: 'c2', code: 'ATK-01' },
          { instanceId: 'c3', code: 'ATK-01' },
        ],
      }),
    })
    expect([...result.current.drawnIds]).toEqual(['c2', 'c3'])
    expect(result.current.deckDrawKey).toBe(1)
  })

  it('ignora recargas da mesma versão', () => {
    const { result, rerender } = setup(view(3))
    rerender({ game: view(3, { participants: [player('a', 1), player('b', 18)] }) })
    expect(result.current.byPlayer.size).toBe(0)
  })
})
