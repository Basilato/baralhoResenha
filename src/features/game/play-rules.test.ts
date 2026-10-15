import { describe, expect, it } from 'vitest'
import type { CardDefinition } from '@/features/cards/catalog'
import type { GameView, Participant } from './game-service'
import { targetOptions, whyNotPlayable } from './play-rules'

const attack = { category: 'attack', deckType: 'main', isReaction: false } as CardDefinition
const game = (overrides: Partial<GameView> = {}) =>
  ({ phase: 'turn_main', actionsUsed: 0, maxActions: 2, ...overrides }) as GameView

const player = (id: string, hp: number, cardsInHand: number, alive = true) =>
  ({ id, hp, cardsInHand, alive }) as Participant
const table = game({
  myPlayerId: 'me',
  participants: [
    player('me', 16, 5),
    player('b', 12, 0),
    player('c', 16, 3),
    player('d', 16, 3),
    player('ghost', 0, 0, false),
  ],
})
const card = (targetRule: string, effectCode = 'x') =>
  ({ targetRule, effectCode }) as CardDefinition
const ids = (players: Participant[]) => players.map((p) => p.id)

describe('whyNotPlayable', () => {
  it('libera carta na própria vez com ação sobrando', () => {
    expect(whyNotPlayable(attack, game(), true)).toBeNull()
  })

  it('explica cada bloqueio', () => {
    expect(whyNotPlayable({ ...attack, isReaction: true }, game(), true)).toMatch(/reação/)
    expect(
      whyNotPlayable({ ...attack, category: 'ghost', deckType: 'ghost' }, game(), true),
    ).toMatch(/fantasma/)
    expect(whyNotPlayable(attack, game(), false)).toMatch(/sua vez/)
    expect(whyNotPlayable(attack, game({ phase: 'awaiting_reactions' }), true)).toMatch(/terminar/)
    expect(whyNotPlayable(attack, game({ actionsUsed: 2 }), true)).toMatch(/2 ações/)
  })
})

describe('targetOptions', () => {
  it('cartas sem alvo não pedem escolha', () => {
    expect(targetOptions(card('self'), table).needed).toBe(0)
    expect(targetOptions(card('all_alive'), table).needed).toBe(0)
  })

  it('nunca oferece fantasmas nem a si mesmo', () => {
    expect(ids(targetOptions(card('opponent'), table).eligible)).toEqual(['b', 'c', 'd'])
  })

  it('Família Basilato: só quem tem mais PV (empate: autor escolhe)', () => {
    expect(ids(targetOptions(card('opponent_highest_hp'), table).eligible)).toEqual(['c', 'd'])
  })

  it('Print Comprometedor: só quem tem mais cartas', () => {
    expect(ids(targetOptions(card('opponent_most_cards'), table).eligible)).toEqual(['c', 'd'])
  })

  it('sabotagem de mão marca quem está sem cartas', () => {
    expect([...targetOptions(card('opponent', 'steal_random'), table).emptyHanded]).toEqual(['b'])
    expect(targetOptions(card('opponent', 'swap_hands'), table).emptyHanded.size).toBe(0)
  })
})
