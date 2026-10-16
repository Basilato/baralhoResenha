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

  it('conta o Vale Entrosa do ponto de vista de cada um', () => {
    const set = event('turn_steal_set', { targetPlayerId: 'p2' }, 'p1')
    expect(describeEvent(set, players, catalog, 'p1')).toBe(
      'Você pegou o Vale Entrosa: a próxima vez de Beto é sua.',
    )
    expect(describeEvent(set, players, catalog, 'p2')).toBe(
      'Ana pegou o Vale Entrosa: a sua próxima vez é de Ana.',
    )
    expect(
      describeEvent(event('turn_stolen', { fromPlayerId: 'p2' }, 'p1'), players, catalog, null),
    ).toBe('Ana roubou a vez de Beto!')
    expect(
      describeEvent(event('turn_stolen', { fromPlayerId: 'p2' }, 'p1'), players, catalog, 'p2'),
    ).toBe('Ana roubou a sua vez!')
    expect(
      describeEvent(
        event('turn_steal_lapsed', { targetPlayerId: 'p2', reason: 'thief_down' }, 'p1'),
        players,
        catalog,
        null,
      ),
    ).toBe('O Vale Entrosa de Ana caducou: quem ia roubar a vez caiu antes.')
  })

  it('Só Mais Uma! conta a compra', () => {
    expect(describeEvent(event('cards_drawn', { count: 2 }, 'p2'), players, catalog, 'p1')).toBe(
      'Beto comprou 2 cartas.',
    )
    expect(describeEvent(event('cards_drawn', { count: 0 }, 'p1'), players, catalog, 'p1')).toBe(
      'Você não tinha cartas para comprar.',
    )
  })

  it('Rolê no Sítio mostra só quantidades', () => {
    expect(
      describeEvent(
        event('hands_shuffled', { count: 9, players: 4 }, 'p1'),
        players,
        catalog,
        'p2',
      ),
    ).toBe('Rolê no Sítio: 9 cartas de 4 jogadores foram embaralhadas e redistribuídas.')
  })

  it('turno fantasma compra do Além', () => {
    expect(
      describeEvent(event('turn_started', { drew: 1, ghost: true }, 'p2'), players, catalog, 'p1'),
    ).toBe('Turno fantasma de Beto: comprou 1 carta do Além.')
  })

  it('descreve ataque com dano por alvo e custo', () => {
    const played = event(
      'card_played',
      { cardCode: 'ATK-01', targets: [{ playerId: 'p2', damage: 4 }], costCode: null },
      'p1',
    )
    expect(describeEvent(played, players, catalog, 'p2')).toBe('Ana jogou Falou Merda em Você (4).')
  })

  it('descreve dano, sobrevivência e morte', () => {
    const damage = event('damage_dealt', {
      results: [
        { playerId: 'p2', damage: 3, hp: 13, survived: false },
        { playerId: 'p1', damage: 3, hp: 1, survived: true },
      ],
    })
    expect(describeEvent(damage, players, catalog, null)).toBe(
      'Beto sofreu 3 (ficou com 13 PV). Ana sobreviveu com 1 PV.',
    )
    expect(
      describeEvent(event('player_died', { byPlayerId: 'p1' }, 'p2'), players, catalog, null),
    ).toBe('Beto foi eliminado por Ana e virou fantasma.')
  })

  it('explica o fim de turno automático e o tempo esgotado', () => {
    expect(
      describeEvent(event('turn_ended', { reason: 'auto' }, 'p2'), players, catalog, 'p1'),
    ).toBe('Beto não tinha mais jogadas: a vez passou.')
    expect(
      describeEvent(
        event('turn_ended', { reason: 'timeout', discarded: ['ATK-01'] }, 'p2'),
        players,
        catalog,
        'p1',
      ),
    ).toBe('O tempo de Beto acabou: a vez passou e descartou Falou Merda.')
  })

  it('distingue resposta automática, por tempo e manual', () => {
    const passed = (payload: Record<string, unknown>) =>
      describeEvent(event('response_passed', payload, 'p2'), players, catalog, 'p1')
    expect(passed({ auto: true })).toBe('Beto não tinha como reagir: aceitou.')
    expect(passed({ timedOut: true })).toBe('O tempo de Beto acabou: aceitou.')
    expect(passed({})).toBe('Beto aceitou.')
  })
})
