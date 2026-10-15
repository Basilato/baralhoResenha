import { describe, expect, it } from 'vitest'
import type { PostgrestError } from '@supabase/supabase-js'
import { AppError, fromRpcError, toFriendlyMessage } from './errors'

const pgError = (fields: Partial<PostgrestError>) =>
  ({
    code: '',
    message: '',
    details: '',
    hint: '',
    name: 'PostgrestError',
    ...fields,
  }) as PostgrestError

describe('fromRpcError', () => {
  it('transforma erro de regra em AppError com a mensagem do banco', () => {
    const error = fromRpcError(
      pgError({
        code: 'P0001',
        message: 'ROOM_FULL',
        details: 'A sala já está cheia (8 pessoas).',
      }),
    )
    expect(error).toBeInstanceOf(AppError)
    expect((error as AppError).code).toBe('ROOM_FULL')
    expect(toFriendlyMessage(error)).toBe('A sala já está cheia (8 pessoas).')
  })

  it('não expõe erros técnicos do banco ao jogador', () => {
    const error = fromRpcError(
      pgError({ code: '42501', message: 'permission denied for function x' }),
    )
    expect(error).not.toBeInstanceOf(AppError)
    expect(toFriendlyMessage(error)).toBe('Algo deu errado. Tente novamente.')
  })
})
