import { Navigate, useNavigate, useParams } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { toast } from 'sonner'
import { XCircleIcon } from 'lucide-react'
import { ConfirmAction } from '@/components/confirm-action'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { PlayerAvatar } from '@/components/player-avatar'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/features/auth/auth-context'
import { closeRoom } from '@/features/rooms/rooms-service'
import { RoomUnavailable } from '@/features/rooms/room-unavailable'
import { useGameChannel, useRoomView } from '@/features/rooms/use-room'
import { toFriendlyMessage } from '@/lib/errors'

// Mesa provisória: a partida em si (cartas, turnos) chega nas Fases 4 e 5.
export function GamePage() {
  const { gameId } = useParams<{ gameId: string }>()
  const { user } = useAuth()
  const navigate = useNavigate()
  const channel = useGameChannel(gameId)
  const room = useRoomView(gameId, channel.status)

  const close = useMutation({
    mutationFn: () => closeRoom(gameId!),
    onSuccess: () => {
      toast.success('Partida encerrada.')
      navigate('/lobby', { replace: true })
    },
    onError: (error) => toast.error(toFriendlyMessage(error)),
  })

  if (room.isPending) return <FullPageSpinner />
  if (!room.data) return <RoomUnavailable error={room.error} />
  if (room.data.status === 'lobby') return <Navigate to={`/sala/${room.data.id}`} replace />
  if (room.data.status !== 'playing') return <RoomUnavailable closed />

  const isHost = room.data.hostUserId === user?.id

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="font-heading text-2xl font-black tracking-tight">A resenha começou!</h1>
        <p className="text-muted-foreground">
          A mesa com cartas e turnos chega nas próximas fases. Por enquanto, quem está jogando:
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Jogadores</CardTitle>
          <CardDescription>Ordem dos assentos, no sentido horário.</CardDescription>
        </CardHeader>
        <CardContent>
          <ol className="grid gap-3 sm:grid-cols-2">
            {room.data.players.map((player) => (
              <li key={player.id} className="flex items-center gap-3" data-testid="table-player">
                <span className="w-5 text-right text-sm text-muted-foreground">{player.seat}</span>
                <PlayerAvatar
                  name={player.displayName}
                  online={channel.onlineUserIds.has(player.userId)}
                />
                <span className="font-medium">{player.displayName}</span>
              </li>
            ))}
          </ol>
        </CardContent>
      </Card>

      {isHost && (
        <ConfirmAction
          trigger={
            <Button variant="outline" className="h-10 self-start text-destructive">
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
  )
}
