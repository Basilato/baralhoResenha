import { toast } from 'sonner'
import { Loader2Icon, ShieldOffIcon } from 'lucide-react'
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import type { CardCatalog } from '@/features/cards/catalog'
import { GameCard } from '@/features/cards/game-card'
import { toFriendlyMessage } from '@/lib/errors'
import { newRequestId, useGameCommand, type GameView, type Participant } from './game-service'

/**
 * Decisão de reação. Fica aberta até a pessoa responder (não fecha ao tocar
 * fora). "Aceitar" sempre existe, para ninguém deduzir quem tem defesa.
 */
export function ReactionDialog({
  game,
  players,
  catalog,
}: {
  game: GameView
  players: ReadonlyMap<string, Participant>
  catalog: CardCatalog
}) {
  const decision = game.myDecision
  const command = useGameCommand(game)

  if (!decision) return null

  const attacker = players.get(decision.actorPlayerId)?.displayName ?? 'Alguém'
  const attackCard = catalog.get(decision.cardCode)?.name ?? 'uma carta'
  const me = game.myPlayerId ? players.get(game.myPlayerId) : undefined
  const fatal = !!me && decision.baseDamage >= me.hp
  const options = game.myHand.filter((item) => decision.eligibleCardIds.includes(item.instanceId))

  const title = {
    target: `${attacker} atacou você!`,
    counter: 'Seu ataque foi devolvido!',
    self: 'A própria carta vai te derrubar!',
  }[decision.role]
  const description = {
    target: `${attackCard}: ${decision.baseDamage} de dano em você.`,
    counter: `O ${attackCard} voltou: ${decision.baseDamage} de dano em você. Só vale defesa simples.`,
    self: `O dano próprio de ${attackCard} (${decision.baseDamage}) vai te eliminar.`,
  }[decision.role]

  const respond = (cardInstanceId?: string) =>
    command.mutate(
      {
        requestId: newRequestId(),
        command: {
          type: 'RESPOND',
          pendingActionId: decision.pendingActionId,
          response: cardInstanceId ? 'REACT' : 'PASS',
          cardInstanceId,
        },
      },
      { onError: (error) => toast.error(toFriendlyMessage(error)) },
    )

  return (
    <AlertDialog open>
      <AlertDialogContent className="max-h-[90svh] overflow-y-auto" data-testid="reaction-dialog">
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>
            {description}
            {fatal && ' Esse golpe é fatal.'}
          </AlertDialogDescription>
        </AlertDialogHeader>

        {options.length > 0 && (
          <div className="flex flex-col gap-2">
            <p className="text-sm font-medium">Você pode reagir com:</p>
            <ul className="flex flex-wrap justify-center gap-3">
              {options.map((item) => {
                const card = catalog.get(item.code)
                if (!card) return null
                return (
                  <li key={item.instanceId} className="flex flex-col items-center gap-2">
                    <GameCard card={card} size="md" />
                    <Button
                      size="sm"
                      disabled={command.isPending}
                      onClick={() => respond(item.instanceId)}
                    >
                      Usar {card.name}
                    </Button>
                  </li>
                )
              })}
            </ul>
          </div>
        )}

        <AlertDialogFooter>
          <Button
            variant={options.length > 0 ? 'outline' : 'default'}
            size="lg"
            className="h-11 w-full"
            disabled={command.isPending}
            onClick={() => respond()}
          >
            {command.isPending ? <Loader2Icon className="animate-spin" /> : <ShieldOffIcon />}
            Aceitar {decision.baseDamage} de dano
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
