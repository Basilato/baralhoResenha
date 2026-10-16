import { describe, expect, it } from 'vitest'
import type { GameView } from './game-service'
import { activeDeadline } from './use-deadline'

const game = (patch: Partial<GameView>) =>
  ({
    status: 'playing',
    pendingAction: null,
    turnDeadlineAt: 'turno',
    responseDeadlineAt: null,
    ...patch,
  }) as GameView

describe('activeDeadline', () => {
  it('sem jogada pendente, vale o prazo do turno', () => {
    expect(activeDeadline(game({}))).toBe('turno')
  })

  it('com jogada pendente, vale o prazo da resposta', () => {
    expect(
      activeDeadline(
        game({ pendingAction: {} as GameView['pendingAction'], responseDeadlineAt: 'resposta' }),
      ),
    ).toBe('resposta')
  })

  it('partida encerrada não tem prazo', () => {
    expect(activeDeadline(game({ status: 'finished' }))).toBeNull()
  })
})
