import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database.generated'
import { env } from '@/lib/env'

export const supabase = createClient<Database>(
  env.VITE_SUPABASE_URL,
  env.VITE_SUPABASE_PUBLISHABLE_KEY,
)
