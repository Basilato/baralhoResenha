import { env } from '@/lib/env'

export const USERNAME_PATTERN = /^[a-z0-9_]{3,20}$/

/** Minúsculas, sem acentos e sem espaços nas pontas: "  Léo " → "leo". */
export function normalizeUsername(raw: string): string {
  return raw.normalize('NFD').replace(/\p{M}/gu, '').trim().toLowerCase()
}

export function isValidUsername(username: string): boolean {
  return USERNAME_PATTERN.test(username)
}

/**
 * O Supabase Auth só aceita senha com e-mail ou telefone. Cada username
 * corresponde a um e-mail técnico sob o domínio do projeto; o jogador nunca o vê.
 */
export function usernameToAuthEmail(
  username: string,
  domain: string = env.VITE_AUTH_EMAIL_DOMAIN,
): string {
  return `${normalizeUsername(username)}@${domain}`
}
