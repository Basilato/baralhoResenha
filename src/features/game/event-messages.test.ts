import { describe, expect, it } from 'vitest'
import type { CardDefinition } from '@/features/cards/catalog'
import { describeEvent } from './event-messages'
import type { GameEvent, Participant } from './game-service'

const player = (id: string, displayName: string) => ({ id, displayName }) as Participant
const players = new Map([
  ['p1', player('p1', 'Ana')],
  ['p2', player('p2', 'Beto')],
])
const catalog = new Map([['ATK-01', { code: 'ATK-01', name: 'Falou Merda' } as CardDefinition]])
const event = (
  kind: string,
  payload: Record<string, unknown>,
  actorPlayerId: string | null = null,
) => ({ seq: 1, kind, actorPlayerId, payload, at: '' }) as GameEvent

describe('describeEvent', () => {
  it('fala com o próprio jogador na vez dele', () => {
    expect(describeEvent(event('turn_started', { drew: 2 }, 'p1'), players, catalog, 'p1')).toBe(
      'Sua vez: você comprou 2 cartas.',
    )
  })

  it('mostra o nome dos outros e o Mais Odiado', () => {
    expect(
      describeEvent(
        event('round_started', { round: 2, leaderPlayerId: 'p2' }),
        players,
        catalog,
        'p1',
      ),
    ).toBe('Rodada 2 começou. Mais Odiado: Beto.')
  })

  it('cita as cartas descartadas pelo nome (descarte é público)', () => {
    expect(
      describeEvent(event('turn_ended', { discarded: ['ATK-01'] }, 'p2'), players, catalog, 'p1'),
    ).toBe('Beto encerrou o turno e descartou Falou Merda.')
  })

  it('turno fantasma compra do Além', () => {
    expect(
      describeEvent(event('turn_started', { drew: 1, ghost: true }, 'p2'), players, catalog, 'p1'),
    ).toBe('Turno fantasma de Beto: comprou 1 carta do Além.')
  })
})
