import type { CardDefinition } from '@/features/cards/catalog'
import type { GameView } from './game-service'

/** Por que uma carta não pode ser jogada agora (null = pode). */
export function whyNotPlayable(card: CardDefinition, game: GameView, isMyTurn: boolean) {
  if (card.isReaction) return 'Esta carta só é usada como reação, quando você é atacado.'
  if (card.category !== 'attack') return 'Esta carta ainda não pode ser jogada nesta versão.'
  if (!isMyTurn) return 'Espere a sua vez para jogar.'
  if (game.phase !== 'turn_main') return 'Espere a jogada atual terminar.'
  if (game.actionsUsed >= game.maxActions) return 'Você já usou as 2 ações deste turno.'
  return null
}
