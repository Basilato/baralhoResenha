import { describe, expect, it } from 'vitest'
import { isValidUsername, normalizeUsername, usernameToAuthEmail } from './username'

describe('normalizeUsername', () => {
  it('remove acentos, espaços nas pontas e maiúsculas', () => {
    expect(normalizeUsername('  Léo ')).toBe('leo')
    expect(normalizeUsername('JOÃO_123')).toBe('joao_123')
    expect(normalizeUsername('Çaça')).toBe('caca')
  })
})

describe('isValidUsername', () => {
  it.each(['leo', 'teste_1', 'a1b2c3d4e5f6g7h8i9j0'])('aceita %s', (value) => {
    expect(isValidUsername(value)).toBe(true)
  })

  it.each(['', 'ab', 'com espaço', 'leo@x', 'Maiusculo', 'a'.repeat(21)])(
    'recusa "%s"',
    (value) => {
      expect(isValidUsername(value)).toBe(false)
    },
  )
})

describe('usernameToAuthEmail', () => {
  it('monta o e-mail técnico com o domínio informado', () => {
    expect(usernameToAuthEmail(' Léo ', 'contas.exemplo.com')).toBe('leo@contas.exemplo.com')
  })
})
