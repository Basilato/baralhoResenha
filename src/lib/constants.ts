export const MIN_PLAYERS = 3
export const MAX_PLAYERS = 8
export const MAX_ROUNDS = 10
export const HAND_LIMIT = 7

/**
 * Ids iguais aos do banco (card_definitions.category). As cores ficam em
 * src/index.css como --cat-<id> (e utilitários bg-cat-<id>, text-cat-<id>).
 */
export const CARD_CATEGORIES = [
  { id: 'attack', label: 'Ataque', description: 'Causa dano a oponentes vivos.' },
  { id: 'defense', label: 'Defesa', description: 'Reação a um ataque contra você.' },
  {
    id: 'sabotage',
    label: 'Sabotagem',
    description: 'Mexe na mão, nas cartas ou nos efeitos dos rivais.',
  },
  {
    id: 'chaos',
    label: 'Caos',
    description: 'Efeito global ou dano especial que não conta como ataque.',
  },
  { id: 'recovery', label: 'Recuperação', description: 'Cura quem a usa.' },
  { id: 'reversal', label: 'Reviravolta', description: 'Ação ou reação, conforme a carta.' },
  { id: 'ghost', label: 'Além', description: 'Só fantasmas usam, no turno de fantasma.' },
] as const

export type CardCategoryId = (typeof CARD_CATEGORIES)[number]['id']

export const CATEGORY_LABEL: Record<CardCategoryId, string> = Object.fromEntries(
  CARD_CATEGORIES.map((category) => [category.id, category.label]),
) as Record<CardCategoryId, string>
