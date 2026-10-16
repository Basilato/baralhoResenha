import { useEffect } from 'react'
import { Navigate, useNavigate, useParams } from 'react-router'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  CheckIcon,
  CopyIcon,
  CrownIcon,
  DoorOpenIcon,
  Loader2Icon,
  PlayIcon,
  RefreshCwIcon,
  Share2Icon,
  UserCheckIcon,
  UserXIcon,
  WifiOffIcon,
  XCircleIcon,
} from 'lucide-react'
import { ConfirmAction } from '@/components/confirm-action'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { PlayerAvatar } from '@/components/player-avatar'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { useAuth } from '@/features/auth/auth-context'
import { isAppError, toFriendlyMessage } from '@/lib/errors'
import { MAX_PLAYERS, MIN_PLAYERS } from '@/lib/constants'
import { cn } from '@/lib/utils'
import {
  allowRejoin,
  closeRoom,
  formatRoomCode,
  inviteLink,
  kickPlayer,
  leaveRoom,
  roomKeys,
  rotateRoomCode,
  setReady,
  startGame,
  type RoomPlayer,
  type RoomView,
} from './rooms-service'
import { useGameChannel, useRoomView } from './use-room'
import { RoomUnavailable } from './room-unavailable'

export function RoomPage() {
  const { gameId } = useParams<{ gameId: string }>()
  const channel = useGameChannel(gameId)
  const room = useRoomView(gameId, channel.status)
  const removed = isAppError(room.error, 'ROOM_NOT_FOUND')
  const navigate = useNavigate()

  // Quem estava na sala e deixou de ser membro foi removido pelo host.
  const wasMember = room.data !== undefined
  useEffect(() => {
    if (removed && wasMember) {
      toast.info('Você não está mais nesta sala.')
      navigate('/lobby', { replace: true })
    }
  }, [removed, wasMember, navigate])

  if (room.isPending) return <FullPageSpinner />
  if (room.isError && !room.data) return <RoomUnavailable error={room.error} />
  if (!room.data) return <FullPageSpinner />

  if (room.data.status === 'playing') return <Navigate to={`/jogo/${room.data.id}`} replace />
  if (room.data.status !== 'lobby') return <RoomUnavailable closed />

  return (
    <Lobby
      room={room.data}
      onlineUserIds={channel.onlineUserIds}
      offline={channel.status === 'offline'}
    />
  )
}

