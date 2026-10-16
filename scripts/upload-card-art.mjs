#!/usr/bin/env node
// Envia as artes prontas para o Storage e liga cada carta à sua arte.
// Uso exclusivo do administrador. Rode `pnpm art:build` antes.
//
//   pnpm art:upload            (catálogo 7.1)
//   pnpm art:upload -- 7.2     (outra versão do catálogo)
//
// Lê art/cards/<versão>/manifest.json e envia, para o bucket privado `card-art`:
//   <versão>/<CÓDIGO>.webp e <versão>/<CÓDIGO>_thumb.webp
// Depois chama admin_set_card_art, que preenche image_path das cartas enviadas.
// Rodar de novo é seguro: sobrescreve os arquivos e refaz a marcação.
//
// Lê do arquivo .env.admin (NUNCA commitar, NUNCA usar prefixo VITE_):
//   SUPABASE_URL=https://SEU-PROJETO.supabase.co
//   SUPABASE_SECRET_KEY=sb_secret_...

import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { createClient } from '@supabase/supabase-js'

const BUCKET = 'card-art'
const setVersion = process.argv[2] ?? '7.1'
const base = join('art', 'cards', setVersion)
const manifestPath = join(base, 'manifest.json')

const { SUPABASE_URL, SUPABASE_SECRET_KEY } = process.env
if (!SUPABASE_URL || !SUPABASE_SECRET_KEY) {
  console.error('Erro: defina SUPABASE_URL e SUPABASE_SECRET_KEY em .env.admin')
  process.exit(1)
}
if (!existsSync(manifestPath)) {
  console.error(`Não encontrei ${manifestPath}. Rode \`pnpm art:build\` antes.`)
  process.exit(1)
}

const admin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
})

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
// Faces ficam ligadas às cartas do catálogo; versos (BACK-*) só vão para o
// Storage, e o app os encontra pelo caminho fixo (card-art-context.ts).
const faces = manifest.ready.filter((item) => !item.code.startsWith('BACK-'))
const backs = manifest.ready.filter((item) => item.code.startsWith('BACK-'))

async function upload(fileName) {
  const path = join(base, 'web', fileName)
  if (!existsSync(path)) throw new Error(`${path} não existe. Rode \`pnpm art:build\`.`)
  const { error } = await admin.storage
    .from(BUCKET)
    .upload(`${setVersion}/${fileName}`, readFileSync(path), {
      contentType: 'image/webp',
      cacheControl: '86400',
      upsert: true,
    })
  if (error) throw new Error(`${fileName}: ${error.message}`)
}

try {
  for (const { code } of [...faces, ...backs]) {
    await upload(`${code}.webp`)
    await upload(`${code}_thumb.webp`)
    console.log(`Enviada: ${code}`)
  }

  const { data: linked, error } = await admin.rpc('admin_set_card_art', {
    p_set_version: setVersion,
    p_codes: faces.map((item) => item.code),
  })
  if (error) throw new Error(`admin_set_card_art: ${error.message}`)

  console.log(`Catálogo ${setVersion}: ${linked} cartas com arte.`)
} catch (error) {
  console.error(`Erro: ${error.message}`)
  process.exitCode = 1
}
