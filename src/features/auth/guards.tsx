import { Navigate, Outlet, useLocation } from 'react-router-dom'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { useAuth } from './auth-context'

export type RedirectState = { from?: string }

/** Só renderiza as rotas filhas com sessão ativa. O banco revalida tudo. */
export function RequireAuth() {
  const { session, isLoading } = useAuth()
  const location = useLocation()

  if (isLoading) return <FullPageSpinner />
  if (!session) {
    const state: RedirectState = { from: location.pathname + location.search }
    return <Navigate to="/login" replace state={state} />
  }
  return <Outlet />
}

/** Leva quem já está logado direto para o lobby. */
export function RedirectIfAuthenticated() {
  const { session, isLoading } = useAuth()
  const location = useLocation()
  const from = (location.state as RedirectState | null)?.from

  if (isLoading) return <FullPageSpinner />
  if (session) return <Navigate to={from ?? '/lobby'} replace />
  return <Outlet />
}
