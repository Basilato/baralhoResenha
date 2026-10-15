import { useState } from 'react'
import { Navigate, useNavigate, useParams } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { toast } from 'sonner'
import { CrownIcon, GhostIcon, LayersIcon, WifiOffIcon, XCircleIcon } from 'lucide-react'
import { ConfirmAction } from '@/components/confirm-action'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { PlayerAvatar } from '@/components/player-avatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Progress } from '@/components/ui/progress'
import { useAuth } from '@/features/auth/auth-context'
import { useCardCatalog, type CardCatalog, type CardDefinition } from '@/features/cards/catalog'
import { CardBack, GameCard } from '@/features/cards/game-card'
import { CardDetailsDialog } from '@/features/cards/card-details-dialog'
import { closeRoom } from '@/features/rooms/rooms-service'
import { RoomUnavailable } from '@/features/rooms/room-unavailable'
import { useGameChannel } from '@/features/rooms/use-room'
import { HAND_LIMIT } from '@/lib/constants'
import { toFriendlyMessage } from '@/lib/errors'
import { cn } from '@/lib/utils'
import { useGameView, type GameView, type Participant } from './game-service'

export function GamePage() {
  const { gameId } = useParams<{ gameId: string }>()
  const channel = useGameChannel(gameId)
  const game = useGameView(gameId, channel.status)
  const catalog = useCardCatalog(game.data?.cardSetVersion)

  if (game.isPending || catalog.isPending) return <FullPageSpinner />
  if (!game.data) return <RoomUnavailable error={game.error} />
  if (catalog.isError) return <RoomUnavailable error={catalog.error} />
  if (game.data.status === 'lobby') return <Navigate to={`/sala/${game.data.gameId}`} replace />
  if (game.data.status !== 'playing') return <RoomUnavailable closed />

  return (
    <Table
      game={game.data}
      catalog={catalog.data.byCode}
      onlineUserIds={channel.onlineUserIds}
      offline={channel.status === 'offline'}
    />
  )
}

function Table({
  game,
  catalog,
  onlineUserIds,
  offline,
}: {
  game: GameView
  catalog: CardCatalog
  onlineUserIds: ReadonlySet<string>
  offline: boolean
}) {
  const { user } = useAuth()
  const navigate = useNavigate()
  const [selected, setSelected] = useState<CardDefinition | null>(null)
  const isHost = game.hostUserId === user?.id
  const discardTop = game.mainDiscardTop ? catalog.get(game.mainDiscardTop) : undefined

  const close = useMutation({
    mutationFn: () => closeRoom(game.gameId),
    onSuccess: () => {
      toast.success('Partida encerrada.')
      navigate('/lobby', { replace: true })
    },
    onError: (error) => toast.error(toFriendlyMessage(error)),
  })

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-heading text-2xl font-black tracking-tight">
            Rodada {game.round} de {game.maxRounds}
          </h1>
          <p className="text-sm text-muted-foreground">
            Turnos e jogadas chegam na próxima fase. Toque numa carta para ver os detalhes.
          </p>
        </div>
        <div className="flex items-center gap-2">
          {offline && (
            <Badge variant="outline" className="gap-1 text-muted-foreground">
              <WifiOffIcon className="size-3" />
              Reconectando…
            </Badge>
          )}
          {isHost && (
            <ConfirmAction
              trigger={
                <Button variant="ghost" size="sm" className="text-destructive">
                  <XCircleIcon />
                  Encerrar partida
                </Button>
              }
              title="Encerrar a partida?"
              description="Use só se o jogo travar. Ninguém vence e todo mundo volta para o lobby."
              confirmLabel="Encerrar"
              destructive
              onConfirm={() => close.mutate()}
            />
          )}
        </div>
      </div>

      <section aria-label="Jogadores" className="min-w-0">
        <ul className="relative -mx-4 flex snap-x gap-3 overflow-x-auto px-4 pb-2 sm:mx-0 sm:grid sm:grid-cols-2 sm:overflow-visible sm:px-0 lg:grid-cols-4">
          {game.participants.map((player) => (
            <PlayerPanel
              key={player.id}
              player={player}
              isMe={player.id === game.myPlayerId}
              online={onlineUserIds.has(player.userId)}
            />
          ))}
        </ul>
      </section>

      <section
        aria-label="Mesa"
        className="flex items-end justify-center gap-6 rounded-2xl border bg-muted/40 p-4 sm:gap-10"
      >
        <Pile label="Baralho" count={game.mainDeckCount} testId="main-deck-count">
          <CardBack deckType="main" size="sm" />
        </Pile>
        <Pile label="Descarte" count={game.mainDiscardCount} testId="main-discard-count">
          {discardTop ? (
            <button
              type="button"
              onClick={() => setSelected(discardTop)}
              aria-label={`Ver ${discardTop.name}`}
            >
              <GameCard card={discardTop} size="sm" />
            </button>
          ) : (
            <div className="flex aspect-card w-24 items-center justify-center rounded-lg border-2 border-dashed text-xs text-muted-foreground">
              vazio
            </div>
          )}
        </Pile>
        <Pile label="Além" count={game.ghostDeckCount} testId="ghost-deck-count">
          <CardBack deckType="ghost" size="sm" />
        </Pile>
      </section>

      <section aria-labelledby="my-hand-title" className="flex min-w-0 flex-col gap-2">
        <h2 id="my-hand-title" className="flex items-center gap-2 font-heading text-lg font-bold">
          Sua mão
          <Badge variant="secondary" data-testid="my-hand-count">
            {game.myHand.length}/{HAND_LIMIT}
          </Badge>
        </h2>
        {game.myHand.length === 0 ? (
          <p className="text-sm text-muted-foreground">Sem cartas na mão.</p>
        ) : (
          <ul
            className="relative -mx-4 flex snap-x gap-3 overflow-x-auto px-4 pt-1 pb-3"
            data-testid="my-hand"
          >
            {game.myHand.map((handCard) => {
              const card = catalog.get(handCard.code)
              if (!card) return null
              return (
                <li key={handCard.instanceId} className="snap-start">
                  <button
                    type="button"
                    className="rounded-xl transition-transform hover:-translate-y-1 focus-visible:-translate-y-1 focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none"
                    onClick={() => setSelected(card)}
                    aria-label={`Ver ${card.name}`}
                  >
                    <GameCard card={card} size="md" />
                  </button>
                </li>
              )
            })}
          </ul>
        )}
      </section>

      <CardDetailsDialog card={selected} onOpenChange={(open) => !open && setSelected(null)} />
    </div>
  )
}

