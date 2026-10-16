import { useEffect } from 'react'
import { Link, Outlet, useMatch } from 'react-router'
import { toast } from 'sonner'
import { BookOpenIcon, GraduationCapIcon, LogOutIcon } from 'lucide-react'
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
import { TutorialDialog } from '@/features/rules/tutorial'
import { useTutorial } from '@/features/rules/use-tutorial'
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
  const tutorial = useTutorial()
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
        <header className="sticky top-0 z-20 border-b border-white/[0.07] bg-[oklch(0.13_0.035_285/0.96)] shadow-[0_10px_30px_-20px_oklch(0_0_0/0.9)]">
          <div className={cn('mx-auto flex h-14 items-center justify-between gap-3 px-4', width)}>
            <Link to="/lobby" className="group flex items-center gap-3">
              <BrandMark className="h-9 text-lg transition-transform group-hover:-rotate-3" />
              <BrandName className="hidden text-xl sm:inline" />
            </Link>

            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button
                  variant="ghost"
                  className="h-10 gap-2 rounded-full border border-white/10 bg-white/[0.04] pr-3 pl-1"
                >
                  <Avatar className="size-8">
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
                <DropdownMenuItem onSelect={() => tutorial.setOpen(true)}>
                  <GraduationCapIcon />
                  Como jogar
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
        <TutorialDialog open={tutorial.open} onOpenChange={tutorial.setOpen} />
      </div>
    </CardArtProvider>
  )
}
