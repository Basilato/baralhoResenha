#!/usr/bin/env node
// Verificação de produção (Fase 11). Só lê e tenta coisas que DEVEM falhar;
// não cria, não altera e não apaga nada.
//
//   pnpm prod:check
//
// Lê .env.production.admin (NUNCA commitar):
//   SUPABASE_URL=https://SEU-PROJETO.supabase.co
//   SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
//   SUPABASE_SECRET_KEY=sb_secret_...
//   AUTH_EMAIL_DOMAIN=...
//   APP_URL=https://baralho-resenha.vercel.app

import { createClient } from '@supabase/supabase-js'

const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SECRET_KEY, AUTH_EMAIL_DOMAIN, APP_URL } =
  process.env

const missing = Object.entries({
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY,
  SUPABASE_SECRET_KEY,
  AUTH_EMAIL_DOMAIN,
  APP_URL,
})
  .filter(([, value]) => !value)
  .map(([name]) => name)
if (missing.length > 0) {
  console.error(`Faltam em .env.production.admin: ${missing.join(', ')}`)
  process.exit(1)
}

const anon = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
})
const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
})

const results = []
async function check(name, fn) {
  try {
    const detail = await fn()
    results.push({ ok: true, name, detail })
  } catch (error) {
    results.push({ ok: false, name, detail: error.message })
  }
}
const assert = (condition, message) => {
  if (!condition) throw new Error(message)
}

// --- Site ---------------------------------------------------------------------

await check('site responde com HTTPS', async () => {
  assert(APP_URL.startsWith('https://'), 'APP_URL precisa ser https://')
  const response = await fetch(APP_URL)
  assert(response.ok, `status ${response.status}`)
  return `${response.status}`
})

await check('rotas do app abrem direto (rewrite da SPA)', async () => {
  const response = await fetch(new URL('/lobby', APP_URL))
  assert(response.ok, `/lobby respondeu ${response.status}`)
  assert((await response.text()).includes('<div id="root">'), 'não devolveu o index.html')
})

await check('cabeçalhos de segurança', async () => {
  const response = await fetch(APP_URL)
  for (const header of ['x-frame-options', 'x-content-type-options', 'referrer-policy']) {
    assert(response.headers.get(header), `falta ${header}`)
  }
})

await check('site aponta para este Supabase', async () => {
  const html = await (await fetch(APP_URL)).text()
  const script = html.match(/src="(\/assets\/[^"]+\.js)"/)?.[1]
  assert(script, 'não achei o bundle principal')
  const bundle = await (await fetch(new URL(script, APP_URL))).text()
  assert(bundle.includes(new URL(SUPABASE_URL).host), 'o bundle usa outro SUPABASE_URL')
  assert(!bundle.includes('127.0.0.1:54321'), 'o bundle ainda aponta para o Supabase local')
  assert(!bundle.includes(SUPABASE_SECRET_KEY), 'A SECRET KEY ESTÁ NO BUNDLE')
})

// --- Supabase: o que precisa estar fechado -------------------------------------

await check('cadastro público desligado', async () => {
  // Lê a configuração pública do Auth. (Tentar um cadastro criaria uma conta
  // de verdade justamente quando o cadastro estiver aberto.)
  const response = await fetch(`${SUPABASE_URL}/auth/v1/settings`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY },
  })
  assert(response.ok, `settings respondeu ${response.status}`)
  const settings = await response.json()
  assert(
    settings.disable_signup === true,
    'qualquer pessoa consegue criar conta (desligue "Allow new users to sign up")',
  )
})

await check('sem login, nenhuma RPC do jogo responde', async () => {
  const { error } = await anon.rpc('get_card_catalog', { p_set_version: '7.1' })
  assert(error, 'get_card_catalog respondeu sem login')
})

await check('tabelas internas fora da API', async () => {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/games?select=id&limit=1`, {
    headers: { apikey: SUPABASE_PUBLISHABLE_KEY },
  })
  assert(!response.ok, 'app_private.games está exposta pela API')
  return `${response.status}`
})

await check('artes não são públicas', async () => {
  const response = await fetch(`${SUPABASE_URL}/storage/v1/object/public/card-art/7.1/ATK-01.webp`)
  assert(!response.ok, 'o bucket card-art está público')
  return `${response.status}`
})

// --- Supabase: o que precisa estar lá -----------------------------------------

await check('migrações aplicadas até a última', async () => {
  const { data, error } = await admin.rpc('admin_check_game_integrity', {
    p_game_id: crypto.randomUUID(),
  })
  assert(!error, `admin_check_game_integrity: ${error?.message}`)
  assert(data?.[0] === 'partida não existe', 'resposta inesperada')
})

await check('artes enviadas', async () => {
  const { data, error } = await admin.storage.from('card-art').list('7.1', { limit: 200 })
  assert(!error, error?.message)
  const faces = (data ?? []).filter((file) => /^[A-Z]{3}-\d{2}\.webp$/.test(file.name))
  assert(faces.length > 0, 'nenhuma arte no bucket (rode pnpm art:upload:prod)')
  return `${faces.length} de 35 faces`
})

await check('contas de teste do seed NÃO existem', async () => {
  const { data, error } = await admin.auth.admin.listUsers({ perPage: 1000 })
  assert(!error, error?.message)
  const seed = data.users.filter((user) => /^teste\d+@/.test(user.email ?? ''))
  assert(seed.length === 0, `${seed.length} contas teste* em produção`)
  return `${data.users.length} contas`
})

// --- Resultado ----------------------------------------------------------------

for (const result of results) {
  const detail = result.detail ? ` (${result.detail})` : ''
  console.log(`${result.ok ? '✔' : '✘'} ${result.name}${detail}`)
}
const failed = results.filter((result) => !result.ok).length
console.log(failed === 0 ? '\nProdução OK.' : `\n${failed} verificação(ões) falharam.`)
process.exitCode = failed === 0 ? 0 : 1
