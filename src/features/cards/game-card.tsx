import { GhostIcon, ZapIcon } from 'lucide-react'
import { CATEGORY_LABEL } from '@/lib/constants'
import { initials } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { CardDefinition } from './catalog'
import { CATEGORY_ICON } from './category-icons'

type CardSize = 'sm' | 'md' | 'lg'

const SIZE: Record<CardSize, string> = {
  sm: 'w-24 rounded-lg text-[0.6rem]',
  md: 'w-36 rounded-xl text-xs',
  lg: 'w-64 rounded-2xl text-sm sm:w-72',
}

/**
 * Face de uma carta. Sem arte (imageUrl), desenha um placeholder com o ícone
 * da categoria e as iniciais do personagem.
 */
export function GameCard({
  card,
  size = 'md',
  imageUrl,
  className,
}: {
  card: CardDefinition
  size?: CardSize
  imageUrl?: string
  className?: string
}) {
  const Icon = CATEGORY_ICON[card.category]
  const color = `var(--cat-${card.category})`
  const showText = size !== 'sm'

  return (
    <article
      className={cn(
        'relative flex aspect-card shrink-0 flex-col overflow-hidden border-2 bg-card text-card-foreground shadow-md select-none',
        SIZE[size],
        className,
      )}
      style={{ borderColor: color }}
      aria-label={`${card.name}, ${CATEGORY_LABEL[card.category]}`}
    >
      <header
        className="flex items-center gap-1 px-1.5 py-1 font-bold text-white"
        style={{ background: color }}
      >
        <Icon className="size-[1.2em] shrink-0" aria-hidden />
        <span className="truncate leading-tight">{card.name}</span>
      </header>

      <div
        className="relative flex flex-1 items-center justify-center overflow-hidden"
        style={{ background: `color-mix(in oklch, ${color} 18%, var(--card))` }}
      >
        {imageUrl ? (
          <img
            src={imageUrl}
            alt={card.characterName ?? card.name}
            className="size-full object-cover"
          />
        ) : (
          <span
            className="font-heading text-[2.6em] font-black opacity-40"
            style={{ color }}
            aria-hidden
          >
            {initials(card.characterName ?? card.name)}
          </span>
        )}
        {card.isReaction && (
          <span
            className="absolute top-1 right-1 flex items-center gap-0.5 rounded-full bg-black/60 px-1.5 py-0.5 font-semibold text-white"
            title="Reação: usada fora do seu turno"
          >
            <ZapIcon className="size-[1em]" aria-hidden />
            {showText && 'Reação'}
          </span>
        )}
      </div>

      {showText && <p className="min-h-[4.5em] px-2 py-1.5 leading-snug">{card.rulesText}</p>}

      <footer className="flex items-center justify-between gap-1 border-t px-1.5 py-0.5 text-muted-foreground">
        <span className="truncate">{card.characterName}</span>
        <span className="shrink-0 font-mono">{card.code}</span>
      </footer>
    </article>
  )
}

/** Verso das cartas (baralho principal ou do Além). */
export function CardBack({
  deckType,
  size = 'md',
  className,
}: {
  deckType: 'main' | 'ghost'
  size?: CardSize
  className?: string
}) {
  const ghost = deckType === 'ghost'
  return (
    <div
      className={cn(
        'flex aspect-card shrink-0 items-center justify-center border-2 border-white/20 shadow-md',
        SIZE[size],
        ghost ? 'bg-cat-ghost' : 'bg-resenha',
        className,
      )}
      aria-hidden
    >
      {ghost ? (
        <GhostIcon className="size-1/3 text-white/70" />
      ) : (
        <span className="-rotate-6 font-heading text-[3em] font-black text-white/80">R</span>
      )}
    </div>
  )
}
