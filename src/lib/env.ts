// Validação à mão (sem zod): este arquivo roda antes de qualquer tela, e o zod
// pesaria ~75 KB no carregamento inicial só por três variáveis.
const checks = {
  VITE_SUPABASE_URL: isUrl,
  VITE_SUPABASE_PUBLISHABLE_KEY: (value: string) => value.length > 0,
  VITE_AUTH_EMAIL_DOMAIN: (value: string) => /^[a-z0-9.-]+\.[a-z]{2,}$/.test(value),
} satisfies Record<string, (value: string) => boolean>

// URL.canParse só existe a partir do Safari 17.
function isUrl(value: string) {
  try {
    return new URL(value).protocol !== ''
  } catch {
    return false
  }
}

type Env = { [K in keyof typeof checks]: string }

function parseEnv(source: Record<string, unknown>): Env {
  const invalid = Object.entries(checks)
    .filter(([key, isValid]) => {
      const value = source[key]
      return typeof value !== 'string' || !isValid(value)
    })
    .map(([key]) => key)

  if (invalid.length > 0) {
    throw new Error(
      `Variáveis de ambiente ausentes ou inválidas: ${invalid.join(', ')}. Copie .env.example para .env.local e preencha.`,
    )
  }
  return Object.fromEntries(Object.keys(checks).map((key) => [key, source[key]])) as Env
}

export const env = parseEnv(import.meta.env)
