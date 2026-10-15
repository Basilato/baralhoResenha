import { PlusIcon, LogInIcon } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { useMyProfile } from '@/features/profile/use-profile'

// Salas chegam na Fase 3. Por enquanto o lobby só mostra o caminho.
export function LobbyPage() {
  const { data: profile } = useMyProfile()

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
            <CardTitle className="flex items-center gap-2">
              Nova resenha <Badge variant="secondary">em breve</Badge>
            </CardTitle>
            <CardDescription>Você vira o host e chama de 2 a 7 amigos.</CardDescription>
          </CardHeader>
          <CardContent>
            <Button size="lg" className="h-11 w-full" disabled>
              <PlusIcon />
              Criar resenha
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              Entrar numa sala <Badge variant="secondary">em breve</Badge>
            </CardTitle>
            <CardDescription>Peça o código para quem criou a sala.</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="flex gap-2" onSubmit={(event) => event.preventDefault()}>
              <Label htmlFor="room-code" className="sr-only">
                Código da sala
              </Label>
              <Input
                id="room-code"
                placeholder="Código da sala"
                autoCapitalize="characters"
                className="h-11"
                disabled
              />
              <Button type="submit" size="lg" variant="outline" className="h-11" disabled>
                <LogInIcon />
                Entrar
              </Button>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
