#!/usr/bin/env node
// Gestão de contas de jogadores (uso exclusivo do administrador).
//
//   pnpm users create <username> "<Nome de exibição>"
//   pnpm users reset-password <username>
//   pnpm users disable <username>
//   pnpm users enable <username>
//   pnpm users list
//
// Lê do arquivo .env.admin (NUNCA commitar, NUNCA usar prefixo VITE_):
//   SUPABASE_URL=https://SEU-PROJETO.supabase.co
//   SUPABASE_SECRET_KEY=sb_secret_...
//   AUTH_EMAIL_DOMAIN=contas.seudominio.com
//
// Senhas são geradas aleatoriamente e mostradas uma única vez no terminal.

import { randomBytes } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'

const USERNAME_PATTERN = /^[a-z0-9_]{3,20}$/
// ~100 anos: o Auth não tem "banido para sempre".
const BAN_FOREVER = '876000h'

function fail(message) {
  console.error(`Erro: ${message}`)
  process.exit(1)
}

const { SUPABASE_URL, SUPABASE_SECRET_KEY, AUTH_EMAIL_DOMAIN } = process.env
if (!SUPABASE_URL || !SUPABASE_SECRET_KEY || !AUTH_EMAIL_DOMAIN) {
  fail('defina SUPABASE_URL, SUPABASE_SECRET_KEY e AUTH_EMAIL_DOMAIN em .env.admin')
}

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

function normalizeUsername(raw) {
  const username = raw?.normalize('NFD').replace(/\p{M}/gu, '').trim().toLowerCase()
  if (!username || !USERNAME_PATTERN.test(username)) {
    fail('username deve ter 3 a 20 caracteres: letras minúsculas, números ou _')
  }
  return username
}

function generatePassword() {
  return randomBytes(9).toString('base64url')
}

async function findProfile(username) {
  const { data, error } = await admin
    .from('profiles')
    .select('id, username, display_name, is_active')
    .eq('username', username)
    .maybeSingle()
  if (error) fail(error.message)
  if (!data) fail(`usuário "${username}" não encontrado`)
  return data
}

async function create(rawUsername, rawDisplayName) {
  const username = normalizeUsername(rawUsername)
  const displayName = (rawDisplayName ?? username).trim().slice(0, 32) || username
  const password = generatePassword()

  const { data, error } = await admin.auth.admin.createUser({
    email: `${username}@${AUTH_EMAIL_DOMAIN}`,
    password,
    email_confirm: true,
    app_metadata: { username, display_name: displayName },
  })
  if (error) fail(error.code === 'email_exists' ? `"${username}" já existe` : error.message)

  console.log('Conta criada:')
  console.log(`  usuário: ${username}`)
  console.log(`  nome:    ${displayName}`)
  console.log(`  senha:   ${password}`)
  console.log(`  id:      ${data.user.id}`)
  console.log('Entregue a senha ao jogador por um canal privado.')
}

async function resetPassword(rawUsername) {
  const profile = await findProfile(normalizeUsername(rawUsername))
  const password = generatePassword()

  const { error } = await admin.auth.admin.updateUserById(profile.id, { password })
  if (error) fail(error.message)

  console.log(`Nova senha de ${profile.username}: ${password}`)
  console.log('Entregue a senha ao jogador por um canal privado.')
}

async function setActive(rawUsername, active) {
  const profile = await findProfile(normalizeUsername(rawUsername))

  // O ban impede novo login e a renovação do token; is_active derruba a sessão
  // aberta no app na próxima leitura do perfil.
  const { error: authError } = await admin.auth.admin.updateUserById(profile.id, {
    ban_duration: active ? 'none' : BAN_FOREVER,
  })
  if (authError) fail(authError.message)

  const { error } = await admin.from('profiles').update({ is_active: active }).eq('id', profile.id)
  if (error) fail(error.message)

  console.log(`${profile.username} ${active ? 'reativado' : 'desativado'}.`)
}

async function list() {
  const { data, error } = await admin
    .from('profiles')
    .select('username, display_name, is_active, created_at')
    .order('username')
  if (error) fail(error.message)
  console.table(
    data.map((p) => ({
      usuário: p.username,
      nome: p.display_name,
      ativo: p.is_active ? 'sim' : 'não',
      criado: p.created_at.slice(0, 10),
    })),
  )
}

const [command, ...args] = process.argv.slice(2)

switch (command) {
  case 'create':
    await create(args[0], args[1])
    break
  case 'reset-password':
    await resetPassword(args[0])
    break
  case 'disable':
    await setActive(args[0], false)
    break
  case 'enable':
    await setActive(args[0], true)
    break
  case 'list':
    await list()
    break
  default:
    fail('comando inválido. Use: create, reset-password, disable, enable ou list')
}
