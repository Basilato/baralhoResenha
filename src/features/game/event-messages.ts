import type { CardCatalog } from '@/features/cards/catalog'
import type { GameEvent, Participant } from './game-service'

/** Texto do histórico. Nunca recebe cartas ocultas: só o que o banco publicou. */
export function describeEvent(
  event: GameEvent,
  players: ReadonlyMap<string, Participant>,
  catalog: CardCatalog,
  myPlayerId: string | null,
): string {
  const name = (id: unknown) => {
    if (typeof id !== 'string') return 'Alguém'
    if (id === myPlayerId) return 'Você'
    return players.get(id)?.displayName ?? 'Alguém'
  }
  const actor = name(event.actorPlayerId)
  const p = event.payload

  switch (event.kind) {
    case 'game_started':
      return `A resenha começou com ${p.players} jogadores. Lugares sorteados.`
    case 'round_started': {
      const leader = p.leaderPlayerId ? ` Mais Odiado: ${name(p.leaderPlayerId)}.` : ''
      return `Rodada ${p.round} começou.${leader}`
    }
    case 'turn_started': {
      const drew = Number(p.drew ?? 0)
      const cards = drew === 1 ? '1 carta' : `${drew} cartas`
      const mine = event.actorPlayerId === myPlayerId
      if (p.ghost) {
        return mine
          ? `Seu turno fantasma: você comprou ${cards} do Além.`
          : `Turno fantasma de ${actor}: comprou ${cards} do Além.`
      }
      return mine ? `Sua vez: você comprou ${cards}.` : `Vez de ${actor}: comprou ${cards}.`
    }
    case 'turn_ended': {
      const discarded = Array.isArray(p.discarded) ? (p.discarded as string[]) : []
      if (discarded.length === 0) return `${actor} encerrou o turno.`
      const names = discarded.map((code) => catalog.get(code)?.name ?? code).join(', ')
      return `${actor} encerrou o turno e descartou ${names}.`
    }
    case 'game_finished':
      return 'Fim da partida!'
    default:
      return 'Algo aconteceu na mesa.'
  }
}
