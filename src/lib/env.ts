import { z } from 'zod'

const envSchema = z.object({
  VITE_SUPABASE_URL: z.url(),
  VITE_SUPABASE_PUBLISHABLE_KEY: z.string().min(1),
  VITE_AUTH_EMAIL_DOMAIN: z.string().regex(/^[a-z0-9.-]+\.[a-z]{2,}$/, 'domínio inválido'),
})

const parsed = envSchema.safeParse(import.meta.env)

if (!parsed.success) {
  const fields = parsed.error.issues.map((issue) => issue.path.join('.')).join(', ')
  throw new Error(
    `Variáveis de ambiente ausentes ou inválidas: ${fields}. Copie .env.example para .env.local e preencha.`,
  )
}

export const env = parsed.data
