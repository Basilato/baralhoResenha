import type { CardDefinition } from '@/features/cards/catalog'
import type { GameView, Participant } from './game-service'

/** Por que uma carta não pode ser jogada agora (null = pode). */
export function whyNotPlayable(card: CardDefinition, game: GameView, isMyTurn: boolean) {
  if (card.isReaction) return 'Esta carta só é usada como reação, quando você é atacado.'
  if (card.deckType === 'ghost') return 'Cartas do Além são jogadas no turno de fantasma.'
  if (!isMyTurn) return 'Espere a sua vez para jogar.'
  if (game.phase !== 'turn_main') return 'Espere a jogada atual terminar.'
  if (game.actionsUsed >= game.maxActions) return 'Você já usou as 2 ações deste turno.'
  return null
}

/** Sabotagens que mexem na mão do alvo: não faz sentido mirar mão vazia. */
const NEEDS_TARGET_CARDS = new Set([
  'steal_random',
  'inspect_discard',
  'swap_card',
  'force_discard',
])

export type TargetOptions = {
  /** Quantos alvos escolher (0 = carta sem alvo). */
  needed: number
  /** Quem pode ser escolhido. */
  eligible: Participant[]
  /** Elegíveis pela regra, mas sem cartas na mão (mostrados desabilitados). */
  emptyHanded: ReadonlySet<string>
}

/**
 * Alvos que a tela oferece para cada carta. Só orienta a pessoa: o banco
 * valida tudo de novo.
 */
export function targetOptions(card: CardDefinition, game: GameView): TargetOptions {
  const opponents = game.participants.filter(
    (player) => player.alive && player.id !== game.myPlayerId,
  )
  const empty = new Set<string>()

  switch (card.targetRule) {
    case 'self':
    case 'all_alive':
      return { needed: 0, eligible: [], emptyHanded: empty }

    case 'up_to_two_opponents':
      return { needed: Math.min(2, opponents.length), eligible: opponents, emptyHanded: empty }

    case 'opponent_most_cards': {
      const max = Math.max(0, ...opponents.map((player) => player.cardsInHand))
      return {
        needed: 1,
        eligible: opponents.filter((player) => player.cardsInHand === max),
        emptyHanded: empty,
      }
    }

    case 'opponent_highest_hp': {
      const max = Math.max(0, ...opponents.map((player) => player.hp))
      return {
        needed: 1,
        eligible: opponents.filter((player) => player.hp === max),
        emptyHanded: empty,
      }
    }

    default: {
      if (NEEDS_TARGET_CARDS.has(card.effectCode)) {
        for (const player of opponents) if (player.cardsInHand === 0) empty.add(player.id)
      }
      return { needed: 1, eligible: opponents, emptyHanded: empty }
    }
  }
}
