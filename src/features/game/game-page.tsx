import { useState } from 'react'
import { Link, Navigate, useNavigate, useParams } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  BombIcon,
  CheckIcon,
  CircleIcon,
  CrosshairIcon,
  CrownIcon,
  EyeOffIcon,
  FlagIcon,
  FlameIcon,
  GhostIcon,
  HeartCrackIcon,
  HeartPulseIcon,
  HourglassIcon,
  LayersIcon,
  Loader2Icon,
  RotateCcwIcon,
  ShieldIcon,
  SparklesIcon,
  TargetIcon,
  TrophyIcon,
  UserMinusIcon,
  Volume2Icon,
  VolumeXIcon,
  WifiOffIcon,
  XCircleIcon,
} from 'lucide-react'
import { ConfirmAction } from '@/components/confirm-action'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { PlayerAvatar } from '@/components/player-avatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Progress } from '@/components/ui/progress'
import { useAuth } from '@/features/auth/auth-context'
import { useCardCatalog, type CardCatalog, type CardDefinition } from '@/features/cards/catalog'
import { CardBack, GameCard } from '@/features/cards/game-card'
import { CardDetailsDialog } from '@/features/cards/card-details-dialog'
import { CATEGORY_ICON } from '@/features/cards/category-icons'
import { closeRoom, createRematch } from '@/features/rooms/rooms-service'
import { RoomUnavailable } from '@/features/rooms/room-unavailable'
import { QuickRulesButton } from '@/features/rules/quick-rules'
import { useGameChannel } from '@/features/rooms/use-room'
import type { CardCategoryId } from '@/lib/constants'
import { isAppError, toFriendlyMessage } from '@/lib/errors'
import { setPreferences, usePreferences } from '@/lib/preferences'
import { cn } from '@/lib/utils'
import { describeEvent, describePrivateEvent } from './event-messages'
import { eventQuip } from './event-quips'
import { PlayCardDialog, type PlayableCard } from './play-card-dialog'
import { whyNotPlayable } from './play-rules'
import { useTableEffects, type PlayerEffect, type Spotlight } from './use-table-effects'
import { useTableSounds } from './use-table-sounds'
import { ReactionDialog } from './reaction-dialog'
import {
  newRequestId,
  useGameCommand,
  useGameView,
  type GameView,
  type HandCard,
  type Participant,
  type Presence,
  type GameEvent,
  type ResponseRole,
} from './game-service'

