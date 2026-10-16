import { useEffect, useRef, useState } from 'react'
import { toast } from 'sonner'
import { CheckIcon, Loader2Icon, ShieldOffIcon } from 'lucide-react'
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
import { cn } from '@/lib/utils'
import { Countdown } from './countdown'
import { useSecondsLeft } from './use-deadline'
import {
  CHOICE_ROLES,
  newRequestId,
  useGameCommand,
  type GameView,
  type MyDecision,
  type Participant,
} from './game-service'

/**
 * Decisão que espera o próprio jogador: reagir a uma jogada ou escolher
 * cartas. Fica aberta até responder (não fecha ao tocar fora).
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
  if (!decision) return null

  return (
    <AlertDialog open>
      <AlertDialogContent className="max-h-[90svh] overflow-y-auto" data-testid="reaction-dialog">
        {CHOICE_ROLES.includes(decision.role) ? (
          <ChoiceForm
            key={decision.pendingActionId + decision.role}
            game={game}
            decision={decision}
            players={players}
            catalog={catalog}
          />
        ) : (
          <ReactionForm
            key={decision.pendingActionId + decision.role}
            game={game}
            decision={decision}
            players={players}
            catalog={catalog}
          />
        )}
      </AlertDialogContent>
    </AlertDialog>
  )
}

type FormProps = {
  game: GameView
  decision: MyDecision
  players: ReadonlyMap<string, Participant>
  catalog: CardCatalog
}

/** Sem defesa: aceita sozinho depois de um tempo ao acaso, como alguém pensando. */
const AUTO_ACCEPT_MIN_MS = 2000
const AUTO_ACCEPT_SPREAD_MS = 3000

/**
 * Reagir ou aceitar. "Aceitar" sempre existe, para ninguém deduzir quem tem
 * defesa: por isso, sem carta que sirva, a resposta automática também espera
 * um tempo ao acaso em vez de sair na hora.
 */
