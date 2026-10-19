import { renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { playSound } from '@/lib/sounds'
import type { PlayerEffect, TableEffects } from './use-table-effects'
import { useTableSounds } from './use-table-sounds'

vi.mock('@/lib/sounds', () => ({ playSound: vi.fn<(name: string) => void>() }))

const fx = (overrides: Partial<TableEffects> = {}): TableEffects => ({
  byPlayer: new Map(),
  spotlight: null,
  drawnIds: new Set(),
  deckDrawKey: 0,
  ...overrides,
})

const effects = (...list: [string, PlayerEffect][]) => {
  const map = new Map<string, PlayerEffect[]>()
  for (const [player, effect] of list) map.set(player, [...(map.get(player) ?? []), effect])
  return map
}

function setup(first = fx(), isMyTurn = false, finished = false) {
  return renderHook(({ value, mine, done }) => useTableSounds(value, mine, done), {
    initialProps: { value: first, mine: isMyTurn, done: finished },
  })
}

describe('useTableSounds', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => {
    vi.useRealTimers()
    vi.mocked(playSound).mockClear()
  })

  it('fica em silêncio ao abrir a mesa, mesmo na minha vez', () => {
    setup(fx(), true)
    vi.runAllTimers()
    expect(playSound).not.toHaveBeenCalled()
  })

  it('carta jogada e depois o som mais importante da leva', () => {
    const { rerender } = setup()
    rerender({
      value: fx({
        spotlight: { id: 1, code: 'ATK-01', playerId: 'a', to: 'discard' },
        byPlayer: effects(
          ['a', { id: 2, kind: 'damage', amount: 3 }],
          ['b', { id: 3, kind: 'death' }],
        ),
      }),
      mine: false,
      done: false,
    })
    expect(playSound).toHaveBeenCalledWith('card')
    vi.runAllTimers()
    expect(playSound).toHaveBeenLastCalledWith('death')
    expect(playSound).toHaveBeenCalledTimes(2)
  })

  it('não repete efeitos já ouvidos', () => {
    const value = fx({ byPlayer: effects(['a', { id: 9, kind: 'heal', amount: 2 }]) })
    const { rerender } = setup()
    rerender({ value, mine: false, done: false })
    rerender({ value: { ...value, deckDrawKey: 1 }, mine: false, done: false })
    vi.runAllTimers()
    expect(playSound).toHaveBeenCalledTimes(1)
  })

  it('compra, começo da minha vez e fim da partida', () => {
    const { rerender } = setup()
    rerender({ value: fx({ drawnIds: new Set(['c1']) }), mine: true, done: false })
    expect(playSound).toHaveBeenCalledWith('draw')
    expect(playSound).toHaveBeenCalledWith('turn')
    rerender({ value: fx(), mine: false, done: true })
    expect(playSound).toHaveBeenLastCalledWith('win')
  })
})
