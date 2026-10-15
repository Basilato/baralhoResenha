import { useState } from 'react'
import { toast } from 'sonner'
import { Loader2Icon, SparklesIcon } from 'lucide-react'
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
import { targetOptions, whyNotPlayable } from './play-rules'

export type PlayableCard = { handCard: HandCard; card: CardDefinition }

/**
 * Escolha de alvo, custo e carta de troca para jogar uma carta. As opções
 * só orientam a pessoa; quem valida de verdade é o banco.
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
  const [own, setOwn] = useState<string | null>(null)

  const blocked = whyNotPlayable(card, game, isMyTurn)
  const { needed, eligible, emptyHanded } = targetOptions(card, game)
  const swap = card.effectCode === 'swap_card'
  const otherCards = game.myHand.filter((item) => item.instanceId !== handCard.instanceId)
  const ready =
    targets.length === needed && (!card.discardCost || cost !== null) && (!swap || own !== null)

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
          ownSwapCardId: swap ? own : null,
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
        <GameCard card={card} size={blocked || needed === 0 ? 'lg' : 'md'} />
      </div>

      {blocked ? (
        <p className="text-center text-sm text-muted-foreground">{blocked}</p>
      ) : (
        <div className="flex flex-col gap-4">
          {needed > 0 && (
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-2 text-sm font-medium">
                {needed === 2 ? 'Escolha 2 adversários' : 'Escolha o alvo'}
                {card.targetRule === 'opponent_most_cards' && ' (quem tem mais cartas)'}
                {card.targetRule === 'opponent_highest_hp' && ' (quem tem mais PV)'}
              </legend>
              {eligible.map((player) => {
                const chosen = targets.includes(player.id)
                const empty = emptyHanded.has(player.id)
                const bonus = card.category === 'attack' && player.id === game.leaderPlayerId
                return (
                  <button
                    key={player.id}
                    type="button"
                    disabled={empty}
                    onClick={() => toggleTarget(player.id)}
                    aria-pressed={chosen}
                    className={cn(
                      'flex items-center gap-3 rounded-lg border p-2 text-left transition-colors disabled:opacity-50',
                      chosen ? 'border-primary bg-primary/10' : 'hover:bg-muted',
                    )}
                  >
                    <PlayerAvatar name={player.displayName} className="size-8" />
                    <span className="flex-1">
                      <span className="block font-medium">{player.displayName}</span>
                      <span className="text-xs text-muted-foreground">
                        {player.hp}/{player.maxHp} PV ·{' '}
                        {empty ? 'sem cartas' : `${player.cardsInHand} cartas`}
                      </span>
                    </span>
                    {bonus && (
                      <Badge variant="outline" className="border-cat-attack text-cat-attack">
                        Mais Odiado +1
                      </Badge>
                    )}
                    {card.category === 'attack' && game.markedPlayerIds.includes(player.id) && (
                      <Badge variant="outline" className="border-cat-sabotage text-cat-sabotage">
                        Marcado +2
                      </Badge>
                    )}
                  </button>
                )
              })}
            </fieldset>
          )}

          {swap && (
            <CardPicker
              legend="Escolha a carta que você vai dar em troca"
              cards={otherCards.filter((item) => item.instanceId !== cost)}
              selected={own}
              onSelect={setOwn}
              catalog={catalog}
              empty="Você não tem outra carta para trocar."
            />
          )}

          {card.discardCost && (
            <CardPicker
              legend="Descarte outra carta como custo"
              cards={otherCards.filter((item) => item.instanceId !== own)}
              selected={cost}
              onSelect={setCost}
              catalog={catalog}
              empty="Você não tem outra carta para pagar o custo."
            />
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
            {command.isPending ? <Loader2Icon className="animate-spin" /> : <SparklesIcon />}
            Jogar {card.name}
          </Button>
        </DialogFooter>
      )}
    </>
  )
}

function CardPicker({
  legend,
  cards,
  selected,
  onSelect,
  catalog,
  empty,
}: {
  legend: string
  cards: HandCard[]
  selected: string | null
  onSelect: (id: string) => void
  catalog: CardCatalog
  empty: string
}) {
  return (
    <fieldset className="flex flex-col gap-2">
      <legend className="mb-2 text-sm font-medium">{legend}</legend>
      {cards.length === 0 ? (
        <p className="text-sm text-muted-foreground">{empty}</p>
      ) : (
        <div className="flex flex-wrap gap-2">
          {cards.map((item) => (
            <Button
              key={item.instanceId}
              type="button"
              size="sm"
              variant={selected === item.instanceId ? 'default' : 'outline'}
              aria-pressed={selected === item.instanceId}
              onClick={() => onSelect(item.instanceId)}
            >
              {catalog.get(item.code)?.name ?? item.code}
            </Button>
          ))}
        </div>
      )}
    </fieldset>
  )
}
