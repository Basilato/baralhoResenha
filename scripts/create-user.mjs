#!/usr/bin/env node
// Provisiona uma conta de jogador (uso exclusivo do administrador).
//
// Uso:
//   pnpm user:create <username> "<Nome de exibição>"
//
// Lê do arquivo .env.admin (NUNCA commitar, NUNCA usar prefixo VITE_):
//   SUPABASE_URL=https://SEU-PROJETO.supabase.co
//   SUPABASE_SECRET_KEY=sb_secret_...
//   AUTH_EMAIL_DOMAIN=contas.seudominio.com
//
// A senha é gerada aleatoriamente e mostrada uma única vez no terminal.

import { randomBytes } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'

const USERNAME_PATTERN = /^[a-z0-9_]{3,20}$/

function fail(message) {
  console.error(`Erro: ${message}`)
  process.exit(1)
}

const { SUPABASE_URL, SUPABASE_SECRET_KEY, AUTH_EMAIL_DOMAIN } = process.env
if (!SUPABASE_URL || !SUPABASE_SECRET_KEY || !AUTH_EMAIL_DOMAIN) {
  fail('defina SUPABASE_URL, SUPABASE_SECRET_KEY e AUTH_EMAIL_DOMAIN em .env.admin')
}

const [rawUsername, rawDisplayName] = process.argv.slice(2)
const username = rawUsername?.normalize('NFD').replace(/\p{M}/gu, '').trim().toLowerCase()

if (!username || !USERNAME_PATTERN.test(username)) {
  fail('username deve ter 3 a 20 caracteres: letras minúsculas, números ou _')
}

const displayName = (rawDisplayName ?? username).trim().slice(0, 32)
const password = randomBytes(9).toString('base64url')

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

const { data, error } = await admin.auth.admin.createUser({
  email: `${username}@${AUTH_EMAIL_DOMAIN}`,
  password,
  email_confirm: true,
  app_metadata: { username, display_name: displayName },
})

if (error) fail(error.message)

console.log('Conta criada:')
console.log(`  usuário: ${username}`)
console.log(`  nome:    ${displayName}`)
console.log(`  senha:   ${password}`)
console.log(`  id:      ${data.user.id}`)
console.log('Entregue a senha ao jogador por um canal privado.')