function Lobby({
  room,
  onlineUserIds,
  offline,
}: {
  room: RoomView
  onlineUserIds: ReadonlySet<string>
  offline: boolean
}) {
  const { user } = useAuth()
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  const me = room.players.find((player) => player.id === room.myPlayerId)
  const isHost = room.hostUserId === user?.id
  const count = room.players.length
  const missing = Math.max(0, MIN_PLAYERS - count)
  const seats = Array.from(
    { length: MAX_PLAYERS },
    (_, index) => room.players.find((player) => player.seat === index + 1) ?? null,
  )

  const refresh = () => queryClient.invalidateQueries({ queryKey: roomKeys.view(room.id) })
  const onError = (error: unknown) => {
    toast.error(toFriendlyMessage(error))
    if (isAppError(error, 'VERSION_CONFLICT')) void refresh()
  }

  const ready = useMutation({
    mutationFn: (value: boolean) => setReady(room.id, value),
    onSuccess: refresh,
    onError,
  })
  const start = useMutation({
    mutationFn: () => startGame(room.id, room.version),
    onSuccess: refresh,
    onError,
  })
  const kick = useMutation({
    mutationFn: (playerId: string) => kickPlayer(room.id, playerId),
    onSuccess: refresh,
    onError,
  })
  const leave = useMutation({
    mutationFn: () => leaveRoom(room.id),
    onSuccess: () => {
      navigate('/lobby', { replace: true })
      queryClient.removeQueries({ queryKey: roomKeys.view(room.id) })
      void queryClient.invalidateQueries({ queryKey: roomKeys.mine() })
    },
    onError,
  })
  const rotate = useMutation({
    mutationFn: () => rotateRoomCode(room.id),
    onSuccess: () => {
      toast.success('Código novo gerado. O anterior parou de funcionar.')
      void refresh()
    },
    onError,
  })
  const allow = useMutation({
    mutationFn: (userId: string) => allowRejoin(room.id, userId),
    onSuccess: refresh,
    onError,
  })
  const close = useMutation({
    mutationFn: () => closeRoom(room.id),
    onSuccess: () => {
      toast.success('Sala encerrada.')
      navigate('/lobby', { replace: true })
      void queryClient.invalidateQueries({ queryKey: roomKeys.mine() })
    },
    onError,
  })

  return (
    <div className="flex flex-col gap-6 pb-56 sm:pb-0">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="font-heading text-sm tracking-[0.25em] text-muted-foreground uppercase">
            Antes da resenha
          </p>
          <h1 className="text-4xl">Sala de espera</h1>
          <p className="text-muted-foreground">
            {missing > 0
              ? missing === 1
                ? 'Falta 1 pessoa para começar.'
                : `Faltam ${missing} pessoas para começar.`
              : `${count} de ${MAX_PLAYERS} lugares ocupados.`}
          </p>
        </div>
        {offline && (
          <Badge variant="outline" className="gap-1 text-muted-foreground">
            <WifiOffIcon className="size-3" />
            Reconectando…
          </Badge>
        )}
      </div>

      {room.code && (
        <InviteCard
          code={room.code}
          canRotate={isHost}
          rotating={rotate.isPending}
          onRotate={() => rotate.mutate()}
        />
      )}

      <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4" aria-label="Lugares">
        {seats.map((player, index) =>
          player ? (
            <SeatCard
              key={player.id}
              player={player}
              isMe={player.id === room.myPlayerId}
              online={onlineUserIds.has(player.userId)}
              canKick={isHost && player.userId !== user?.id}
              onKick={() => kick.mutate(player.id)}
            />
          ) : (
            <li
              key={`empty-${index}`}
              className="flex h-20 items-center gap-3 rounded-2xl border border-dashed border-white/12 bg-white/[0.02] px-4 text-sm text-muted-foreground"
            >
              <span className="flex size-10 items-center justify-center rounded-full border border-dashed border-white/20 font-heading text-base">
                {index + 1}
              </span>
              Lugar vago
            </li>
          ),
        )}
      </ul>

      {room.removedPlayers.length > 0 && (
        <section aria-labelledby="removed-title" className="flex flex-col gap-2">
          <h2 id="removed-title" className="text-sm font-medium text-muted-foreground">
            Removidos por você (só voltam se você liberar)
          </h2>
          <ul className="flex flex-wrap gap-2">
            {room.removedPlayers.map((removed) => (
              <li
                key={removed.userId}
                className="flex items-center gap-2 rounded-full py-1 pr-1 pl-3 text-sm panel"
              >
                {removed.displayName}
                <Button
                  size="sm"
                  variant="outline"
                  className="rounded-full"
                  disabled={allow.isPending}
                  onClick={() => allow.mutate(removed.userId)}
                >
                  <UserCheckIcon />
                  Permitir volta
                </Button>
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="fixed inset-x-0 bottom-0 z-10 border-t border-white/10 bg-[oklch(0.13_0.035_285/0.97)] p-4 sm:static sm:border-0 sm:bg-transparent sm:p-0">
        <div className="mx-auto flex max-w-5xl flex-col gap-2 sm:flex-row sm:items-center">
          <Button
            size="lg"
            variant={me?.isReady ? 'secondary' : 'outline'}
            className="h-11 sm:w-44"
            disabled={ready.isPending}
            aria-pressed={me?.isReady ?? false}
            onClick={() => ready.mutate(!me?.isReady)}
          >
            {me?.isReady ? <CheckIcon /> : null}
            {me?.isReady ? 'Estou pronto' : 'Marcar como pronto'}
          </Button>

          {isHost && (
            <Button
              variant="gold"
              size="lg"
              className="h-12 text-lg sm:w-60"
              disabled={missing > 0 || start.isPending}
              onClick={() => start.mutate()}
            >
              {start.isPending ? <Loader2Icon className="animate-spin" /> : <PlayIcon />}
              Começar ({count}/{MAX_PLAYERS})
            </Button>
          )}

          <div className="flex gap-2 sm:ml-auto">
            <ConfirmAction
              trigger={
                <Button variant="ghost" className="h-10 flex-1" disabled={leave.isPending}>
                  <DoorOpenIcon />
                  Sair da sala
                </Button>
              }
              title="Sair da sala?"
              description={
                isHost && count > 1
                  ? 'Você é o host. Ao sair, o posto passa para quem entrou primeiro depois de você.'
                  : 'Você pode voltar depois com o código, se a resenha ainda não tiver começado.'
              }
              confirmLabel="Sair"
              onConfirm={() => leave.mutate()}
            />
            {isHost && (
              <ConfirmAction
                trigger={
                  <Button
                    variant="ghost"
                    className="h-10 flex-1 text-destructive"
                    disabled={close.isPending}
                  >
                    <XCircleIcon />
                    Encerrar sala
                  </Button>
                }
                title="Encerrar a sala?"
                description="Todo mundo volta para o lobby e o código deixa de funcionar."
                confirmLabel="Encerrar"
                destructive
                onConfirm={() => close.mutate()}
              />
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

function InviteCard({
  code,
  canRotate,
  rotating,
  onRotate,
}: {
  code: string
  canRotate: boolean
  rotating: boolean
  onRotate: () => void
}) {
  const link = inviteLink(code)
  const canShare = typeof navigator.share === 'function'

  const copy = async (value: string, label: string) => {
    try {
      await navigator.clipboard.writeText(value)
      toast.success(`${label} copiado!`)
    } catch {
      toast.error('Não foi possível copiar. Copie manualmente.')
    }
  }

  const share = async () => {
    try {
      await navigator.share({
        title: 'Baralho da Resenha',
        text: `Bora pra resenha! Código ${code}`,
        url: link,
      })
    } catch {
      // Usuário cancelou o compartilhamento.
    }
  }

  return (
    <Card className="border-gold/30 bg-linear-to-r from-gold/[0.12] via-card/80 to-card/80 shadow-[0_0_50px_-18px_var(--gold)]">
      <CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="font-heading text-sm tracking-[0.2em] text-gold/80 uppercase">
            Código da sala
          </p>
          <p
            className="font-mono text-3xl font-black tracking-[0.12em] whitespace-nowrap text-gold text-glow sm:text-4xl"
            data-testid="room-code"
            data-code={code}
            aria-label={`Código da sala: ${code.split('').join(' ')}`}
          >
            {formatRoomCode(code)}
          </p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" className="h-10 flex-1" onClick={() => copy(code, 'Código')}>
            <CopyIcon />
            Copiar código
          </Button>
          {canShare ? (
            <Button className="h-10 flex-1" onClick={share}>
              <Share2Icon />
              Convidar
            </Button>
          ) : (
            <Button className="h-10 flex-1" onClick={() => copy(link, 'Link')}>
              <Share2Icon />
              Copiar link
            </Button>
          )}
          {canRotate && (
            <ConfirmAction
              trigger={
                <Button
                  variant="ghost"
                  size="icon-lg"
                  className="h-10"
                  disabled={rotating}
                  aria-label="Gerar código novo"
                  title="Gerar código novo"
                >
                  <RefreshCwIcon className={cn(rotating && 'animate-spin')} />
                </Button>
              }
              title="Gerar um código novo?"
              description="O código atual e o link de convite param de funcionar na hora. Quem já está na sala continua."
              confirmLabel="Gerar novo"
              onConfirm={onRotate}
            />
          )}
        </div>
      </CardContent>
    </Card>
  )
}

function SeatCard({
  player,
  isMe,
  online,
  canKick,
  onKick,
}: {
  player: RoomPlayer
  isMe: boolean
  online: boolean
  canKick: boolean
  onKick: () => void
}) {
  return (
    <li
      className={cn(
        'flex h-20 animate-in items-center gap-3 rounded-2xl px-4 panel zoom-in-95 fade-in',
        isMe && 'border-primary/60 shadow-[0_0_30px_-12px_var(--primary)]',
        player.isReady && 'border-cat-recovery/50',
      )}
      data-testid="seat"
    >
      <PlayerAvatar name={player.displayName} online={online} className="size-11" />
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-1 truncate font-heading text-lg tracking-wide">
          {player.isHost && <CrownIcon className="size-4 shrink-0 text-gold" aria-label="Host" />}
          <span className="truncate">{player.displayName}</span>
          {isMe && <span className="shrink-0 text-xs text-muted-foreground">(você)</span>}
        </p>
        <p className="text-xs text-muted-foreground">
          {player.isReady ? (
            <span className="font-semibold text-cat-recovery">Pronto</span>
          ) : (
            'Aguardando'
          )}
          {!online && ' · fora da tela'}
        </p>
      </div>
      {canKick && (
        <ConfirmAction
          trigger={
            <Button variant="ghost" size="icon-lg" aria-label={`Remover ${player.displayName}`}>
              <UserXIcon />
            </Button>
          }
          title={`Remover ${player.displayName}?`}
          description="A pessoa sai da sala e só volta se você liberar."
          confirmLabel="Remover"
          destructive
          onConfirm={onKick}
        />
      )}
    </li>
  )
}
