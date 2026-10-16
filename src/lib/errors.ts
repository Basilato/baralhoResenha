import { AuthError, type PostgrestError } from '@supabase/supabase-js'

/**
 * Erro de regra vindo das RPCs: `code` é estável (ex.: ROOM_FULL) e `message`
 * é o texto em pt-BR que o banco mandou em `detail`.
 */
export class AppError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.name = 'AppError'
    this.code = code
  }
}

const FALLBACK_MESSAGES: Record<string, string> = {
  INVALID_CODE: 'Código não encontrado. Confira com quem criou a sala.',
  ROOM_NOT_FOUND: 'Sala não encontrada ou você não faz parte dela.',
  VERSION_CONFLICT: 'A sala mudou. Confira e tente de novo.',
}

/** Converte o erro do PostgREST de uma RPC em AppError quando é erro de regra. */
export function fromRpcError(error: PostgrestError): Error {
  // P0001 = raise exception das nossas funções; message traz o código.
  if (error.code === 'P0001' && /^[A-Z_]+$/.test(error.message)) {
    return new AppError(
      error.message,
      error.details || FALLBACK_MESSAGES[error.message] || 'Não foi possível concluir.',
    )
  }
  return Object.assign(new Error(error.message), { cause: error })
}

export function isAppError(error: unknown, code?: string): error is AppError {
  return error instanceof AppError && (code === undefined || error.code === code)
}

/** Converte erros técnicos em mensagens para o jogador. */
export function toFriendlyMessage(error: unknown): string {
  if (error instanceof AppError) return error.message

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
      case 'user_already_exists':
      case 'email_exists':
        return 'Esse usuário já existe. Escolha outro.'
      case 'weak_password':
        return 'Senha fraca: use pelo menos 8 caracteres.'
      case 'signup_disabled':
        return 'O cadastro está fechado. Fale com o administrador.'
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
