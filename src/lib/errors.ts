import { AuthError } from '@supabase/supabase-js'

/** Converte erros técnicos em mensagens para o jogador. */
export function toFriendlyMessage(error: unknown): string {
  if (error instanceof AuthError) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Usuário ou senha incorretos.'
      case 'over_request_rate_limit':
      case 'over_email_send_rate_limit':
        return 'Muitas tentativas. Espere um pouco e tente de novo.'
      case 'user_banned':
        return 'Esta conta está bloqueada. Fale com o administrador.'
      case 'email_not_confirmed':
        return 'Esta conta ainda não foi ativada. Fale com o administrador.'
    }
    if (error.status === 0 || error.name === 'AuthRetryableFetchError') {
      return 'Sem conexão com o servidor. Verifique sua internet.'
    }
  }

  if (error instanceof TypeError && error.message.includes('fetch')) {
    return 'Sem conexão com o servidor. Verifique sua internet.'
  }

  return 'Algo deu errado. Tente novamente.'
}