export function GamePage() {
  const { gameId } = useParams<{ gameId: string }>()
  const channel = useGameChannel(gameId)
  const game = useGameView(gameId, channel.status)
  const catalog = useCardCatalog(game.data?.cardSetVersion)

  if (game.isPending || catalog.isPending) return <FullPageSpinner />
  if (!game.data) return <RoomUnavailable error={game.error} />
  if (catalog.isError) return <RoomUnavailable error={catalog.error} />
  if (game.data.status === 'lobby') return <Navigate to={`/sala/${game.data.gameId}`} replace />
  if (game.data.status === 'cancelled') return <RoomUnavailable closed />

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
  const [playing, setPlaying] = useState<PlayableCard | null>(null)

  const players = new Map(game.participants.map((player) => [player.id, player]))
  const me = game.myPlayerId ? players.get(game.myPlayerId) : undefined
  const active = game.activePlayerId ? players.get(game.activePlayerId) : undefined
  const isHost = game.hostUserId === user?.id
  const isMyTurn = game.status === 'playing' && !!me && me.id === game.activePlayerId
  const discardTop = game.mainDiscardTop ? catalog.get(game.mainDiscardTop) : undefined
  const fx = useTableEffects(game, catalog)
  // A partir de mim, na ordem dos lugares: é a ordem em que a vez passa.
  const bySeat = [...game.participants].sort((a, b) => a.seat - b.seat)
  const myIndex = Math.max(
    0,
    bySeat.findIndex((player) => player.id === game.myPlayerId),
  )
  const seated = [...bySeat.slice(myIndex), ...bySeat.slice(0, myIndex)]
  // Mesa cheia: painéis menores para caber todo mundo sem empurrar a mão.
  const compact = game.participants.length > 5
  useTableSounds(fx, isMyTurn, game.status === 'finished')
  const targetedIds = new Set(
    game.pendingAction?.responses
      .filter((response) => TARGET_ROLES.includes(response.role))
      .map((response) => response.playerId),
  )
  const awaitingIds = new Set(
    game.pendingAction?.responses
      .filter((response) => !response.responded)
      .map((response) => response.playerId),
  )

  const close = useMutation({
    mutationFn: () => closeRoom(game.gameId),
    onSuccess: () => {
      toast.success('Partida encerrada.')
      navigate('/lobby', { replace: true })
    },
    onError: (error) => toast.error(toFriendlyMessage(error)),
  })

  return (
    <div className={cn('flex min-w-0 flex-col gap-6', isMyTurn && 'max-sm:pb-20')}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="font-heading text-xl font-black tracking-tight sm:text-2xl">
            Rodada {game.round} de {game.maxRounds}
          </h1>
          {game.status === 'playing' && (
            <p className="text-sm text-muted-foreground" data-testid="turn-status">
              {isMyTurn ? 'Sua vez!' : `Vez de ${active?.displayName ?? '…'}`}
            </p>
          )}
        </div>
        <div className="flex items-center gap-2">
          <QuickRulesButton />
          <SoundToggle />
          {game.curseActive && game.status === 'playing' && (
            <Badge variant="outline" className="border-cat-ghost text-cat-ghost">
              Maldição da Ressaca ativa
            </Badge>
          )}
          {offline && (
            <Badge variant="outline" className="gap-1 text-muted-foreground">
              <WifiOffIcon className="size-3" />
              Reconectando…
            </Badge>
          )}
          {isHost && game.status === 'playing' && (
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

      {game.status === 'finished' && game.result && <ResultPanel game={game} players={players} />}

      {game.status === 'playing' && !isHost && hostAway(game) && <ClaimHostBanner game={game} />}

      {game.pendingAction && <PendingBanner game={game} players={players} catalog={catalog} />}

      {/* Desktop: jogadores e mesa à esquerda, histórico ao lado; mão embaixo, larga.
          Celular: uma coluna, com o histórico por último. */}
      <div className="grid min-w-0 gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div className="flex min-w-0 flex-col gap-4">
          <section aria-label="Jogadores" className="min-w-0">
            <ul
              className={cn(
                'relative -mx-4 flex snap-x gap-2 overflow-x-auto px-4 pb-2 sm:mx-0 sm:grid sm:gap-3 sm:overflow-visible sm:px-0',
                compact
                  ? 'sm:grid-cols-[repeat(auto-fill,minmax(11rem,1fr))]'
                  : 'sm:grid-cols-[repeat(auto-fill,minmax(14rem,1fr))]',
              )}
            >
              {seated.map((player) => (
                <PlayerPanel
                  key={player.id}
                  player={player}
                  compact={compact}
                  isMe={player.id === game.myPlayerId}
                  isActive={game.status === 'playing' && player.id === game.activePlayerId}
                  isLeader={player.id === game.leaderPlayerId}
                  isMarked={game.markedPlayerIds.includes(player.id)}
                  isTargeted={targetedIds.has(player.id)}
                  isAwaiting={awaitingIds.has(player.id)}
                  effects={fx.byPlayer.get(player.id) ?? NO_EFFECTS}
                  online={onlineUserIds.has(player.userId)}
                  presence={game.presence.find((item) => item.playerId === player.id)}
                  absenceLimit={game.absenceLimitSeconds}
                  canRemove={isHost && game.status === 'playing' && player.id !== game.myPlayerId}
                  game={game}
                />
              ))}
            </ul>
          </section>

          <section
            aria-label="Mesa"
            className={cn(
              'flex items-end justify-center gap-6 rounded-2xl border bg-muted/40 p-3 transition-colors sm:gap-10 sm:p-4',
              // Maldição da Ressaca: a mesa fica tomada pela névoa do Além.
              game.curseActive &&
                game.status === 'playing' &&
                'border-cat-ghost/40 bg-linear-to-t from-cat-ghost/25 to-cat-ghost/5',
            )}
          >
            <Pile label="Baralho" count={game.mainDeckCount} testId="main-deck-count">
              {/* A key nova reinicia o "pulo" do monte a cada compra. */}
              <div key={fx.deckDrawKey} className={cn(fx.deckDrawKey > 0 && 'animate-deck-bump')}>
                <CardBack deckType="main" size="sm" className={PILE_CARD} />
              </div>
            </Pile>
            <Pile label="Descarte" count={game.mainDiscardCount} testId="main-discard-count">
              {discardTop ? (
                <button
                  type="button"
                  onClick={() => setSelected(discardTop)}
                  aria-label={`Ver ${discardTop.name}`}
                >
                  <GameCard card={discardTop} size="sm" className={PILE_CARD} />
                </button>
              ) : (
                <div className="flex aspect-card w-16 items-center justify-center rounded-lg border-2 border-dashed text-xs text-muted-foreground sm:w-24">
                  vazio
                </div>
              )}
            </Pile>
            <Pile label="Além" count={game.ghostDeckCount} testId="ghost-deck-count">
              <CardBack deckType="ghost" size="sm" className={PILE_CARD} />
            </Pile>
          </section>
        </div>

        <div className="min-w-0 max-lg:order-last lg:relative">
          <EventLog
            game={game}
            players={players}
            catalog={catalog}
            className="lg:absolute lg:inset-0"
          />
        </div>

        {me && (
          <MyArea
            // Recomeça a seleção de descarte a cada turno.
            key={`${game.round}-${game.activePlayerId}`}
            game={game}
            me={me}
            isMyTurn={isMyTurn}
            catalog={catalog}
            drawnIds={fx.drawnIds}
            className="lg:col-span-2"
            onOpenCard={(handCard, card) => setPlaying({ handCard, card })}
          />
        )}
      </div>

      {fx.spotlight && (
        <CardSpotlight key={fx.spotlight.id} spotlight={fx.spotlight} catalog={catalog} />
      )}

      <PlayCardDialog
        playable={playing}
        game={game}
        isMyTurn={isMyTurn}
        catalog={catalog}
        onClose={() => setPlaying(null)}
      />
      <ReactionDialog game={game} players={players} catalog={catalog} />

      <CardDetailsDialog card={selected} onOpenChange={(open) => !open && setSelected(null)} />
    </div>
  )
}

/** Minha mão (ou mão do Além) e o controle do turno. */
function MyArea({
  game,
  me,
  isMyTurn,
  catalog,
  drawnIds,
  className,
  onOpenCard,
}: {
  game: GameView
  me: Participant
  isMyTurn: boolean
  catalog: CardCatalog
  /** Cartas recém-compradas: entram na mão com animação. */
  drawnIds: ReadonlySet<string>
  className?: string
  onOpenCard: (handCard: HandCard, card: CardDefinition) => void
}) {
  const command = useGameCommand(game)
  const [discarding, setDiscarding] = useState<ReadonlySet<string>>(new Set())
  // O limite de mão só vale ao encerrar: durante a vez dá para jogar com 9.
  const [endingTurn, setEndingTurn] = useState(false)

  const ghost = !me.alive
  const hand = ghost ? game.myGhostHand : game.myHand
  const limit = ghost ? game.ghostHandLimit : game.handLimit
  const excess = Math.max(0, hand.length - limit)
  const mustDiscard = isMyTurn && excess > 0 && endingTurn
  const ready = discarding.size === excess

  const cancelEnding = () => {
    setEndingTurn(false)
    setDiscarding(new Set())
  }

  const toggle = (instanceId: string) =>
    setDiscarding((current) => {
      const next = new Set(current)
      if (next.has(instanceId)) next.delete(instanceId)
      else if (next.size < excess) next.add(instanceId)
      return next
    })

  const endTurn = () =>
    command.mutate(
      {
        requestId: newRequestId(),
        command: { type: 'END_TURN', discardCardIds: [...discarding] },
      },
      {
        onError: (error) => {
          toast.error(toFriendlyMessage(error))
          if (isAppError(error, 'VERSION_CONFLICT')) setDiscarding(new Set())
        },
      },
    )

  return (
    <section
      aria-labelledby="my-hand-title"
      className={cn('flex min-w-0 flex-col gap-3', className)}
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 id="my-hand-title" className="flex items-center gap-2 font-heading text-lg font-bold">
          {ghost ? 'Suas cartas do Além' : 'Sua mão'}
          <Badge variant={excess > 0 ? 'destructive' : 'secondary'} data-testid="my-hand-count">
            {hand.length}/{limit}
          </Badge>
        </h2>

        {isMyTurn && (
          // No celular, a barra fica presa embaixo da tela durante a sua vez.
          <div className="flex flex-wrap items-center gap-2 max-sm:fixed max-sm:inset-x-0 max-sm:bottom-0 max-sm:z-10 max-sm:justify-between max-sm:border-t max-sm:bg-background/95 max-sm:p-3 max-sm:backdrop-blur">
            <span className="text-sm text-muted-foreground" data-testid="actions-left">
              {ghost
                ? `Carta do Além: ${game.actionsUsed}/${game.maxGhostActions}`
                : `Ações: ${game.actionsUsed}/${game.maxActions}`}
            </span>
            {mustDiscard && (
              <Button variant="ghost" className="h-11" onClick={cancelEnding}>
                Cancelar
              </Button>
            )}
            <Button
              size="lg"
              className="h-11"
              disabled={
                command.isPending ||
                game.phase === 'awaiting_reactions' ||
                game.phase === 'ghost_decision' ||
                (mustDiscard && !ready)
              }
              onClick={excess > 0 && !endingTurn ? () => setEndingTurn(true) : endTurn}
            >
              {command.isPending ? <Loader2Icon className="animate-spin" /> : <CheckIcon />}
              {mustDiscard ? `Descartar ${excess} e encerrar` : 'Encerrar turno'}
            </Button>
          </div>
        )}
      </div>

      {isMyTurn && game.phase === 'ghost_decision' && <ReviveChoice game={game} />}

      {mustDiscard && (
        <p className="rounded-lg border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
          Você está com {hand.length} cartas. Toque em{' '}
          {excess === 1 ? '1 carta' : `${excess} cartas`} para descartar antes de encerrar (
          {discarding.size}/{excess}).
        </p>
      )}

      {hand.length === 0 ? (
        <p className="text-sm text-muted-foreground">Sem cartas na mão.</p>
      ) : (
        <ul
          className="relative -mx-4 flex snap-x gap-3 overflow-x-auto px-4 pt-2 pb-3"
          data-testid="my-hand"
        >
          {hand.map((handCard, index) => {
            const card = catalog.get(handCard.code)
            // Na sua vez, destaca o que dá para jogar agora e apaga o resto.
            const blockedReason =
              card && isMyTurn && !mustDiscard ? whyNotPlayable(card, game, true) : undefined
            return (
              <HandItem
                key={handCard.instanceId}
                handCard={handCard}
                card={card}
                playable={blockedReason === null}
                blockedReason={blockedReason ?? undefined}
                drawnDelay={
                  drawnIds.has(handCard.instanceId)
                    ? (index - hand.findIndex((item) => drawnIds.has(item.instanceId))) * 120
                    : undefined
                }
                selectable={mustDiscard}
                selected={discarding.has(handCard.instanceId)}
                onSelect={() => toggle(handCard.instanceId)}
                onOpen={onOpenCard}
              />
            )
          })}
        </ul>
      )}
    </section>
  )
}

function HandItem({
  handCard,
  card,
  playable,
  blockedReason,
  drawnDelay,
  selectable,
  selected,
  onSelect,
  onOpen,
}: {
  handCard: HandCard
  card: CardDefinition | undefined
  /** Pode ser jogada agora (só na sua vez). */
  playable: boolean
  /** Por que não pode ser jogada agora (só na sua vez). */
  blockedReason?: string
  /** Recém-comprada: atraso (ms) da animação de entrada, para entrar em sequência. */
  drawnDelay?: number
  selectable: boolean
  selected: boolean
  onSelect: () => void
  onOpen: (handCard: HandCard, card: CardDefinition) => void
}) {
  if (!card) return null
  return (
    <li
      className={cn('snap-start', drawnDelay !== undefined && 'animate-card-draw')}
      style={drawnDelay ? { animationDelay: `${drawnDelay}ms` } : undefined}
    >
      <button
        type="button"
        className={cn(
          'relative rounded-xl transition-transform focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none',
          !selectable && 'hover:-translate-y-1 focus-visible:-translate-y-1',
          playable && 'shadow-[0_0_0.9em_var(--cat)] ring-2 ring-(--cat)',
          blockedReason && 'opacity-60 saturate-[0.35] hover:opacity-90 hover:saturate-100',
          selected && '-translate-y-2 opacity-60 ring-3 ring-destructive',
        )}
        style={{ '--cat': `var(--cat-${card.category})` } as React.CSSProperties}
        title={blockedReason}
        data-playable={playable || undefined}
        onClick={() => (selectable ? onSelect() : onOpen(handCard, card))}
        aria-label={selectable ? `Descartar ${card.name}` : `Ver ${card.name}`}
        aria-pressed={selectable ? selected : undefined}
        data-instance={handCard.instanceId}
      >
        <GameCard card={card} size="md" />
        {selected && (
          <span className="absolute inset-x-0 top-1/2 mx-auto w-fit -translate-y-1/2 rounded-full bg-destructive px-2 py-0.5 text-xs font-bold text-white">
            Descartar
          </span>
        )}
      </button>
    </li>
  )
}

function PlayerPanel({
  player,
  compact,
  isMe,
  isActive,
  isLeader,
  isMarked,
  isTargeted,
  isAwaiting,
  effects,
  online,
  presence,
  absenceLimit,
  canRemove,
  game,
}: {
  player: Participant
  /** Mesa cheia ou tela pequena: painel enxuto. */
  compact: boolean
  isMe: boolean
  isActive: boolean
  isLeader: boolean
  isMarked: boolean
  /** Alvo da jogada que está esperando resposta. */
  isTargeted: boolean
  /** A jogada pendente espera uma resposta desta pessoa. */
  isAwaiting: boolean
  /** Efeitos passageiros: dano, cura, golpe, morte e volta. */
  effects: readonly PlayerEffect[]
  online: boolean
  presence: Presence | undefined
  absenceLimit: number
  canRemove: boolean
  game: GameView
}) {
  const command = useGameCommand(game)
  const quit = presence?.quit ?? false
  const away = presence && !quit ? presence.secondsAway : 0
  const removable = canRemove && !quit && away > absenceLimit
  const hpRatio = player.hp / Math.max(player.maxHp, 1)
  const remove = () =>
    command.mutate(
      { requestId: newRequestId(), command: { type: 'REMOVE_ABSENT', playerId: player.id } },
      { onError: (error) => toast.error(toFriendlyMessage(error)) },
    )

  return (
    <li
      className={cn(
        'relative flex min-w-38 snap-start flex-col gap-2 overflow-hidden rounded-xl border bg-card p-2.5 transition-shadow sm:min-w-0 sm:p-3',
        compact && 'gap-1.5 sm:p-2.5',
        isMe && 'border-primary/50',
        isLeader && player.alive && 'bg-linear-to-br from-cat-attack/12 to-card to-60%',
        !player.alive && 'border-cat-ghost/40 bg-linear-to-br from-cat-ghost/20 to-card to-70%',
        isActive && 'bg-primary/5 shadow-md ring-2 ring-primary',
        isTargeted && 'animate-target-pulse border-cat-attack',
        effects.some((effect) => effect.kind === 'damage') && 'animate-shake',
      )}
      data-testid="table-player"
      data-active={isActive || undefined}
      data-targeted={isTargeted || undefined}
    >
      {!player.alive && !quit && (
        <GhostIcon
          className="pointer-events-none absolute -right-3 -bottom-3 size-20 text-cat-ghost opacity-15"
          aria-hidden
        />
      )}
      {effects.map((effect) => (
        <EffectOverlay key={effect.id} effect={effect} />
      ))}
      <div className="flex items-center gap-2">
        <PlayerAvatar
          name={player.displayName}
          online={online}
          className={compact ? 'size-7 text-xs' : 'size-8'}
        />
        <p className="flex min-w-0 flex-1 items-center gap-1 font-medium">
          {player.isHost && (
            <CrownIcon className="size-4 shrink-0 text-amber-500" aria-label="Host" />
          )}
          <span className={cn('truncate', compact && 'text-sm')}>{player.displayName}</span>
          {isMe && (
            // No celular a borda já destaca o próprio painel.
            <span className="shrink-0 text-xs text-muted-foreground max-sm:sr-only">(você)</span>
          )}
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
      {(isActive || isLeader || isMarked || isTargeted || isAwaiting) && (
        <div className="flex flex-wrap gap-1">
          {isActive && <Badge className="h-5">Jogando</Badge>}
          {isTargeted && (
            <Badge className="h-5 gap-1 bg-cat-attack text-white">
              <CrosshairIcon className="size-3" aria-hidden />
              Na mira
            </Badge>
          )}
          {isAwaiting && (
            <Badge variant="outline" className="h-5 gap-1">
              <HourglassIcon className="size-3" aria-hidden />
              Respondendo
            </Badge>
          )}
          {isLeader && (
            <Badge variant="outline" className="h-5 gap-1 border-cat-attack text-cat-attack">
              <FlameIcon className="size-3" aria-hidden />
              Mais Odiado
            </Badge>
          )}
          {isMarked && (
            <Badge variant="outline" className="h-5 gap-1 border-cat-sabotage text-cat-sabotage">
              <TargetIcon className="size-3" aria-hidden />
              Marcado +2
            </Badge>
          )}
        </div>
      )}
      {quit ? (
        <p className="text-xs text-muted-foreground">Desistiu (removido por ausência)</p>
      ) : player.alive ? (
        <div className="flex items-center gap-2">
          <Progress
            value={hpRatio * 100}
            className={cn(
              'h-2 flex-1',
              hpRatio > 0.5
                ? '*:data-[slot=progress-indicator]:bg-cat-recovery'
                : hpRatio > 0.25
                  ? '*:data-[slot=progress-indicator]:bg-cat-chaos'
                  : '*:data-[slot=progress-indicator]:bg-cat-attack',
            )}
            aria-label={`Vida de ${player.displayName}`}
          />
          <span className="w-14 text-right text-xs font-semibold tabular-nums">
            {player.hp}/{player.maxHp} PV
          </span>
        </div>
      ) : (
        <p className="flex items-center gap-1 text-xs text-cat-ghost">
          <GhostIcon className="size-3.5" aria-hidden />
          Fantasma · {player.revivalUsed ? 'já ressuscitou' : `${player.ghostTokens}/3 fichas`}
        </p>
      )}
      {away > 60 && (
        <p className="text-xs text-amber-600" data-testid="away">
          Sem conexão há {Math.floor(away / 60)} min
        </p>
      )}
      {removable && (
        <ConfirmAction
          trigger={
            <Button size="sm" variant="outline" className="self-start text-destructive">
              <UserMinusIcon />
              Remover (ausente)
            </Button>
          }
          title={`Remover ${player.displayName}?`}
          description="Sem conexão há mais de 2 minutos. A pessoa vira desistente: perde as cartas, sai da disputa e não volta para esta partida."
          confirmLabel="Remover"
          destructive
          onConfirm={remove}
        />
      )}
    </li>
  )
}

const NO_EFFECTS: readonly PlayerEffect[] = []

/** Pilhas da mesa menores no celular, para sobrar tela para a mão. */
const PILE_CARD = 'max-sm:w-16 max-sm:text-[0.45rem]'

/** Modo silencioso a um toque, sem sair da mesa. */
function SoundToggle() {
  const { sound } = usePreferences()
  return (
    <Button
      variant="ghost"
      size="icon"
      onClick={() => setPreferences({ sound: !sound })}
      aria-label={sound ? 'Silenciar sons' : 'Ativar sons'}
      aria-pressed={!sound}
      title={sound ? 'Silenciar sons' : 'Ativar sons'}
    >
      {sound ? <Volume2Icon /> : <VolumeXIcon className="text-muted-foreground" />}
    </Button>
  )
}

const FLASH: Record<PlayerEffect['kind'], string> = {
  damage: 'bg-cat-attack/30',
  hit: 'bg-cat-attack/20',
  heal: 'bg-cat-recovery/30',
  death: 'bg-cat-ghost/40',
  revive: 'bg-amber-300/40',
}

/** Camada passageira sobre o painel do jogador. Some sozinha (EFFECT_MS). */
function EffectOverlay({ effect }: { effect: PlayerEffect }) {
  return (
    <span className="pointer-events-none absolute inset-0" aria-hidden data-effect={effect.kind}>
      <span className={cn('absolute inset-0 animate-fx-flash', FLASH[effect.kind])} />
      {effect.kind === 'damage' && (
        <span className="absolute top-8 right-4 animate-float-up text-2xl font-black text-cat-attack [text-shadow:0_1px_0_white]">
          −{effect.amount}
        </span>
      )}
      {effect.kind === 'heal' && (
        <span className="absolute top-8 right-4 animate-float-up text-2xl font-black text-cat-recovery [text-shadow:0_1px_0_white]">
          +{effect.amount}
        </span>
      )}
      {effect.kind === 'death' && (
        <span className="absolute inset-0 flex items-center justify-center">
          <GhostIcon className="size-14 animate-ghost-rise text-cat-ghost" />
        </span>
      )}
      {effect.kind === 'revive' && (
        <span className="absolute inset-0 flex items-center justify-center">
          <span className="size-24 animate-revive-burst rounded-full bg-radial from-amber-200 to-transparent to-70%" />
        </span>
      )}
    </span>
  )
}

/** Carta que acabou de ser jogada, em destaque no meio da tela por um instante. */
function CardSpotlight({ spotlight, catalog }: { spotlight: Spotlight; catalog: CardCatalog }) {
  const card = catalog.get(spotlight.code)
  if (!card) return null
  return (
    <div
      className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center"
      aria-hidden
      data-testid="card-spotlight"
    >
      <div className="animate-card-spotlight drop-shadow-2xl">
        <GameCard card={card} size="md" />
      </div>
    </div>
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

function EventLog({
  game,
  players,
  catalog,
  className,
}: {
  game: GameView
  players: ReadonlyMap<string, Participant>
  catalog: CardCatalog
  className?: string
}) {
  const recent = [...game.events].reverse().slice(0, 15)
  const secrets = game.myPrivateEvents.slice(0, 3)
  // A zoeira fala de todo mundo na terceira pessoa (sem "Você").
  const nameOf = (id: unknown) =>
    (typeof id === 'string' && players.get(id)?.displayName) || 'Alguém'
  return (
    <section aria-labelledby="log-title" className={cn('flex flex-col gap-2', className)}>
      <h2 id="log-title" className="font-heading text-lg font-bold">
        Histórico
      </h2>
      <ol
        className="flex flex-col divide-y rounded-xl border bg-card text-sm lg:min-h-0 lg:flex-1 lg:overflow-y-auto"
        data-testid="event-log"
      >
        {secrets.map((event, index) => (
          <li
            key={`secret-${index}`}
            className="flex items-start gap-2 bg-cat-ghost/5 px-3 py-2 italic"
          >
            <EyeOffIcon className="mt-0.5 size-4 shrink-0 text-cat-ghost" aria-hidden />
            <span>{describePrivateEvent(event, players, catalog)}</span>
          </li>
        ))}
        {recent.map((event) => {
          const { Icon, color } = eventIcon(event, catalog)
          const quip = eventQuip(event, nameOf)
          return (
            <li key={event.seq} className="flex items-start gap-2 px-3 py-2">
              <Icon className={cn('mt-0.5 size-4 shrink-0', color)} aria-hidden />
              <p>
                {describeEvent(event, players, catalog, game.myPlayerId)}
                {quip && (
                  <span className="text-muted-foreground italic" data-testid="event-quip">
                    {' '}
                    {quip}
                  </span>
                )}
              </p>
            </li>
          )
        })}
      </ol>
    </section>
  )
}

type EventIcon = { Icon: React.ComponentType<{ className?: string }>; color: string }

const EVENT_ICON: Record<string, EventIcon> = {
  game_started: { Icon: FlagIcon, color: 'text-primary' },
  round_started: { Icon: FlagIcon, color: 'text-primary' },
  damage_dealt: { Icon: HeartCrackIcon, color: 'text-cat-attack' },
  self_damage: { Icon: HeartCrackIcon, color: 'text-cat-attack' },
  last_word: { Icon: HeartCrackIcon, color: 'text-cat-attack' },
  hangover: { Icon: HeartCrackIcon, color: 'text-cat-ghost' },
  healed: { Icon: HeartPulseIcon, color: 'text-cat-recovery' },
  reaction_played: { Icon: ShieldIcon, color: 'text-cat-defense' },
  sabotage_blocked: { Icon: ShieldIcon, color: 'text-cat-defense' },
  card_stolen: { Icon: BombIcon, color: 'text-cat-sabotage' },
  card_swapped: { Icon: BombIcon, color: 'text-cat-sabotage' },
  target_marked: { Icon: TargetIcon, color: 'text-cat-sabotage' },
  hands_swapped: { Icon: RotateCcwIcon, color: 'text-cat-reversal' },
  player_died: { Icon: GhostIcon, color: 'text-cat-ghost' },
  ghost_peeked: { Icon: GhostIcon, color: 'text-cat-ghost' },
  card_to_bottom: { Icon: GhostIcon, color: 'text-cat-ghost' },
  curse_cast: { Icon: GhostIcon, color: 'text-cat-ghost' },
  revive_declined: { Icon: GhostIcon, color: 'text-cat-ghost' },
  player_revived: { Icon: SparklesIcon, color: 'text-amber-500' },
  game_finished: { Icon: TrophyIcon, color: 'text-amber-500' },
  player_removed: { Icon: UserMinusIcon, color: 'text-muted-foreground' },
}

const DEFAULT_ICON: EventIcon = { Icon: CircleIcon, color: 'text-muted-foreground/50' }

// Classes completas (o Tailwind só gera o que aparece escrito no código).
const CATEGORY_TEXT: Record<CardCategoryId, string> = {
  attack: 'text-cat-attack',
  defense: 'text-cat-defense',
  sabotage: 'text-cat-sabotage',
  chaos: 'text-cat-chaos',
  recovery: 'text-cat-recovery',
  reversal: 'text-cat-reversal',
  ghost: 'text-cat-ghost',
}

function eventIcon(event: GameEvent, catalog: CardCatalog): EventIcon {
  if (event.kind === 'card_played' && typeof event.payload.cardCode === 'string') {
    const card = catalog.get(event.payload.cardCode)
    if (card) return { Icon: CATEGORY_ICON[card.category], color: CATEGORY_TEXT[card.category] }
  }
  return EVENT_ICON[event.kind] ?? DEFAULT_ICON
}

function ResultPanel({
  game,
  players,
}: {
  game: GameView
  players: ReadonlyMap<string, Participant>
}) {
  const result = game.result!
  const winners = result.winnerPlayerIds
    .map((id) => players.get(id))
    .filter((player): player is Participant => player !== undefined)
  const iWon = !!game.myPlayerId && result.winnerPlayerIds.includes(game.myPlayerId)
  const navigate = useNavigate()
  const rematch = useMutation({
    mutationFn: () => createRematch(game.gameId),
    onSuccess: (room) => navigate(`/sala/${room.gameId}`),
    onError: (error) => toast.error(toFriendlyMessage(error)),
  })
  const when = {
    round_limit: 'Fim das 10 rodadas',
    last_alive: 'Último vivo de pé',
    all_dead: 'Todo mundo caiu',
  }[result.reason]
  const why = {
    hp: 'venceu quem terminou com mais PV.',
    knockouts: 'empate desfeito pelas eliminações.',
    shared: 'empate total, vitória compartilhada.',
    last_alive: 'nenhum fantasma podia mais voltar.',
    last_standing: 'venceu quem caiu por último (e com mais PV antes do golpe).',
  }[result.criteria]

  return (
    <Card className="border-amber-400/60 bg-amber-50/60" data-testid="result">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-xl">
          <TrophyIcon className="size-6 text-amber-500" aria-hidden />
          {iWon ? 'Você venceu!' : winners.length > 1 ? 'Vitória compartilhada' : 'Fim da resenha'}
        </CardTitle>
        <CardDescription>
          {when}: {why}
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <p className="font-medium" data-testid="winners">
          {winners.length === 1 ? 'Vencedor: ' : 'Vencedores: '}
          {winners.map((winner) => winner.displayName).join(', ')}
        </p>
        <div className="flex flex-wrap gap-2">
          <Button disabled={rematch.isPending} onClick={() => rematch.mutate()}>
            {rematch.isPending ? <Loader2Icon className="animate-spin" /> : <RotateCcwIcon />}
            {game.rematchGameId ? 'Entrar na revanche' : 'Revanche'}
          </Button>
          <Button asChild variant="outline">
            <Link to="/lobby">Voltar ao lobby</Link>
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}

/** Jogada esperando respostas: quem jogou, em quem e quem falta responder. */
function PendingBanner({
  game,
  players,
  catalog,
}: {
  game: GameView
  players: ReadonlyMap<string, Participant>
  catalog: CardCatalog
}) {
  const pending = game.pendingAction!
  const name = (id: string) =>
    id === game.myPlayerId ? 'você' : (players.get(id)?.displayName ?? 'alguém')
  const waiting = pending.responses.filter((response) => !response.responded)
  const card = catalog.get(pending.cardCode)?.name ?? pending.cardCode
  const targets = pending.responses
    .filter((response) => TARGET_ROLES.includes(response.role))
    .map((response) =>
      response.role === 'sabotage_target'
        ? name(response.playerId)
        : `${name(response.playerId)} (${response.baseDamage})`,
    )
    .join(' e ')
  const choosing = pending.stage === 'choice'

  return (
    <div
      className="flex flex-col gap-1 rounded-xl border border-cat-attack/40 bg-cat-attack/5 p-3 text-sm"
      role="status"
      data-testid="pending-banner"
    >
      <p className="font-medium">
        {name(pending.actorPlayerId)} jogou {card}
        {targets ? ` em ${targets}` : ''}.
      </p>
      {waiting.length > 0 && (
        <p className="text-muted-foreground">
          {choosing ? 'Aguardando escolha de ' : 'Aguardando resposta de '}
          {waiting.map((response) => name(response.playerId)).join(', ')}…
        </p>
      )}
    </div>
  )
}

/** Fantasma com 3 fichas: ressuscitar agora ou seguir no Além. */
function ReviveChoice({ game }: { game: GameView }) {
  const command = useGameCommand(game)
  const send = (type: 'GHOST_REVIVE' | 'GHOST_STAY') =>
    command.mutate(
      { requestId: newRequestId(), command: { type } },
      { onError: (error) => toast.error(toFriendlyMessage(error)) },
    )

  return (
    <div
      className="flex flex-col gap-3 rounded-xl border border-cat-ghost/40 bg-cat-ghost/5 p-4"
      data-testid="revive-choice"
    >
      <p className="font-medium">Você juntou 3 fichas de ressaca!</p>
      <p className="text-sm text-muted-foreground">
        Ressuscitar: volta com 6 PV e 3 cartas novas, perde as cartas do Além e o turno acaba. Só dá
        para fazer isso uma vez. Ou continue fantasma: compra 1 carta do Além e joga normalmente.
      </p>
      <div className="flex flex-wrap gap-2">
        <Button disabled={command.isPending} onClick={() => send('GHOST_REVIVE')}>
          Ressuscitar
        </Button>
        <Button variant="outline" disabled={command.isPending} onClick={() => send('GHOST_STAY')}>
          Continuar fantasma
        </Button>
      </div>
    </div>
  )
}

/** Host sumido há mais de 2 minutos: qualquer jogador pode assumir o posto. */
function ClaimHostBanner({ game }: { game: GameView }) {
  const command = useGameCommand(game)
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-amber-400/60 bg-amber-50 p-3 text-sm">
      <p>O host está sem conexão há mais de 2 minutos.</p>
      <Button
        size="sm"
        disabled={command.isPending}
        onClick={() =>
          command.mutate(
            { requestId: newRequestId(), command: { type: 'CLAIM_HOST' } },
            { onError: (error) => toast.error(toFriendlyMessage(error)) },
          )
        }
      >
        Assumir como host
      </Button>
    </div>
  )
}

/** Papéis de quem sofre a jogada (o resto são contra-ataques e escolhas). */
const TARGET_ROLES: readonly ResponseRole[] = ['target', 'sabotage_target', 'chaos_target']

function hostAway(game: GameView) {
  const host = game.participants.find((player) => player.userId === game.hostUserId)
  const presence = host && game.presence.find((item) => item.playerId === host.id)
  return !!presence && !presence.quit && presence.secondsAway > game.absenceLimitSeconds
}
