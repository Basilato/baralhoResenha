import { Link, useNavigate } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation, useQuery } from '@tanstack/react-query'
import { z } from 'zod'
import { ChevronRightIcon, Loader2Icon, LogInIcon, PlusIcon, TicketIcon } from 'lucide-react'
import { toast } from 'sonner'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Skeleton } from '@/components/ui/skeleton'
import { useCardCatalog } from '@/features/cards/catalog'
import { GameCard } from '@/features/cards/game-card'
import { useMyProfile } from '@/features/profile/use-profile'
import {
  createRoom,
  extractRoomCode,
  joinRoom,
  listMyRooms,
  roomKeys,
  ROOM_CODE_LENGTH,
  roomPath,
} from '@/features/rooms/rooms-service'
import { MAX_PLAYERS } from '@/lib/constants'
import { toFriendlyMessage } from '@/lib/errors'
import { cn } from '@/lib/utils'

const joinSchema = z.object({
  code: z
    .string()
    .transform(extractRoomCode)
    .refine(
      (code) => code.length === ROOM_CODE_LENGTH,
      `O código tem ${ROOM_CODE_LENGTH} letras e números.`,
    ),
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
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-1">
        <p className="font-heading text-sm tracking-[0.25em] text-muted-foreground uppercase">
          Bem-vindo à mesa
        </p>
        <h1 className="text-4xl sm:text-5xl">
          E aí, <span className="text-gradient-brand">{profile?.display_name}</span>!
        </h1>
        <p className="text-muted-foreground">Crie uma resenha ou entre com o código da sala.</p>
      </div>

      <div className="grid gap-5 md:grid-cols-[1.25fr_1fr]">
        {/* Nova resenha: o bloco principal, com um leque de cartas de verdade. */}
        <Card className="relative min-h-[23rem] justify-end border-primary/30 shadow-[0_0_60px_-20px_var(--primary)] sm:min-h-64">
          <CardFan />
          <CardHeader className="relative">
            <CardTitle className="text-3xl">Nova resenha</CardTitle>
            <CardDescription>Você vira o host e chama de 2 a 7 amigos.</CardDescription>
          </CardHeader>
          <CardContent className="relative">
            <Button
              variant="gold"
              size="lg"
              className="h-12 w-full text-lg sm:w-auto sm:px-8"
              disabled={create.isPending}
              onClick={() => create.mutate()}
            >
              {create.isPending ? <Loader2Icon className="animate-spin" /> : <PlusIcon />}
              Criar resenha
            </Button>
          </CardContent>
        </Card>

        <Card className="justify-center">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-2xl">
              <TicketIcon className="size-6 text-neon" aria-hidden />
              Entrar numa sala
            </CardTitle>
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
                  placeholder="Ex.: K7QX2 M9PLA"
                  autoCapitalize="characters"
                  autoComplete="off"
                  autoCorrect="off"
                  spellCheck={false}
                  className="h-12 border-dashed border-white/20 font-mono text-lg tracking-[0.2em] uppercase placeholder:font-sans placeholder:text-sm placeholder:tracking-normal placeholder:normal-case"
                  aria-invalid={!!codeError}
                  aria-describedby={codeError ? 'room-code-error' : undefined}
                  disabled={join.isPending}
                  {...form.register('code')}
                />
                <Button type="submit" size="lg" className="h-12" disabled={join.isPending}>
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

/** Três cartas em leque no canto do bloco "Nova resenha" (só enfeite). */
function CardFan() {
  const catalog = useCardCatalog()
  const cards = ['ATK-05', 'REV-02', 'GHO-02']
    .map((code) => catalog.data?.byCode.get(code))
    .filter((card) => card !== undefined)
  if (cards.length === 0) return null
  return (
    <div
      className="pointer-events-none absolute top-6 right-4 flex max-sm:top-4 max-sm:opacity-50 sm:right-8"
      aria-hidden
    >
      {cards.map((card, index) => (
        <div
          key={card.code}
          className="-ml-12 origin-bottom first:ml-0"
          style={{
            transform: `rotate(${(index - 1) * 10}deg) translateY(${index === 1 ? -6 : 8}px)`,
            zIndex: index === 1 ? 2 : 1,
          }}
        >
          <GameCard card={card} size="sm" className="shadow-2xl" />
        </div>
      ))}
    </div>
  )
}

function MyRooms() {
  // Sempre fresco ao abrir o lobby: a lista muda fora desta tela.
  const rooms = useQuery({ queryKey: roomKeys.mine(), queryFn: listMyRooms, staleTime: 0 })

  if (rooms.isPending) return <Skeleton className="h-24 w-full" />
  if (rooms.isError) {
    return <p className="text-sm text-destructive">{toFriendlyMessage(rooms.error)}</p>
  }
  if (rooms.data.length === 0) return null

  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-2xl">Suas resenhas abertas</h2>
      <ul className="grid gap-3 sm:grid-cols-2">
        {rooms.data.map((room) => (
          <li key={room.id}>
            <Link
              to={roomPath(room.id, room.status)}
              className="group flex items-center gap-3 rounded-2xl p-4 panel transition hover:-translate-y-0.5 hover:border-primary/40"
            >
              <span
                className={cn(
                  'size-2.5 shrink-0 rounded-full',
                  room.status === 'playing'
                    ? 'animate-pulse bg-cat-recovery shadow-[0_0_10px_var(--cat-recovery)]'
                    : 'bg-gold shadow-[0_0_10px_var(--gold)]',
                )}
                aria-hidden
              />
              <div className="min-w-0 flex-1">
                <p className="truncate font-heading text-lg tracking-wide">
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
              <ChevronRightIcon className="size-5 text-muted-foreground transition group-hover:translate-x-0.5 group-hover:text-foreground" />
            </Link>
          </li>
        ))}
      </ul>
    </section>
  )
}
