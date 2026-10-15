import { describe, expect, it } from 'vitest'
import type { CardDefinition } from '@/features/cards/catalog'
import type { GameView } from './game-service'
import { whyNotPlayable } from './play-rules'

const attack = { category: 'attack', isReaction: false } as CardDefinition
const game = (overrides: Partial<GameView> = {}) =>
  ({ phase: 'turn_main', actionsUsed: 0, maxActions: 2, ...overrides }) as GameView

describe('whyNotPlayable', () => {
  it('libera ataque na própria vez com ação sobrando', () => {
    expect(whyNotPlayable(attack, game(), true)).toBeNull()
  })

  it('explica cada bloqueio', () => {
    expect(whyNotPlayable({ ...attack, isReaction: true }, game(), true)).toMatch(/reação/)
    expect(whyNotPlayable({ ...attack, category: 'recovery' }, game(), true)).toMatch(/ainda não/)
    expect(whyNotPlayable(attack, game(), false)).toMatch(/sua vez/)
    expect(whyNotPlayable(attack, game({ phase: 'awaiting_reactions' }), true)).toMatch(/terminar/)
    expect(whyNotPlayable(attack, game({ actionsUsed: 2 }), true)).toMatch(/2 ações/)
  })
})
