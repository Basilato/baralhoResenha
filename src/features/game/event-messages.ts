import type { CardCatalog } from '@/features/cards/catalog'
import type { GameEvent, Participant, PrivateEvent } from './game-service'

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
      if (p.reason === 'removed') return `O turno de ${actor} foi pulado (ausente).`
      if (p.reason === 'auto') return `${actor} não tinha mais jogadas: a vez passou.`
      const discarded = Array.isArray(p.discarded) ? (p.discarded as string[]) : []
      if (p.reason === 'timeout') {
        const lost =
          discarded.length > 0 ? ` e descartou ${discarded.map(cardName).join(', ')}` : ''
        return `O tempo de ${actor} acabou: a vez passou${lost}.`
      }
      if (discarded.length === 0) return `${actor} encerrou o turno.`
      return `${actor} encerrou o turno e descartou ${discarded.map(cardName).join(', ')}.`
    }
    case 'card_played': {
      const targets = Array.isArray(p.targets)
        ? (p.targets as { playerId: string; damage?: number }[])
        : []
      const cost = p.costCode ? `, descartando ${cardName(p.costCode)}` : ''
      if (targets.length === 0) return `${actor} jogou ${cardName(p.cardCode)}${cost}.`
      const who = targets
        .map((target) =>
          target.damage === undefined
            ? name(target.playerId)
            : `${name(target.playerId)} (${target.damage})`,
        )
        .join(' e ')
      return `${actor} jogou ${cardName(p.cardCode)}${cost ? `${cost},` : ''} em ${who}.`
    }
    case 'sabotage_blocked':
      return `${actor} cancelou ${cardName(p.cardCode)} com Evento Raro.`
    case 'card_stolen':
      return Number(p.count) > 0
        ? `${actor} roubou 1 carta de ${name(p.fromPlayerId)}.`
        : `${name(p.fromPlayerId)} não tinha cartas para roubar.`
    case 'target_marked':
      return `${name(p.targetPlayerId)} foi marcado: o próximo ataque contra ele causa +2 (vale até a rodada ${p.untilRound}).`
    case 'turn_steal_set': {
      const turn =
        p.targetPlayerId === myPlayerId
          ? 'a sua próxima vez'
          : `a próxima vez de ${name(p.targetPlayerId)}`
      return `${actor} pegou o Vale Entrosa: ${turn} é ${mine ? 'sua' : `de ${actor}`}.`
    }
    case 'turn_stolen':
      return p.fromPlayerId === myPlayerId
        ? `${actor} roubou a sua vez!`
        : `${actor} roubou a vez de ${name(p.fromPlayerId)}!`
    case 'turn_steal_lapsed':
      return p.reason === 'thief_down'
        ? `O Vale Entrosa de ${actor} caducou: quem ia roubar a vez caiu antes.`
        : `O Vale Entrosa de ${actor} caducou: ${name(p.targetPlayerId)} já não estava vivo.`
    case 'card_swapped':
      return `${actor} trocou 1 carta com ${name(p.targetPlayerId)}.`
    case 'cards_discarded': {
      const codes = Array.isArray(p.codes) ? (p.codes as string[]) : []
      return `${actor} descartou ${codes.map(cardName).join(', ') || 'nada'}.`
    }
    case 'cards_passed':
      return `${p.count} cartas foram passadas para a direita.`
    case 'chaos_no_effect':
      return `${cardName(p.cardCode)} não teve efeito: faltou gente com cartas.`
    case 'choice_made':
      if (p.timedOut) return `O tempo de ${actor} acabou: a escolha foi sorteada.`
      return p.auto ? `${actor} não tinha o que escolher.` : `${actor} escolheu.`
    case 'healed': {
      const drew = Number(p.drew ?? 0)
      const draw = drew > 0 ? ` e comprou ${drew === 1 ? '1 carta' : `${drew} cartas`}` : ''
      return `${actor} recuperou PV (ficou com ${p.hp})${draw}.`
    }
    case 'cards_drawn': {
      const count = Number(p.count ?? 0)
      if (count === 0) return `${actor} não tinha cartas para comprar.`
      return `${actor} comprou ${count === 1 ? '1 carta' : `${count} cartas`}.`
    }
    case 'hands_shuffled':
      return `Rolê no Sítio: ${p.count} cartas de ${p.players} jogadores foram embaralhadas e redistribuídas.`
    case 'hands_swapped':
      return `${actor} trocou a mão inteira com ${name(p.targetPlayerId)}.`
    case 'reaction_played':
      return p.role === 'counter'
        ? `${actor} se defendeu do ataque devolvido com ${cardName(p.cardCode)}.`
        : `${actor} reagiu com ${cardName(p.cardCode)}.`
    case 'response_passed':
      if (p.timedOut) return `O tempo de ${actor} acabou: aceitou.`
      return p.auto ? `${actor} não tinha como reagir: aceitou.` : `${actor} aceitou.`
    case 'turn_timed_out':
      return `O tempo de ${actor} acabou: continua fantasma.`
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
    case 'hangover':
      return `Ressaca da rodada ${p.round}: ${p.damage} de dano em todos os vivos.`
    case 'player_revived':
      return `${actor} ressuscitou com ${p.hp} PV e ${p.drew} cartas!`
    case 'revive_declined':
      return `${actor} preferiu continuar fantasma.`
    case 'ghost_peeked':
      return `${actor} espiou cartas de ${name(p.targetPlayerId)}.`
    case 'card_to_bottom':
      return `Uma carta de ${actor} foi para o fundo do baralho.`
    case 'curse_cast':
      return `${actor} lançou a Maldição da Ressaca: o próximo ataque ao Mais Odiado causa +1.`
    case 'player_removed':
      return `${actor} foi removido por ausência e saiu da disputa.`
    case 'host_changed':
      return `${actor} assumiu como host.`
    case 'game_finished':
      return 'Fim da partida!'
    default:
      return 'Algo aconteceu na mesa.'
  }
}

/** Revelação que só o próprio jogador recebeu. */
export function describePrivateEvent(
  event: PrivateEvent,
  players: ReadonlyMap<string, Participant>,
  catalog: CardCatalog,
): string {
  if (event.kind === 'cards_peeked') {
    const codes = Array.isArray(event.payload.codes) ? (event.payload.codes as string[]) : []
    const who = players.get(String(event.payload.targetPlayerId))?.displayName ?? 'o alvo'
    const names = codes.map((code) => catalog.get(code)?.name ?? code).join(' e ')
    return codes.length > 0
      ? `Só você viu: ${who} tem ${names}.`
      : `Só você viu: ${who} está sem cartas.`
  }
  return 'Você recebeu uma informação secreta.'
}
