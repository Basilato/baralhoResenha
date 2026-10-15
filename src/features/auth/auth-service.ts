import { supabase } from '@/lib/supabase'
import { usernameToAuthEmail } from './username'

export async function signIn(username: string, password: string) {
  const { error } = await supabase.auth.signInWithPassword({
    email: usernameToAuthEmail(username),
    password,
  })
  if (error) throw error
}

export async function signOut() {
  // scope 'local' encerra só este navegador; as outras abas recebem SIGNED_OUT.
  const { error } = await supabase.auth.signOut({ scope: 'local' })
  if (error) throw error
}
