import { createContext, useContext } from 'react'

export type CardArtVariant = 'full' | 'thumb'

/** URLs assinadas por caminho no Storage (`7.1/ATK-01.webp`, `7.1/ATK-01_thumb.webp`). */
export type CardArtUrls = ReadonlyMap<string, string>

// Fora do provider (testes, telas sem login) não há arte: as cartas mostram o placeholder.
export const CardArtContext = createContext<CardArtUrls>(new Map())

/** Caminho da miniatura: `7.1/ATK-01.webp` → `7.1/ATK-01_thumb.webp`. */
export function thumbPath(imagePath: string): string {
  return imagePath.replace(/\.webp$/, '_thumb.webp')
}

/** URL da arte da carta, se ela tiver arte e a URL já estiver pronta. */
export function useCardArtUrl(
  imagePath: string | null,
  variant: CardArtVariant,
): string | undefined {
  const urls = useContext(CardArtContext)
  if (!imagePath) return undefined
  return urls.get(variant === 'thumb' ? thumbPath(imagePath) : imagePath)
}
