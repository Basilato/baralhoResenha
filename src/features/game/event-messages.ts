import type { CardCatalog } from '@/features/cards/catalog'
import type { GameEvent, Participant } from './game-service'

type DamageResult = { playerId: string; damage: number; hp: number; survived: boolean }

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
  const cardName = (code: unknown) =>
    typeof code === 'string' ? (catalog.get(code)?.name ?? code) : 'uma carta'
  const actor = name(event.actorPlayerId)
  const mine = event.actorPlayerId === myPlayerId
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
      if (p.ghost) {
        return mine
          ? `Seu turno fantasma: você comprou ${cards} do Além.`
          : `Turno fantasma de ${actor}: comprou ${cards} do Além.`
      }
      return mine ? `Sua vez: você comprou ${cards}.` : `Vez de ${actor}: comprou ${cards}.`
    }
    case 'turn_ended': {
      if (p.reason === 'died') return `${actor} caiu no próprio turno e perdeu a vez.`
      const discarded = Array.isArray(p.discarded) ? (p.discarded as string[]) : []
      if (discarded.length === 0) return `${actor} encerrou o turno.`
      return `${actor} encerrou o turno e descartou ${discarded.map(cardName).join(', ')}.`
    }
    case 'card_played': {
      const targets = Array.isArray(p.targets)
        ? (p.targets as { playerId: string; damage: number }[])
        : []
      const who = targets.map((target) => `${name(target.playerId)} (${target.damage})`).join(' e ')
      const cost = p.costCode ? `, descartando ${cardName(p.costCode)},` : ''
      return `${actor} jogou ${cardName(p.cardCode)}${cost} em ${who}.`
    }
    case 'reaction_played':
      return p.role === 'counter'
        ? `${actor} se defendeu do ataque devolvido com ${cardName(p.cardCode)}.`
        : `${actor} reagiu com ${cardName(p.cardCode)}.`
    case 'response_passed':
      return `${actor} aceitou.`
    case 'damage_dealt': {
      const results = Array.isArray(p.results) ? (p.results as DamageResult[]) : []
      return results
        .map((result) =>
          result.survived
            ? `${name(result.playerId)} sobreviveu com 1 PV.`
            : result.damage === 0
              ? `${name(result.playerId)} não sofreu dano.`
              : `${name(result.playerId)} sofreu ${result.damage} (ficou com ${result.hp} PV).`,
        )
        .join(' ')
    }
    case 'self_damage':
      return p.survived
        ? `${actor} sofreu o dano da própria carta e sobreviveu com 1 PV.`
        : `${actor} sofreu ${p.damage} de dano da própria carta.`
    case 'last_word':
      return `Última Palavra: ${actor} causou ${p.damage} em ${name(p.targetPlayerId)}.`
    case 'player_died':
      return p.byPlayerId
        ? `${actor} foi eliminado por ${name(p.byPlayerId)} e virou fantasma.`
        : `${actor} caiu e virou fantasma.`
    case 'game_finished':
      return 'Fim da partida!'
    default:
      return 'Algo aconteceu na mesa.'
  }
}
