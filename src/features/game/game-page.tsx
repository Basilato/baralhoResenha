import { useLayoutEffect, useRef, useState } from 'react'
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
  TicketIcon,
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
import { useDeadlineEnforcer } from './use-deadline'
import { Countdown } from './countdown'
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
  // Vale Entrosa: quem está jogando agora pegou a vez de outra pessoa.
  const stolenFrom = game.stolenFromPlayerId ? players.get(game.stolenFromPlayerId) : undefined
  const thiefByTarget = new Map(
    game.turnSteals.map((steal) => [steal.targetPlayerId, players.get(steal.thiefPlayerId)]),
  )
  const isHost = game.hostUserId === user?.id
  const isMyTurn = game.status === 'playing' && !!me && me.id === game.activePlayerId
  const fx = useTableEffects(game, catalog)
  // Com uma carta voando para o descarte, a mesa mostra o topo de antes: a nova
  // aparece quando pousa.
  const previousTop = fx.spotlight?.previousTop
  const landing = previousTop !== undefined
  const discardCode = landing ? previousTop : game.mainDiscardTop
  const discardTop = discardCode ? catalog.get(discardCode) : undefined
  const discardPileCount = game.mainDiscardCount - (landing ? 1 : 0)
  // Onde estava a última carta que abri na mão: se eu jogá-la, ela sai dali.
  const [handOrigin, setHandOrigin] = useState<FlightOrigin | null>(null)
  const iQuit = !!me && !!game.presence.find((item) => item.playerId === me.id)?.quit
  // Prazo vencido: qualquer participante cobra (o banco confere a hora).
  useDeadlineEnforcer(game, !!me && !iQuit)
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
        <div className="flex flex-wrap items-center gap-3">
          <div>
            <h1 className="text-2xl sm:text-3xl">
              Rodada <span className="text-gradient-brand">{game.round}</span>
              <span className="text-lg text-muted-foreground"> de {game.maxRounds}</span>
            </h1>
            {/* Uma bolinha por rodada: o quanto falta para a Ressaca apertar. */}
            <div className="mt-1 flex gap-1" aria-hidden>
              {Array.from({ length: game.maxRounds }, (_, index) => (
                <span
                  key={index}
                  className={cn(
                    'h-1.5 w-4 rounded-full',
                    index < game.round
                      ? index >= 4
                        ? 'bg-cat-chaos shadow-[0_0_8px_var(--cat-chaos)]'
                        : 'bg-primary shadow-[0_0_8px_var(--primary)]'
                      : 'bg-white/10',
                  )}
                />
              ))}
            </div>
          </div>
          {game.status === 'playing' && (
            <span
              className={cn(
                'inline-flex items-center gap-2 rounded-full px-4 py-1.5 font-heading text-base tracking-wide',
                isMyTurn
                  ? 'glow-gold bg-linear-to-b from-[oklch(0.9_0.15_92)] to-[oklch(0.76_0.16_70)] text-gold-foreground'
                  : 'border border-white/10 bg-white/[0.05] text-foreground/85',
              )}
            >
              <span
                className={cn(
                  'size-2 rounded-full',
                  isMyTurn ? 'bg-gold-foreground' : 'animate-pulse bg-neon',
                )}
              />
              <span data-testid="turn-status">
                {isMyTurn ? 'Sua vez!' : `Vez de ${active?.displayName ?? '…'}`}
              </span>
              {stolenFrom && (
                <span className="flex items-center gap-1 text-sm opacity-80">
                  <TicketIcon className="size-3.5" aria-hidden />
                  roubada de {stolenFrom.id === me?.id ? 'você' : stolenFrom.displayName}
                </span>
              )}
              {!game.pendingAction && (
                <Countdown deadline={game.turnDeadlineAt} skewMs={game.clockSkewMs} />
              )}
            </span>
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
                  stealBy={thiefByTarget.get(player.id)}
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

          {/* Visto de quem está sentado: o pano inclina um pouco para longe. */}
          <div className="perspective-[1100px]">
            <section
              aria-label="Mesa"
              // Maldição da Ressaca: a mesa fica tomada pela névoa do Além.
              data-curse={(game.curseActive && game.status === 'playing') || undefined}
              className="felt flex rotate-x-[10deg] items-end justify-center gap-6 rounded-[999px] px-10 pt-6 pb-5 sm:gap-14 sm:px-20 sm:pt-8 sm:pb-6"
            >
              <Pile label="Baralho" count={game.mainDeckCount} testId="main-deck-count">
                {/* A key nova reinicia o "pulo" do monte a cada compra. */}
                <div key={fx.deckDrawKey} className={cn(fx.deckDrawKey > 0 && 'animate-deck-bump')}>
                  <PileStack count={game.mainDeckCount}>
                    <CardBack deckType="main" size="sm" className={PILE_CARD} />
                  </PileStack>
                </div>
              </Pile>
              <Pile label="Descarte" count={game.mainDiscardCount} testId="main-discard-count">
                {discardTop ? (
                  <DiscardPile count={discardPileCount}>
                    <button
                      type="button"
                      onClick={() => setSelected(discardTop)}
                      aria-label={`Ver ${discardTop.name}`}
                    >
                      <GameCard card={discardTop} size="sm" className={PILE_CARD} />
                    </button>
                  </DiscardPile>
                ) : (
                  <div
                    className="flex aspect-card w-16 items-center justify-center rounded-lg border-2 border-dashed border-white/25 text-xs text-white/60 sm:w-24"
                    data-flight-target="discard"
                  >
                    vazio
                  </div>
                )}
              </Pile>
              <Pile label="Além" count={game.ghostDeckCount} testId="ghost-deck-count">
                <PileStack count={game.ghostDeckCount} flightTarget="ghost">
                  <CardBack deckType="ghost" size="sm" className={PILE_CARD} />
                </PileStack>
              </Pile>
            </section>
          </div>
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
            key={`${game.round}-${game.activePlayerId}-${game.stolenFromPlayerId}`}
            game={game}
            me={me}
            isMyTurn={isMyTurn}
            catalog={catalog}
            drawnIds={fx.drawnIds}
            className="lg:col-span-2"
            onOpenCard={(handCard, card, origin) => {
              setHandOrigin(origin)
              setPlaying({ handCard, card })
            }}
          />
        )}
      </div>

      {fx.spotlight && (
        <CardFlight
          key={fx.spotlight.id}
          spotlight={fx.spotlight}
          catalog={catalog}
          origin={
            fx.spotlight.playerId === game.myPlayerId && handOrigin?.code === fx.spotlight.code
              ? handOrigin
              : undefined
          }
          landingTilt={fx.spotlight.to === 'discard' ? discardTilt(game.mainDiscardCount) : 0}
        />
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
  onOpenCard: (handCard: HandCard, card: CardDefinition, origin: FlightOrigin) => void
}) {
  const command = useGameCommand(game)
  const [discarding, setDiscarding] = useState<ReadonlySet<string>>(new Set())
  // O limite de mão só vale ao encerrar: durante a vez dá para jogar com 9.
  const [endingTurn, setEndingTurn] = useState(false)

  const ghost = !me.alive
  const hand = ghost ? game.myGhostHand : game.myHand
  const limit = ghost ? game.ghostHandLimit : game.handLimit
  const excess = Math.max(0, hand.length - limit)
  // Sem ações e acima do limite: o descarte já abre (o banco encerra sozinho
  // quem não tem o que descartar).
  const inTurn = game.phase === 'turn_main' || game.phase === 'turn_ghost'
  const outOfActions =
    inTurn && game.actionsUsed >= (ghost ? game.maxGhostActions : game.maxActions)
  const mustDiscard = isMyTurn && excess > 0 && (endingTurn || outOfActions)
  const ready = discarding.size === excess
  // Nada jogável com ações sobrando: só resta encerrar (a tela destaca o botão).
  const nothingToPlay =
    isMyTurn &&
    inTurn &&
    !mustDiscard &&
    hand.every((item) => {
      const card = catalog.get(item.code)
      return !card || whyNotPlayable(card, game, true) !== null
    })

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
      className={cn(
        'flex min-w-0 flex-col gap-3 rounded-[1.75rem] border border-white/[0.06] bg-linear-to-b from-white/[0.045] to-transparent p-3 sm:p-4',
        className,
      )}
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h2 id="my-hand-title" className="flex items-center gap-2 text-xl">
          {ghost ? 'Suas cartas do Além' : 'Sua mão'}
          <Badge variant={excess > 0 ? 'destructive' : 'secondary'} data-testid="my-hand-count">
            {hand.length}/{limit}
          </Badge>
        </h2>

        {isMyTurn && (
          // No celular, a barra fica presa embaixo da tela durante a sua vez.
          <div className="flex flex-wrap items-center gap-2 max-sm:fixed max-sm:inset-x-0 max-sm:bottom-0 max-sm:z-10 max-sm:justify-between max-sm:border-t max-sm:border-white/10 max-sm:bg-[oklch(0.13_0.035_285/0.97)] max-sm:p-3">
            <span className="text-sm text-muted-foreground" data-testid="actions-left">
              {ghost
                ? `Carta do Além: ${game.actionsUsed}/${game.maxGhostActions}`
                : `Ações: ${game.actionsUsed}/${game.maxActions}`}
            </span>
            {nothingToPlay && (
              <span className="text-sm text-gold" data-testid="nothing-to-play">
                Nada para jogar agora
              </span>
            )}
            {mustDiscard && !outOfActions && (
              <Button variant="ghost" className="h-11" onClick={cancelEnding}>
                Cancelar
              </Button>
            )}
            <Button
              size="lg"
              className={cn('h-11', nothingToPlay && 'glow-gold animate-pulse')}
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
          className="hand-fan relative -mx-4 flex justify-center-safe overflow-x-auto px-8 pt-12 pb-4"
          style={{ '--n': hand.length } as React.CSSProperties}
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
                fan={fanPosition(index, hand.length)}
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

/**
 * Lugar de uma carta no leque: gira a partir da base, e as do meio ficam mais
 * altas, formando um arco. Quanto mais cartas, menor o giro entre elas.
 */
function fanPosition(index: number, total: number) {
  const offset = index - (total - 1) / 2
  const step = total > 1 ? Math.min(3, 18 / (total - 1)) : 0
  const edge = (total - 1) / 2
  return { rotate: offset * step, lift: (edge * edge - offset * offset) * 0.09 }
}

function HandItem({
  handCard,
  card,
  fan,
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
  /** Giro (graus) e altura (rem) da carta no leque. */
  fan: { rotate: number; lift: number }
  /** Pode ser jogada agora (só na sua vez). */
  playable: boolean
  /** Por que não pode ser jogada agora (só na sua vez). */
  blockedReason?: string
  /** Recém-comprada: atraso (ms) da animação de entrada, para entrar em sequência. */
  drawnDelay?: number
  selectable: boolean
  selected: boolean
  onSelect: () => void
  onOpen: (handCard: HandCard, card: CardDefinition, origin: FlightOrigin) => void
}) {
  if (!card) return null
  return (
    <li
      className={cn(
        // Na mão, a carta apontada (ou com foco) endireita, sobe e vai para a frente.
        'relative shrink-0 origin-bottom translate-y-(--fan-y) rotate-(--fan-rotate) transition-[translate,rotate] duration-200 ease-out hover:z-10 hover:translate-y-[calc(var(--fan-y)-1.25rem)] hover:rotate-0 has-focus-visible:z-10 has-focus-visible:translate-y-[calc(var(--fan-y)-1.25rem)] has-focus-visible:rotate-0',
        drawnDelay !== undefined && 'animate-card-draw',
      )}
      style={
        {
          '--fan-rotate': `${fan.rotate}deg`,
          '--fan-y': `${-fan.lift}rem`,
          animationDelay: drawnDelay ? `${drawnDelay}ms` : undefined,
        } as React.CSSProperties
      }
    >
      <button
        type="button"
        className={cn(
          'relative rounded-xl shadow-[-0.4rem_0.3rem_1rem_oklch(0_0_0/0.45)] transition-transform focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none',
          playable && 'shadow-[0_0_0.9em_var(--cat)] ring-2 ring-(--cat)',
          blockedReason && 'opacity-60 saturate-[0.35] hover:opacity-90 hover:saturate-100',
          selected && '-translate-y-2 opacity-60 ring-3 ring-destructive',
        )}
        style={{ '--cat': `var(--cat-${card.category})` } as React.CSSProperties}
        title={blockedReason}
        data-playable={playable || undefined}
        onClick={(event) =>
          selectable
            ? onSelect()
            : onOpen(handCard, card, flightOrigin(card.code, event.currentTarget, fan.rotate))
        }
        aria-label={selectable ? `Descartar ${card.name}` : `Ver ${card.name}`}
        aria-pressed={selectable ? selected : undefined}
        data-instance={handCard.instanceId}
      >
        <GameCard card={card} size="md" className="max-sm:w-32 max-sm:text-[0.68rem]" />
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
  stealBy,
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
  /** Quem vai jogar a próxima vez desta pessoa (Vale Entrosa). */
  stealBy: Participant | undefined
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
        'relative flex min-w-38 snap-start flex-col gap-2 overflow-hidden rounded-2xl p-2.5 panel transition-shadow sm:min-w-0 sm:p-3',
        compact && 'gap-1.5 sm:p-2.5',
        isMe && 'border-primary/60',
        isLeader && player.alive && 'bg-linear-to-br from-cat-attack/12 to-card to-60%',
        !player.alive && 'border-cat-ghost/40 bg-linear-to-br from-cat-ghost/20 to-card to-70%',
        isActive && 'glow-gold border-gold/70',
        isTargeted && 'animate-target-pulse border-cat-attack',
        effects.some((effect) => effect.kind === 'damage') && 'animate-shake',
      )}
      data-testid="table-player"
      data-player={player.id}
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
          {player.isHost && <CrownIcon className="size-4 shrink-0 text-gold" aria-label="Host" />}
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
      {(isActive || isLeader || isMarked || stealBy || isTargeted || isAwaiting) && (
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
          {stealBy && (
            <Badge
              variant="outline"
              className="h-5 gap-1 border-cat-sabotage text-cat-sabotage"
              title={`Vale Entrosa: a próxima vez é de ${stealBy.displayName}`}
            >
              <TicketIcon className="size-3" aria-hidden />
              Perde a vez
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
        <p className="text-xs text-amber-300" data-testid="away">
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
        <span className="absolute top-8 right-4 animate-float-up font-heading text-3xl text-cat-attack [text-shadow:0_2px_0_oklch(0_0_0/0.6),0_0_14px_var(--cat-attack)]">
          −{effect.amount}
        </span>
      )}
      {effect.kind === 'heal' && (
        <span className="absolute top-8 right-4 animate-float-up font-heading text-3xl text-cat-recovery [text-shadow:0_2px_0_oklch(0_0_0/0.6),0_0_14px_var(--cat-recovery)]">
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

/** Centro, largura e giro de uma carta na tela, de onde uma jogada sai voando. */
type FlightOrigin = { code: string; x: number; y: number; width: number; rotate: number }

function flightOrigin(code: string, element: HTMLElement, rotate = 0): FlightOrigin {
  const box = element.getBoundingClientRect()
  // offsetWidth ignora o giro: é a largura da carta, não da caixa girada.
  return {
    code,
    x: box.left + box.width / 2,
    y: box.top + box.height / 2,
    width: element.offsetWidth,
    rotate,
  }
}

/** Dura o mesmo que o destaque (SPOTLIGHT_MS): a carta some quando pousa. */
const FLIGHT_MS = 1800

function reducedMotion() {
  return (
    document.documentElement.dataset.motion === 'reduced' ||
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  )
}

/**
 * Carta que acabou de ser jogada: sai da minha mão (ou do painel de quem jogou),
 * para em destaque no meio da tela e voa até pousar no monte, já com o giro
 * que vai ter lá. Sem animações (preferência do sistema ou do menu), não aparece.
 */
function CardFlight({
  spotlight,
  catalog,
  origin,
  landingTilt,
}: {
  spotlight: Spotlight
  catalog: CardCatalog
  /** Onde a carta estava na minha mão; sem isso, sai do painel de quem jogou. */
  origin?: FlightOrigin
  landingTilt: number
}) {
  const card = catalog.get(spotlight.code)
  const ref = useRef<HTMLDivElement>(null)
  // Lidos só ao montar (a key muda a cada jogada): mudar no meio não refaz o voo.
  const start = useRef({ spotlight, origin, landingTilt })

  useLayoutEffect(() => {
    const element = ref.current
    if (!element?.animate) return
    const { spotlight: played, origin: fromHand, landingTilt: tilt } = start.current
    const home = element.getBoundingClientRect()
    const place = (to: FlightOrigin | undefined, scale = 1) =>
      to
        ? `translate(${to.x - (home.left + home.width / 2)}px, ${to.y - (home.top + home.height / 2)}px) scale(${(to.width / home.width) * scale}) rotate(${to.rotate}deg)`
        : `translateY(2rem) scale(0.6)`
    const find = (selector: string) => {
      const target = document.querySelector<HTMLElement>(selector)
      return target ? flightOrigin(played.code, target) : undefined
    }

    const from =
      fromHand ??
      (played.playerId ? find(`[data-player="${CSS.escape(played.playerId)}"]`) : undefined)
    const landing = find(`[data-flight-target="${played.to}"]`)
    const center = 'translate(0, 0) scale(1) rotate(0deg)'

    const animation = element.animate(
      [
        {
          offset: 0,
          // Do painel de alguém a carta nasce pequena; da minha mão, já inteira.
          transform: place(from, fromHand ? 1 : 0.4),
          opacity: fromHand ? 1 : 0,
          easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)',
        },
        { offset: 0.08, opacity: 1 },
        { offset: 0.24, transform: 'translate(0, 0) scale(1.08) rotate(0deg)' },
        { offset: 0.32, transform: center },
        { offset: 0.66, transform: center, easing: 'cubic-bezier(0.5, 0, 0.3, 1)' },
        landing
          ? { offset: 0.9, transform: place({ ...landing, rotate: tilt }), opacity: 1 }
          : { offset: 0.9, transform: 'translateY(-1rem) scale(0.85)', opacity: 0 },
        landing
          ? { offset: 1, transform: place({ ...landing, rotate: tilt }), opacity: 1 }
          : { offset: 1, opacity: 0 },
      ],
      { duration: FLIGHT_MS, fill: 'forwards' },
    )
    return () => animation.cancel()
  }, [])

  if (!card || reducedMotion()) return null
  return (
    <div
      className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center"
      aria-hidden
      data-testid="card-spotlight"
    >
      <div ref={ref} className="rounded-xl shadow-[0_1.2rem_2.5rem_oklch(0_0_0/0.6)]">
        <GameCard card={card} size="md" />
      </div>
    </div>
  )
}

/** Monte virado para baixo com espessura: afina conforme as cartas saem. */
function PileStack({
  count,
  flightTarget,
  children,
}: {
  count: number
  /** Monte onde pousam as cartas jogadas (CardFlight). */
  flightTarget?: Spotlight['to']
  children: React.ReactNode
}) {
  const depth = count > 1 ? Math.min(4, Math.ceil(count / 12)) : 0
  return (
    <div
      className={cn('relative', count > 1 && 'pile-stack')}
      style={{ '--depth': depth } as React.CSSProperties}
      data-flight-target={flightTarget}
    >
      {children}
    </div>
  )
}

/** Giro de uma carta do descarte, estável para a mesma posição na pilha (−7° a 7°). */
function discardTilt(position: number) {
  return ((position * 37) % 15) - 7
}

/**
 * Descarte como numa mesa de verdade: cartas jogadas umas sobre as outras, cada
 * uma meio torta. Só a de cima é conhecida; as de baixo são silhuetas.
 */
function DiscardPile({ count, children }: { count: number; children: React.ReactNode }) {
  const below = Math.min(2, count - 1)
  return (
    <div className="relative">
      {Array.from({ length: below }, (_, index) => (
        <span
          key={index}
          className="absolute inset-0 rounded-lg border-2 border-white/15 bg-card shadow-md"
          style={{ rotate: `${discardTilt(count - below + index)}deg` }}
          aria-hidden
        />
      ))}
      <div
        className="relative drop-shadow-[0_6px_6px_oklch(0_0_0/0.5)]"
        style={{ rotate: `${discardTilt(count)}deg` }}
        data-flight-target="discard"
      >
        {children}
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
      <p className="flex items-center gap-1.5 rounded-full bg-black/35 px-2.5 py-0.5 text-xs text-white/75 ring-1 ring-white/10">
        {label}
        <span className="font-heading text-sm text-white tabular-nums" data-testid={testId}>
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
        className="flex flex-col divide-y divide-white/[0.06] rounded-2xl text-sm panel lg:min-h-0 lg:flex-1 lg:overflow-y-auto"
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
  cards_drawn: { Icon: LayersIcon, color: 'text-cat-recovery' },
  reaction_played: { Icon: ShieldIcon, color: 'text-cat-defense' },
  sabotage_blocked: { Icon: ShieldIcon, color: 'text-cat-defense' },
  card_stolen: { Icon: BombIcon, color: 'text-cat-sabotage' },
  card_swapped: { Icon: BombIcon, color: 'text-cat-sabotage' },
  target_marked: { Icon: TargetIcon, color: 'text-cat-sabotage' },
  turn_steal_set: { Icon: TicketIcon, color: 'text-cat-sabotage' },
  turn_stolen: { Icon: TicketIcon, color: 'text-cat-sabotage' },
  turn_steal_lapsed: { Icon: TicketIcon, color: 'text-muted-foreground' },
  hands_swapped: { Icon: RotateCcwIcon, color: 'text-cat-reversal' },
  hands_shuffled: { Icon: RotateCcwIcon, color: 'text-cat-chaos' },
  storm_draw: { Icon: LayersIcon, color: 'text-cat-chaos' },
  player_died: { Icon: GhostIcon, color: 'text-cat-ghost' },
  ghost_peeked: { Icon: GhostIcon, color: 'text-cat-ghost' },
  card_to_bottom: { Icon: GhostIcon, color: 'text-cat-ghost' },
  curse_cast: { Icon: GhostIcon, color: 'text-cat-ghost' },
  revive_declined: { Icon: GhostIcon, color: 'text-cat-ghost' },
  player_revived: { Icon: SparklesIcon, color: 'text-gold' },
  game_finished: { Icon: TrophyIcon, color: 'text-gold' },
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
    <Card
      className="border-gold/50 bg-linear-to-br from-gold/20 via-card/80 to-card/80 shadow-[0_0_50px_-12px_var(--gold)]"
      data-testid="result"
    >
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-xl">
          <TrophyIcon className="size-8 text-gold drop-shadow-[0_0_10px_var(--gold)]" aria-hidden />
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
      className="flex flex-col gap-1 rounded-2xl border border-cat-attack/45 bg-linear-to-r from-cat-attack/20 to-cat-attack/5 p-3 text-sm shadow-[0_0_24px_-8px_var(--cat-attack)]"
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
          {waiting.map((response) => name(response.playerId)).join(', ')}…{' '}
          <Countdown deadline={game.responseDeadlineAt} skewMs={game.clockSkewMs} />
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
      className="flex flex-col gap-3 rounded-2xl border border-cat-ghost/50 bg-linear-to-br from-cat-ghost/25 to-cat-ghost/5 p-4 shadow-[0_0_30px_-10px_var(--cat-ghost)]"
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
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-gold/40 bg-gold/10 p-3 text-sm">
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
const TARGET_ROLES: readonly ResponseRole[] = [
  'target',
  'sabotage_target',
  'chaos_target',
  'chaos_self',
]

function hostAway(game: GameView) {
  const host = game.participants.find((player) => player.userId === game.hostUserId)
  const presence = host && game.presence.find((item) => item.playerId === host.id)
  return !!presence && !presence.quit && presence.secondsAway > game.absenceLimitSeconds
}
