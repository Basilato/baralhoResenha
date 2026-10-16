import { useEffect } from 'react'
import { Link, Outlet, useMatch } from 'react-router'
import { toast } from 'sonner'
import { BookOpenIcon, LogOutIcon } from 'lucide-react'
import { BrandMark, BrandName } from '@/components/brand'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuCheckboxItem,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { signOut } from '@/features/auth/auth-service'
import { CardArtProvider } from '@/features/cards/card-art-provider'
import { useMyProfile } from '@/features/profile/use-profile'
import { toFriendlyMessage } from '@/lib/errors'
import { setPreferences, usePreferences } from '@/lib/preferences'
import { initials } from '@/lib/format'
import { cn } from '@/lib/utils'

async function handleSignOut() {
  try {
    await signOut()
  } catch (error) {
    toast.error(toFriendlyMessage(error))
  }
}

export function AppLayout() {
  const profile = useMyProfile()
  const preferences = usePreferences()
  // A mesa usa a tela inteira: jogadores, histórico ao lado e a mão larga.
  const wide = useMatch('/jogo/:gameId') !== null
  const width = wide ? 'max-w-7xl' : 'max-w-5xl'
  // null = conta do Auth sem perfil (provisionada sem username).
  const isInactive = profile.data === null || profile.data?.is_active === false

  // Conta desativada ou incompleta: encerra a sessão local.
  useEffect(() => {
    if (!isInactive) return
    toast.error('Esta conta está desativada. Fale com o administrador.')
    void handleSignOut()
  }, [isInactive])

  if (profile.isPending || isInactive) return <FullPageSpinner />

  const displayName = profile.data?.display_name ?? 'Jogador'

  return (
    <CardArtProvider>
      <div className="flex min-h-svh flex-col">
        <header className="sticky top-0 z-10 border-b bg-background/90 backdrop-blur">
          <div className={cn('mx-auto flex h-14 items-center justify-between gap-3 px-4', width)}>
            <Link to="/lobby" className="flex items-center gap-2">
              <BrandMark className="size-8 text-base" />
              <BrandName className="hidden text-lg sm:inline" />
            </Link>

            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="ghost" className="h-10 gap-2 px-2">
                  <Avatar className="size-7">
                    <AvatarFallback>{initials(displayName)}</AvatarFallback>
                  </Avatar>
                  <span className="max-w-32 truncate">{displayName}</span>
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-48">
                <DropdownMenuLabel className="truncate">
                  @{profile.data?.username}
                </DropdownMenuLabel>
                <DropdownMenuSeparator />
                <DropdownMenuItem asChild>
                  <Link to="/regras">
                    <BookOpenIcon />
                    Regras
                  </Link>
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuCheckboxItem
                  checked={preferences.sound}
                  onCheckedChange={(checked) => setPreferences({ sound: checked })}
                  onSelect={(event) => event.preventDefault()}
                >
                  Sons
                </DropdownMenuCheckboxItem>
                <DropdownMenuCheckboxItem
                  checked={preferences.reduceMotion}
                  onCheckedChange={(checked) => setPreferences({ reduceMotion: checked })}
                  onSelect={(event) => event.preventDefault()}
                >
                  Reduzir animações
                </DropdownMenuCheckboxItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem variant="destructive" onSelect={() => void handleSignOut()}>
                  <LogOutIcon />
                  Sair
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </header>

        <main className={cn('mx-auto w-full min-w-0 flex-1 px-4 py-6', width)}>
          {profile.isError ? (
            <p className="text-destructive">{toFriendlyMessage(profile.error)}</p>
          ) : (
            <Outlet />
          )}
        </main>
      </div>
    </CardArtProvider>
  )
}
