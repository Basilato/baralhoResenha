import { AppError } from '@/lib/errors'
import { supabase } from '@/lib/supabase'
import { normalizeUsername, usernameToAuthEmail } from './username'

export async function signIn(username: string, password: string) {
  const { error } = await supabase.auth.signInWithPassword({
    email: usernameToAuthEmail(username),
    password,
  })
  if (error) throw error
}

/**
 * Autocadastro: cria a conta já logada. Usuário e nome vão no user_metadata;
 * o banco cria o perfil a partir deles (migração self_signup).
 */
export async function signUp(username: string, displayName: string, password: string) {
  const normalized = normalizeUsername(username)
  const { data, error } = await supabase.auth.signUp({
    email: usernameToAuthEmail(normalized),
    password,
    options: { data: { username: normalized, display_name: displayName.trim() } },
  })
  if (error) throw error
  // Com "Confirm email" ligado no Supabase, a conta nasce sem sessão e esperaria
  // um e-mail que nunca chega (o e-mail é técnico).
  if (!data.session) {
    throw new AppError(
      'SIGNUP_NEEDS_CONFIRMATION',
      'Conta criada, mas ainda precisa ser ativada. Fale com o administrador.',
    )
  }
}

export async function signOut() {
  // scope 'local' encerra só este navegador; as outras abas recebem SIGNED_OUT.
  const { error } = await supabase.auth.signOut({ scope: 'local' })
  if (error) throw error
}
