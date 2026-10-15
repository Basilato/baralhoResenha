import { useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { AuthContext, type AuthState } from './auth-context'

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const [session, setSession] = useState<Session | null>(null)
  const [isLoading, setIsLoading] = useState(true)

  useEffect(() => {
    let active = true

    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      setSession(data.session)
      setIsLoading(false)
    })

    // Também recebe eventos de outras abas (login/logout) e de refresh do token.
    // Se o refresh falhar (sessão expirada), chega SIGNED_OUT e os guardas
    // levam o usuário de volta ao login.
    const { data } = supabase.auth.onAuthStateChange((event, nextSession) => {
      setSession(nextSession)
      setIsLoading(false)
      if (event === 'SIGNED_OUT') queryClient.clear()
    })

    return () => {
      active = false
      data.subscription.unsubscribe()
    }
  }, [queryClient])

  const value = useMemo<AuthState>(
    () => ({ session, user: session?.user ?? null, isLoading }),
    [session, isLoading],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}