function ReactionForm({ game, decision, players, catalog }: FormProps) {
  const command = useGameCommand(game)
  const sent = useRef(false)
  const [auto] = useState(() => {
    const delay = AUTO_ACCEPT_MIN_MS + Math.random() * AUTO_ACCEPT_SPREAD_MS
    return { at: new Date(Date.now() + delay).toISOString(), delay }
  })
  const autoSeconds = useSecondsLeft(auto.at, 0)
  const actor = players.get(decision.actorPlayerId)?.displayName ?? 'Alguém'
  const card = catalog.get(decision.cardCode)?.name ?? 'uma carta'
  const me = game.myPlayerId ? players.get(game.myPlayerId) : undefined
  const fatal = !!me && decision.baseDamage >= me.hp && decision.role !== 'sabotage_target'
  const options = game.myHand.filter((item) => decision.eligibleCardIds.includes(item.instanceId))

  const { title, description, accept } = {
    target: {
      title: `${actor} atacou você!`,
      description: `${card}: ${decision.baseDamage} de dano em você.`,
      accept: `Aceitar ${decision.baseDamage} de dano`,
    },
    counter: {
      title: 'Seu ataque foi devolvido!',
      description: `O ${card} voltou: ${decision.baseDamage} de dano em você. Só vale defesa simples.`,
      accept: `Aceitar ${decision.baseDamage} de dano`,
    },
    self: {
      title: 'A própria carta vai te derrubar!',
      description: `O dano próprio de ${card} (${decision.baseDamage}) vai te eliminar.`,
      accept: `Aceitar ${decision.baseDamage} de dano`,
    },
    sabotage_target: {
      title: `${actor} jogou ${card} em você!`,
      description: 'Só Evento Raro cancela uma sabotagem.',
      accept: 'Aceitar',
    },
    chaos_target: {
      title: `${actor} jogou ${card} em você!`,
      description: `${decision.baseDamage} de dano de caos: não admite defesa comum.`,
      accept: `Aceitar ${decision.baseDamage} de dano`,
    },
  }[decision.role as 'target' | 'counter' | 'self' | 'sabotage_target' | 'chaos_target']

  const respond = (cardInstanceId?: string) => {
    sent.current = true
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
      {
        onError: (error) => {
          sent.current = false
          toast.error(toFriendlyMessage(error))
        },
      },
    )
  }

  const noDefense = options.length === 0
  const { mutate } = command
  useEffect(() => {
    if (!noDefense) return
    const timer = setTimeout(() => {
      if (sent.current) return
      sent.current = true
      mutate(
        {
          requestId: newRequestId(),
          command: { type: 'RESPOND', pendingActionId: decision.pendingActionId, response: 'PASS' },
        },
        { onError: () => (sent.current = false) },
      )
    }, auto.delay)
    return () => clearTimeout(timer)
  }, [noDefense, auto.delay, decision.pendingActionId, mutate])

  return (
    <>
      <AlertDialogHeader>
        <AlertDialogTitle className="flex items-center justify-between gap-3 text-2xl">
          {title}
          <Countdown deadline={game.responseDeadlineAt} skewMs={game.clockSkewMs} />
        </AlertDialogTitle>
        <AlertDialogDescription>
          {description}
          {fatal && ' Esse golpe é fatal.'}
        </AlertDialogDescription>
      </AlertDialogHeader>

      {noDefense && (
        <p className="text-sm text-muted-foreground" data-testid="auto-accept">
          Nenhuma carta sua serve contra isso. Aceitando sozinho em {autoSeconds ?? 0}s…
        </p>
      )}

      {options.length > 0 && (
        <div className="flex flex-col gap-2">
          <p className="font-heading text-base tracking-wide">Você pode reagir com:</p>
          <ul className="flex flex-wrap justify-center gap-3">
            {options.map((item) => {
              const option = catalog.get(item.code)
              if (!option) return null
              return (
                <li key={item.instanceId} className="flex flex-col items-center gap-2">
                  <GameCard card={option} size="md" />
                  <Button
                    size="sm"
                    disabled={command.isPending}
                    onClick={() => respond(item.instanceId)}
                  >
                    Usar {option.name}
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
          {accept}
        </Button>
      </AlertDialogFooter>
    </>
  )
}

/** Escolher cartas (descarte, passagem ou carta do alvo). Escolhas são secretas. */
function ChoiceForm({ game, decision, players, catalog }: FormProps) {
  const command = useGameCommand(game)
  const [selected, setSelected] = useState<string[]>([])
  const count = decision.choiceCount ?? 1
  const actor = players.get(decision.actorPlayerId)?.displayName ?? 'Alguém'
  const card = catalog.get(decision.cardCode)?.name ?? 'uma carta'
  const target = decision.targetPlayerId ? players.get(decision.targetPlayerId) : undefined
  const me = game.myPlayerId ? players.get(game.myPlayerId) : undefined
  const nextAlive = me ? nextAlivePlayer(game.participants, me.seat) : undefined
  const many = count === 1 ? '1 carta' : `${count} cartas`
  const soloDiscard = catalog.get(decision.cardCode)?.effectCode === 'draw_discard'

  const { title, description, confirm } = {
    actor_pick: {
      title: `Mão de ${target?.displayName ?? 'seu alvo'}`,
      description: `Só você está vendo estas cartas. Escolha 1 para ${target?.displayName ?? 'ele'} descartar.`,
      confirm: 'Descartar esta',
    },
    target_discard: {
      title: `${actor} jogou ${card} em você`,
      description: `Escolha ${many} para descartar.`,
      confirm: `Descartar ${many}`,
    },
    pass_pick: {
      title: `${card}: passe 1 carta`,
      description: `Escolha 1 carta para passar para ${nextAlive?.displayName ?? 'o próximo'}. Todos entregam ao mesmo tempo.`,
      confirm: 'Passar esta',
    },
    discard_pick: {
      title: `${card}: descarte 1 carta`,
      // Só Mais Uma!: só quem jogou escolhe, depois de comprar.
      description: soloDiscard
        ? 'Escolha 1 carta da sua mão para descartar. Pode ser uma das que você acabou de comprar.'
        : 'Escolha 1 carta da sua mão para descartar. Todos escolhem ao mesmo tempo.',
      confirm: 'Descartar esta',
    },
  }[decision.role as 'actor_pick' | 'target_discard' | 'pass_pick' | 'discard_pick']

  const toggle = (id: string) =>
    setSelected((current) => {
      if (current.includes(id)) return current.filter((item) => item !== id)
      if (count === 1) return [id]
      return current.length < count ? [...current, id] : current
    })

  const choose = () =>
    command.mutate(
      {
        requestId: newRequestId(),
        command: {
          type: 'RESPOND',
          pendingActionId: decision.pendingActionId,
          response: 'CHOOSE',
          selectedCardIds: selected,
        },
      },
      { onError: (error) => toast.error(toFriendlyMessage(error)) },
    )

  return (
    <>
      <AlertDialogHeader>
        <AlertDialogTitle className="flex items-center justify-between gap-3 text-2xl">
          {title}
          <Countdown deadline={game.responseDeadlineAt} skewMs={game.clockSkewMs} />
        </AlertDialogTitle>
        <AlertDialogDescription>
          {description} Sem escolha a tempo, o sorteio escolhe por você.
        </AlertDialogDescription>
      </AlertDialogHeader>

      <ul className="flex flex-wrap justify-center gap-3" data-testid="choice-options">
        {decision.options.map((item) => {
          const option = catalog.get(item.code)
          if (!option) return null
          const chosen = selected.includes(item.instanceId)
          return (
            <li key={item.instanceId}>
              <button
                type="button"
                onClick={() => toggle(item.instanceId)}
                aria-pressed={chosen}
                aria-label={`Escolher ${option.name}`}
                className={cn(
                  'rounded-xl transition-transform',
                  chosen && '-translate-y-1 shadow-[0_0_24px_-4px_var(--gold)] ring-3 ring-gold',
                )}
              >
                <GameCard card={option} size="sm" />
              </button>
            </li>
          )
        })}
      </ul>

      <AlertDialogFooter>
        <Button
          size="lg"
          className="h-11 w-full"
          disabled={selected.length !== count || command.isPending}
          onClick={choose}
        >
          {command.isPending ? <Loader2Icon className="animate-spin" /> : <CheckIcon />}
          {confirm} ({selected.length}/{count})
        </Button>
      </AlertDialogFooter>
    </>
  )
}

/** Próximo vivo no sentido dos turnos, dando a volta. */
function nextAlivePlayer(players: Participant[], seat: number) {
  const alive = players.filter((player) => player.alive && player.seat !== seat)
  return alive.find((player) => player.seat > seat) ?? alive[0]
}
