import { useState } from 'react'
import { toast } from 'sonner'
import { Loader2Icon, SwordsIcon } from 'lucide-react'
import { PlayerAvatar } from '@/components/player-avatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import type { CardCatalog, CardDefinition } from '@/features/cards/catalog'
import { GameCard } from '@/features/cards/game-card'
import { CATEGORY_LABEL } from '@/lib/constants'
import { toFriendlyMessage } from '@/lib/errors'
import { cn } from '@/lib/utils'
import { newRequestId, useGameCommand, type GameView, type HandCard } from './game-service'
import { whyNotPlayable } from './play-rules'

export type PlayableCard = { handCard: HandCard; card: CardDefinition }

/**
 * Escolha de alvo (e de custo) para jogar uma carta. As opções aqui só
 * orientam a pessoa; quem valida de verdade é o banco.
 */
export function PlayCardDialog({
  playable,
  game,
  isMyTurn,
  catalog,
  onClose,
}: {
  playable: PlayableCard | null
  game: GameView
  isMyTurn: boolean
  catalog: CardCatalog
  onClose: () => void
}) {
  return (
    <Dialog open={playable !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[90svh] max-w-md overflow-y-auto">
        {playable && (
          <PlayCardForm
            // Recomeça a escolha a cada carta aberta.
            key={playable.handCard.instanceId}
            playable={playable}
            game={game}
            isMyTurn={isMyTurn}
            catalog={catalog}
            onClose={onClose}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}

function PlayCardForm({
  playable,
  game,
  isMyTurn,
  catalog,
  onClose,
}: {
  playable: PlayableCard
  game: GameView
  isMyTurn: boolean
  catalog: CardCatalog
  onClose: () => void
}) {
  const { card, handCard } = playable
  const command = useGameCommand(game)
  const [targets, setTargets] = useState<string[]>([])
  const [cost, setCost] = useState<string | null>(null)

  const blocked = whyNotPlayable(card, game, isMyTurn)
  const opponents = game.participants.filter(
    (player) => player.alive && player.id !== game.myPlayerId,
  )
  const maxHand = Math.max(0, ...opponents.map((player) => player.cardsInHand))
  const eligible =
    card.targetRule === 'opponent_most_cards'
      ? opponents.filter((player) => player.cardsInHand === maxHand)
      : opponents
  const needed = card.targetRule === 'up_to_two_opponents' ? Math.min(2, opponents.length) : 1
  const costOptions = game.myHand.filter((item) => item.instanceId !== handCard.instanceId)
  const ready = targets.length === needed && (!card.discardCost || cost !== null)

  const toggleTarget = (playerId: string) =>
    setTargets((current) => {
      if (current.includes(playerId)) return current.filter((id) => id !== playerId)
      if (needed === 1) return [playerId]
      return current.length < needed ? [...current, playerId] : current
    })

  const play = () =>
    command.mutate(
      {
        requestId: newRequestId(),
        command: {
          type: 'PLAY_CARD',
          cardInstanceId: handCard.instanceId,
          targetPlayerIds: targets,
          discardCostCardId: card.discardCost ? cost : null,
        },
      },
      {
        onSuccess: onClose,
        onError: (error) => toast.error(toFriendlyMessage(error)),
      },
    )

  return (
    <>
      <DialogHeader>
        <DialogTitle>{card.name}</DialogTitle>
        <DialogDescription className="flex flex-wrap items-center gap-1.5">
          <Badge variant="secondary">{CATEGORY_LABEL[card.category]}</Badge>
          {card.isReaction && <Badge variant="outline">Reação</Badge>}
        </DialogDescription>
      </DialogHeader>

      <div className="flex justify-center">
        <GameCard card={card} size={blocked ? 'lg' : 'md'} />
      </div>

      {blocked ? (
        <p className="text-center text-sm text-muted-foreground">{blocked}</p>
      ) : (
        <div className="flex flex-col gap-4">
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-2 text-sm font-medium">
              {needed === 2 ? 'Escolha 2 adversários' : 'Escolha o alvo'}
              {card.targetRule === 'opponent_most_cards' && ' (quem tem mais cartas)'}
            </legend>
            {eligible.map((player) => {
              const chosen = targets.includes(player.id)
              const bonus = player.id === game.leaderPlayerId
              return (
                <button
                  key={player.id}
                  type="button"
                  onClick={() => toggleTarget(player.id)}
                  aria-pressed={chosen}
                  className={cn(
                    'flex items-center gap-3 rounded-lg border p-2 text-left transition-colors',
                    chosen ? 'border-primary bg-primary/10' : 'hover:bg-muted',
                  )}
                >
                  <PlayerAvatar name={player.displayName} className="size-8" />
                  <span className="flex-1">
                    <span className="block font-medium">{player.displayName}</span>
                    <span className="text-xs text-muted-foreground">
                      {player.hp}/{player.maxHp} PV · {player.cardsInHand} cartas
                    </span>
                  </span>
                  {bonus && (
                    <Badge variant="outline" className="border-cat-attack text-cat-attack">
                      Mais Odiado +1
                    </Badge>
                  )}
                </button>
              )
            })}
          </fieldset>

          {card.discardCost && (
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-2 text-sm font-medium">Descarte outra carta como custo</legend>
              {costOptions.length === 0 ? (
                <p className="text-sm text-muted-foreground">
                  Você não tem outra carta para pagar o custo.
                </p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {costOptions.map((item) => {
                    const def = catalog.get(item.code)
                    return (
                      <Button
                        key={item.instanceId}
                        type="button"
                        size="sm"
                        variant={cost === item.instanceId ? 'default' : 'outline'}
                        aria-pressed={cost === item.instanceId}
                        onClick={() => setCost(item.instanceId)}
                      >
                        {def?.name ?? item.code}
                      </Button>
                    )
                  })}
                </div>
              )}
            </fieldset>
          )}
        </div>
      )}

      {!blocked && (
        <DialogFooter>
          <Button
            size="lg"
            className="h-11 w-full"
            disabled={!ready || command.isPending}
            onClick={play}
          >
            {command.isPending ? <Loader2Icon className="animate-spin" /> : <SwordsIcon />}
            Jogar {card.name}
          </Button>
        </DialogFooter>
      )}
    </>
  )
}
