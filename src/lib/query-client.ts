import { MutationCache, QueryCache, QueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { supabase } from '@/lib/supabase'
import { isAppError } from '@/lib/errors'

// Conta desativada no meio do uso: qualquer RPC recusada encerra a sessão local.
function handleAccountErrors(error: unknown) {
  if (isAppError(error, 'ACCOUNT_DISABLED') || isAppError(error, 'NOT_AUTHENTICATED')) {
    if (isAppError(error, 'ACCOUNT_DISABLED')) {
      toast.error('Esta conta está desativada. Fale com o administrador.')
    }
    void supabase.auth.signOut({ scope: 'local' })
  }
}

export const queryClient = new QueryClient({
  queryCache: new QueryCache({ onError: handleAccountErrors }),
  mutationCache: new MutationCache({ onError: handleAccountErrors }),
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: 1,
      refetchOnWindowFocus: true,
    },
  },
})
