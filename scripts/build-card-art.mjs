#!/usr/bin/env node
// Prepara as artes das cartas para o app.
//
//   pnpm art:build            (catálogo 7.1)
//   pnpm art:build -- 7.2     (outra versão do catálogo)
//
// Lê   art/cards/<versão>/source/<CÓDIGO>.png   (originais, versionados no git)
// Gera art/cards/<versão>/web/<CÓDIGO>.webp       (qualidade 85, largura máx. 1536)
//      art/cards/<versão>/web/<CÓDIGO>_thumb.webp (512×384, recorte central)
//      art/cards/<versão>/web/contact-sheet.webp  (folha de contato para revisão)
//      art/cards/<versão>/manifest.json           (o que está pronto e o que falta)
//
// Especificação completa: docs/ARTES_PROMPTS.md

import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import sharp from 'sharp'

const setVersion = process.argv[2] ?? '7.1'
const base = join('art', 'cards', setVersion)
const sourceDir = join(base, 'source')
const webDir = join(base, 'web')

// 40 faces + 2 versos (docs/ARTES_PROMPTS.md, seção 7).
const FACES = [
  ...['ATK-01', 'ATK-02', 'ATK-03', 'ATK-04', 'ATK-05', 'ATK-06', 'ATK-07'],
  ...['DEF-01', 'DEF-02', 'DEF-03', 'DEF-04', 'DEF-05', 'DEF-06', 'DEF-07'],
  ...['SAB-01', 'SAB-02', 'SAB-03', 'SAB-04', 'SAB-05', 'SAB-06', 'SAB-07'],
  ...['CAO-01', 'CAO-02', 'CAO-03', 'CAO-04', 'CAO-05'],
  ...['REC-01', 'REC-02', 'REC-03', 'REC-04', 'REC-05', 'REC-06'],
  ...['REV-01', 'REV-02', 'REV-03'],
  ...['GHO-01', 'GHO-02', 'GHO-03', 'GHO-04', 'GHO-05'],
]
const BACKS = ['BACK-MAIN', 'BACK-GHOST']

const FACE = { width: 1536, height: 1152, ratio: 4 / 3, thumb: [512, 384] }
const BACK = { width: 1575, height: 2200, ratio: 63 / 88, thumb: [450, 629] }

if (!existsSync(sourceDir)) {
  console.error(`Pasta não encontrada: ${sourceDir}`)
  process.exit(1)
}
mkdirSync(webDir, { recursive: true })

const known = new Set([...FACES, ...BACKS])
const files = readdirSync(sourceDir).filter((file) => file.toLowerCase().endsWith('.png'))
const warnings = []
const ready = []

for (const file of files.sort()) {
  const code = file.replace(/\.png$/i, '')
  if (!known.has(code)) {
    warnings.push(`${file}: nome não é um código de carta (ex.: ATK-01.png, BACK-MAIN.png)`)
    continue
  }

  const spec = code.startsWith('BACK-') ? BACK : FACE
  const input = join(sourceDir, file)
  const { width, height } = await sharp(input).metadata()

  if (Math.abs(width / height - spec.ratio) > 0.02) {
    warnings.push(
      `${code}: proporção ${width}×${height} diferente da esperada (${spec.width}×${spec.height})`,
    )
  }
  if (width < spec.width * 0.9) {
    warnings.push(
      `${code}: ${width}×${height} é menor que o recomendado (${spec.width}×${spec.height})`,
    )
  }

  // Nunca aumenta a imagem: só reduz se passar do tamanho de referência.
  await sharp(input)
    .resize({ width: spec.width, withoutEnlargement: true })
    .webp({ quality: 85 })
    .toFile(join(webDir, `${code}.webp`))

  await sharp(input)
    .resize(spec.thumb[0], spec.thumb[1], { fit: 'cover', position: 'centre' })
    .webp({ quality: 80 })
    .toFile(join(webDir, `${code}_thumb.webp`))

  ready.push({ code, width, height, storagePath: `${setVersion}/${code}.webp` })
}

// Folha de contato das faces prontas (5 por linha), para revisar de uma vez.
const faces = ready.filter((item) => !item.code.startsWith('BACK-'))
if (faces.length > 0) {
  const [tw, th] = FACE.thumb
  const columns = 5
  const rows = Math.ceil(faces.length / columns)
  const composites = await Promise.all(
    faces.map(async (item, index) => ({
      input: await sharp(join(webDir, `${item.code}_thumb.webp`)).toBuffer(),
      left: (index % columns) * tw,
      top: Math.floor(index / columns) * th,
    })),
  )
  await sharp({
    create: { width: columns * tw, height: rows * th, channels: 3, background: '#1b1530' },
  })
    .composite(composites)
    .webp({ quality: 75 })
    .toFile(join(webDir, 'contact-sheet.webp'))
}

const readyCodes = new Set(ready.map((item) => item.code))
const missing = [...FACES, ...BACKS].filter((code) => !readyCodes.has(code))

writeFileSync(
  join(base, 'manifest.json'),
  `${JSON.stringify({ setVersion, ready, missing }, null, 2)}\n`,
)

console.log(
  `Catálogo ${setVersion}: ${ready.length} de ${FACES.length + BACKS.length} artes prontas.`,
)
if (missing.length > 0) console.log(`Faltam (${missing.length}): ${missing.join(', ')}`)
for (const warning of warnings) console.log(`Aviso: ${warning}`)
