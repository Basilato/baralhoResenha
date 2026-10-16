import { useMemo, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { useCardCatalog } from './catalog'
import { CARD_BACK_PATH, CardArtContext, thumbPath, type CardArtUrls } from './card-art-context'

const BUCKET = 'card-art'
// O bucket é privado (plano, 9.3): URLs assinadas de curta duração, renovadas antes de vencer.
const URL_TTL_SECONDS = 60 * 60
const REFRESH_MS = 50 * 60 * 1000

async function signCardArt(paths: string[]): Promise<Map<string, string>> {
  const { data, error } = await supabase.storage
    .from(BUCKET)
    .createSignedUrls(paths, URL_TTL_SECONDS)
  if (error) throw error
  const urls = new Map<string, string>()
  for (const item of data) {
    if (item.path && item.signedUrl && !item.error) urls.set(item.path, item.signedUrl)
  }
  return urls
}

/**
 * Assina de uma vez as URLs de todas as artes do catálogo (inteira + miniatura).
 * Carta sem arte, ou com falha ao assinar, continua com o placeholder (C2).
 */
export function CardArtProvider({ children }: { children: ReactNode }) {
  const catalog = useCardCatalog()

  const paths = useMemo(
    () =>
      [
        ...(catalog.data?.list ?? []).map((card) => card.imagePath),
        ...Object.values(CARD_BACK_PATH),
      ]
        .flatMap((path) => (path ? [path, thumbPath(path)] : []))
        .sort(),
    [catalog.data],
  )

  const signed = useQuery({
    queryKey: ['card-art-urls', paths],
    queryFn: () => signCardArt(paths),
    enabled: paths.length > 0,
    staleTime: REFRESH_MS,
    refetchInterval: REFRESH_MS,
  })

  const urls: CardArtUrls = signed.data ?? EMPTY
  return <CardArtContext value={urls}>{children}</CardArtContext>
}

const EMPTY: CardArtUrls = new Map()
