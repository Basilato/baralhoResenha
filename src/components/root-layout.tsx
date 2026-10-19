import { Outlet } from 'react-router'
import { NavigationProgress } from '@/components/navigation-progress'

/** Raiz de todas as rotas: a barra de carregamento fica acima de qualquer tela. */
export function RootLayout() {
  return (
    <>
      <NavigationProgress />
      <Outlet />
    </>
  )
}
