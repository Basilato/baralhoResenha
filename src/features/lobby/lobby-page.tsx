import { Link, useNavigate } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation, useQuery } from '@tanstack/react-query'
import { z } from 'zod'
import { ChevronRightIcon, Loader2Icon, LogInIcon, PlusIcon } from 'lucide-react'
import { toast } from 'sonner'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { useMyProfile } from '@/features/profile/use-profile'
import {
  createRoom,
  extractRoomCode,
  joinRoom,
  listMyRooms,
  roomKeys,
  roomPath,
} from '@/features/rooms/rooms-service'
import { MAX_PLAYERS } from '@/lib/constants'
import { toFriendlyMessage } from '@/lib/errors'

const joinSchema = z.object({
  code: z
    .string()
    .transform(extractRoomCode)
    .refine((code) => code.length === 6, 'O código tem 6 letras/números.'),
})

type JoinInput = z.input<typeof joinSchema>
type JoinValues = z.output<typeof joinSchema>

export function LobbyPage() {
  const { data: profile } = useMyProfile()
  const navigate = useNavigate()

  const create = useMutation({
    mutationFn: createRoom,
    onSuccess: (room) => navigate(`/sala/${room.id}`),
    onError: (error) => toast.error(toFriendlyMessage(error)),
  })

  const form = useForm<JoinInput, unknown, JoinValues>({
    resolver: zodResolver(joinSchema),
    defaultValues: { code: '' },
  })

  const join = useMutation({
    mutationFn: ({ code }: JoinValues) => joinRoom(code),
    onSuccess: (result) => navigate(roomPath(result.gameId, result.status)),
    onError: (error) => form.setError('code', { message: toFriendlyMessage(error) }),
  })

  const codeError = form.formState.errors.code

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="font-heading text-2xl font-black tracking-tight">
          E aí, {profile?.display_name}!
        </h1>
        <p className="text-muted-foreground">Crie uma resenha ou entre com o código da sala.</p>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Nova resenha</CardTitle>
            <CardDescription>Você vira o host e chama de 2 a 7 amigos.</CardDescription>
          </CardHeader>
          <CardContent>
            <Button
              size="lg"
              className="h-11 w-full"
              disabled={create.isPending}
              onClick={() => create.mutate()}
            >
              {create.isPending ? <Loader2Icon className="animate-spin" /> : <PlusIcon />}
              Criar resenha
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Entrar numa sala</CardTitle>
            <CardDescription>Digite o código ou cole o link do convite.</CardDescription>
          </CardHeader>
          <CardContent>
            <form
              noValidate
              className="flex flex-col gap-2"
              onSubmit={form.handleSubmit((values) => join.mutate(values))}
            >
              <div className="flex gap-2">
                <Label htmlFor="room-code" className="sr-only">
                  Código da sala
                </Label>
                <Input
                  id="room-code"
                  placeholder="Ex.: K7QX2M"
                  autoCapitalize="characters"
                  autoComplete="off"
                  autoCorrect="off"
                  spellCheck={false}
                  className="h-11 font-mono tracking-widest uppercase placeholder:font-sans placeholder:tracking-normal placeholder:normal-case"
                  aria-invalid={!!codeError}
                  aria-describedby={codeError ? 'room-code-error' : undefined}
                  disabled={join.isPending}
                  {...form.register('code')}
                />
                <Button
                  type="submit"
                  size="lg"
                  variant="outline"
                  className="h-11"
                  disabled={join.isPending}
                >
                  {join.isPending ? <Loader2Icon className="animate-spin" /> : <LogInIcon />}
                  Entrar
                </Button>
              </div>
              {codeError && (
                <p id="room-code-error" className="text-sm text-destructive">
                  {codeError.message}
                </p>
              )}
            </form>
          </CardContent>
        </Card>
      </div>

      <MyRooms />
    </div>
  )
}

function MyRooms() {
  const rooms = useQuery({ queryKey: roomKeys.mine(), queryFn: listMyRooms })

  if (rooms.isPending) return <Skeleton className="h-24 w-full" />
  if (rooms.isError) {
    return <p className="text-sm text-destructive">{toFriendlyMessage(rooms.error)}</p>
  }
  if (rooms.data.length === 0) return null

  return (
    <section className="flex flex-col gap-3">
      <h2 className="font-heading text-lg font-bold">Suas resenhas abertas</h2>
      <ul className="flex flex-col gap-2">
        {rooms.data.map((room) => (
          <li key={room.id}>
            <Link
              to={roomPath(room.id, room.status)}
              className="flex items-center gap-3 rounded-xl border bg-card p-3 transition-colors hover:bg-muted"
            >
              <div className="min-w-0 flex-1">
                <p className="truncate font-medium">
                  {room.isHost ? 'Sua sala' : `Sala de ${room.hostName}`}
                </p>
                <p className="text-sm text-muted-foreground">
                  {room.playerCount}/{MAX_PLAYERS} jogadores · criada às{' '}
                  {new Date(room.createdAt).toLocaleTimeString('pt-BR', {
                    hour: '2-digit',
                    minute: '2-digit',
                  })}
                </p>
              </div>
              <Badge variant={room.status === 'playing' ? 'default' : 'secondary'}>
                {room.status === 'playing' ? 'Em jogo' : 'Esperando'}
              </Badge>
              <ChevronRightIcon className="size-4 text-muted-foreground" />
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
