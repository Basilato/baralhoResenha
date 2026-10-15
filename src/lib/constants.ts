export const MIN_PLAYERS = 3
export const MAX_PLAYERS = 8
export const MAX_ROUNDS = 10

/** As cores ficam em src/index.css como --cat-<id> (e utilitários bg-cat-<id>). */
export const CARD_CATEGORIES = [
  { id: 'ataque', label: 'Ataque', description: 'Causa dano a oponentes vivos.' },
  { id: 'defesa', label: 'Defesa', description: 'Reação a um ataque contra você.' },
  {
    id: 'sabotagem',
    label: 'Sabotagem',
    description: 'Mexe na mão, nas cartas ou nos efeitos dos rivais.',
  },
  {
    id: 'caos',
    label: 'Caos',
    description: 'Efeito global ou dano especial que não conta como ataque.',
  },
  { id: 'recuperacao', label: 'Recuperação', description: 'Cura quem a usa.' },
  { id: 'reviravolta', label: 'Reviravolta', description: 'Ação ou reação, conforme a carta.' },
  { id: 'alem', label: 'Além', description: 'Só fantasmas usam, no turno de fantasma.' },
] as const

export type CardCategoryId = (typeof CARD_CATEGORIES)[number]['id']
