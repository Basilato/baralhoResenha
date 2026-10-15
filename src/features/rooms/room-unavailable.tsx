import { Link } from 'react-router'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { toFriendlyMessage } from '@/lib/errors'

/** Sala encerrada, inexistente ou de que a pessoa não faz parte. */
export function RoomUnavailable({ error, closed }: { error?: unknown; closed?: boolean }) {
  return (
    <Card className="mx-auto mt-8 max-w-md text-center">
      <CardHeader>
        <CardTitle>{closed ? 'Essa resenha acabou' : 'Não deu para abrir a sala'}</CardTitle>
        <CardDescription>
          {closed ? 'A sala foi encerrada pelo host.' : toFriendlyMessage(error)}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <Button asChild>
          <Link to="/lobby">Voltar ao lobby</Link>
        </Button>
      </CardContent>
    </Card>
  )
}
