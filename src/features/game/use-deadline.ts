import { useEffect, useState } from 'react'
import { newRequestId, useGameCommand, type GameView } from './game-service'

/** Folga depois do prazo antes de cobrar: o relógio do aparelho nunca é exato. */
const GRACE_MS = 1000
/** Espalha as cobranças: cada aparelho espera um pouco a mais, ao acaso. */
const JITTER_MS = 2000
const RETRY_MS = 3000
const MAX_RETRIES = 4

/** Prazo que vale agora: o da jogada pendente ou, sem ela, o do turno. */
export function activeDeadline(game: GameView) {
  if (game.status !== 'playing') return null
  return game.pendingAction ? game.responseDeadlineAt : game.turnDeadlineAt
}

/**
 * Segundos até o prazo, atualizados a cada segundo. `skewMs` corrige o relógio
 * do aparelho (servidor menos aparelho).
 */
export function useSecondsLeft(deadline: string | null, skewMs: number) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!deadline) return
    // Prazo novo: atualiza já, sem esperar o próximo segundo.
    const first = setTimeout(() => setNow(Date.now()), 0)
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => {
      clearTimeout(first)
      clearInterval(timer)
    }
  }, [deadline])

  if (!deadline) return null
  return Math.max(0, Math.ceil((Date.parse(deadline) - (now + skewMs)) / 1000))
}

/**
 * Cobra o prazo vencido. Qualquer participante pode cobrar e o banco confere
 * a hora; quem chegar depois recebe conflito de versão e só recarrega a mesa.
 */
export function useDeadlineEnforcer(game: GameView, enabled: boolean) {
  const command = useGameCommand(game)
  const skew = game.clockSkewMs
  const deadline = enabled ? activeDeadline(game) : null
  const [retry, setRetry] = useState({ deadline: '', count: 0 })
  const attempts = retry.deadline === deadline ? retry.count : 0
  const { mutate } = command

  useEffect(() => {
    if (!deadline || attempts > MAX_RETRIES) return
    const due = Date.parse(deadline) - (Date.now() + skew) + GRACE_MS
    const wait = Math.max(due, attempts > 0 ? RETRY_MS : 0) + Math.random() * JITTER_MS
    const timer = setTimeout(
      () =>
        mutate(
          { requestId: newRequestId(), command: { type: 'TIMEOUT' } },
          { onError: () => setRetry({ deadline, count: attempts + 1 }) },
        ),
      wait,
    )
    return () => clearTimeout(timer)
  }, [deadline, skew, attempts, mutate])
}
