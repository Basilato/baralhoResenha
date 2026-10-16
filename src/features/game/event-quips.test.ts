import { describe, expect, it } from 'vitest'
import { eventQuip } from './event-quips'
import type { GameEvent } from './game-service'

const names: Record<string, string> = { p1: 'Ana', p2: 'Beto' }
const name = (id: unknown) => (typeof id === 'string' && names[id]) || 'Alguém'
const event = (kind: string, payload: Record<string, unknown> = {}, seq = 1): GameEvent => ({
  seq,
  kind,
  actorPlayerId: 'p1',
  payload,
  at: '',
})

describe('eventQuip', () => {
  it('é a mesma frase para o mesmo evento (todos na mesa veem igual)', () => {
    const played = event('card_played', { cardCode: 'ATK-05' }, 7)
    expect(eventQuip(played, name)).toBe(eventQuip(played, name))
    expect(eventQuip(played, name)).toMatch(/print/i)
  })

  it('varia a frase conforme o evento', () => {
    const quips = new Set(
      [1, 2, 3, 4].map((seq) =>
        eventQuip(
          event('damage_dealt', { results: [{ playerId: 'p2', damage: 2, survived: false }] }, seq),
          name,
        ),
      ),
    )
    expect(quips.size).toBeGreaterThan(1)
  })

  it('reações usam a frase da própria carta', () => {
    expect(eventQuip(event('reaction_played', { cardCode: 'DEF-03' }), name)).toMatch(
      /dormindo|ouviu/i,
    )
  })

  it('distingue sobreviver, não sofrer dano e pancada grande', () => {
    const quip = (result: object) => eventQuip(event('damage_dealt', { results: [result] }), name)
    expect(quip({ playerId: 'p2', damage: 5, survived: true })).toMatch(/fio|ainda/i)
    expect(quip({ playerId: 'p2', damage: 0, survived: false })).toMatch(/raspão|cócegas/i)
    expect(quip({ playerId: 'p2', damage: 6, survived: false })).toMatch(/pancada|Beto/)
  })

  it('eventos repetitivos ficam sem comentário', () => {
    expect(eventQuip(event('turn_started', { drew: 2 }), name)).toBeNull()
    expect(eventQuip(event('response_passed'), name)).toBeNull()
  })

  it('espiadas e roubos não revelam cartas, mesmo que o payload trouxesse alguma', () => {
    for (const kind of ['ghost_peeked', 'card_stolen', 'card_swapped', 'card_to_bottom']) {
      for (const seq of [1, 2, 3]) {
        const quip = eventQuip(event(kind, { codes: ['ATK-01'], cardCode: 'ATK-01' }, seq), name)
        expect(quip).not.toMatch(/ATK-01|Falou Merda/)
      }
    }
  })
})
