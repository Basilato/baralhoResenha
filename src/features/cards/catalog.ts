import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { fromRpcError } from '@/lib/errors'
import type { CardCategoryId } from '@/lib/constants'

export type CardDefinition = {
  code: string
  name: string
  characterName: string | null
  category: CardCategoryId
  deckType: 'main' | 'ghost'
  copies: number
  targetRule: string
  isReaction: boolean
  rulesText: string
  imagePath: string | null
  isProvisional: boolean
}

export type CardCatalog = ReadonlyMap<string, CardDefinition>

export async function getCardCatalog(setVersion = '7.1'): Promise<CardDefinition[]> {
  const { data, error } = await supabase.rpc('get_card_catalog', { p_set_version: setVersion })
  if (error) throw fromRpcError(error)
  return data as unknown as CardDefinition[]
}

/** O catálogo é fixo por versão: busca uma vez e mantém em cache. */
export function useCardCatalog(setVersion = '7.1') {
  return useQuery({
    queryKey: ['card-catalog', setVersion],
    queryFn: () => getCardCatalog(setVersion),
    staleTime: Infinity,
    gcTime: Infinity,
    select: (cards): { list: CardDefinition[]; byCode: CardCatalog } => ({
      list: cards,
      byCode: new Map(cards.map((card) => [card.code, card])),
    }),
  })
}