function PlayerPanel({
  player,
  isMe,
  online,
}: {
  player: Participant
  isMe: boolean
  online: boolean
}) {
  return (
    <li
      className={cn(
        'flex min-w-56 snap-start flex-col gap-2 rounded-xl border bg-card p-3',
        isMe && 'border-primary/50 ring-1 ring-primary/30',
        !player.alive && 'opacity-70',
      )}
      data-testid="table-player"
    >
      <div className="flex items-center gap-2">
        <PlayerAvatar name={player.displayName} online={online} className="size-8" />
        <p className="flex min-w-0 flex-1 items-center gap-1 font-medium">
          {player.isHost && (
            <CrownIcon className="size-4 shrink-0 text-amber-500" aria-label="Host" />
          )}
          <span className="truncate">{player.displayName}</span>
          {isMe && <span className="shrink-0 text-xs text-muted-foreground">(você)</span>}
        </p>
        <span
          className="flex shrink-0 items-center gap-1 text-xs text-muted-foreground"
          title="Cartas na mão"
          data-testid="cards-in-hand"
        >
          <LayersIcon className="size-3.5" aria-hidden />
          {player.cardsInHand}
          <span className="sr-only">cartas na mão</span>
        </span>
      </div>
      {player.alive ? (
        <div className="flex items-center gap-2">
          <Progress
            value={(player.hp / Math.max(player.maxHp, 1)) * 100}
            className="h-2 flex-1"
            aria-label={`Vida de ${player.displayName}`}
          />
          <span className="w-14 text-right text-xs font-semibold tabular-nums">
            {player.hp}/{player.maxHp} PV
          </span>
        </div>
      ) : (
        <p className="flex items-center gap-1 text-xs text-cat-ghost">
          <GhostIcon className="size-3.5" aria-hidden />
          Fantasma · {player.ghostTokens}/3 fichas
        </p>
      )}
    </li>
  )
}

function Pile({
  label,
  count,
  testId,
  children,
}: {
  label: string
  count: number
  testId: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col items-center gap-1.5">
      {children}
      <p className="text-xs text-muted-foreground">
        {label} ·{' '}
        <span className="font-semibold tabular-nums" data-testid={testId}>
          {count}
        </span>
      </p>
    </div>
  )
}
