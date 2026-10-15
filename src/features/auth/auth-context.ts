import { createContext, useContext } from 'react'
import type { Session, User } from '@supabase/supabase-js'

export type AuthState = {
  session: Session | null
  user: User | null
  /** true até a sessão salva no navegador ser lida. */
  isLoading: boolean
}

export const AuthContext = createContext<AuthState | null>(null)

export function useAuth(): AuthState {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth precisa estar dentro de <AuthProvider>')
  return value
}
