import { isRouteErrorResponse, Link, useRouteError } from 'react-router'
import { Button } from '@/components/ui/button'

export function RouteError() {
  const error = useRouteError()
  // Sem erro de rota = renderizado pela rota curinga (*), ou seja, 404.
  const notFound = !error || (isRouteErrorResponse(error) && error.status === 404)

  if (!notFound) console.error(error)

  return (
    <div className="flex min-h-svh flex-col items-center justify-center gap-4 px-4 text-center">
      <h1 className="font-heading text-2xl font-black">
        {notFound ? 'Essa página não existe' : 'Deu ruim por aqui'}
      </h1>
      <p className="max-w-sm text-muted-foreground">
        {notFound
          ? 'Confira o endereço ou volte para o lobby.'
          : 'Um erro inesperado aconteceu. Recarregue a página ou volte para o lobby.'}
      </p>
      <Button asChild>
        <Link to="/lobby">Voltar ao lobby</Link>
      </Button>
    </div>
  )
}
