import { useState, type CSSProperties } from 'react'
import { GhostIcon, Trash2Icon, ZapIcon } from 'lucide-react'
import { CATEGORY_LABEL } from '@/lib/constants'
import { initials } from '@/lib/format'
import { cn } from '@/lib/utils'
import { CARD_BACK_PATH, useCardArtUrl } from './card-art-context'
import type { CardDefinition } from './catalog'
import { CATEGORY_ICON } from './category-icons'

type CardSize = 'sm' | 'md' | 'lg'

const SIZE: Record<CardSize, string> = {
  sm: 'w-24 rounded-lg text-[0.6rem]',
  md: 'w-36 rounded-xl text-xs',
  lg: 'w-64 rounded-2xl text-sm sm:w-72',
}

/**
 * Face de uma carta, com a moldura da categoria. Usa a arte do Storage (miniatura
 * na carta pequena); sem arte, ou se a imagem não carregar, desenha um placeholder
 * com o ícone da categoria e as iniciais do personagem.
 */
export function GameCard({
  card,
  size = 'md',
  className,
}: {
  card: CardDefinition
  size?: CardSize
  className?: string
}) {
  const artUrl = useCardArtUrl(card.imagePath, size === 'sm' ? 'thumb' : 'full')
  // Guarda a URL que falhou: uma URL nova (renovada) tenta de novo.
  const [failedUrl, setFailedUrl] = useState<string>()
  const imageUrl = artUrl !== failedUrl ? artUrl : undefined
  const Icon = CATEGORY_ICON[card.category]
  const ghost = card.deckType === 'ghost'
  const showText = size !== 'sm'

  return (
    <article
      className={cn(
        'relative flex aspect-card shrink-0 flex-col overflow-hidden border-2 border-(--cat) bg-card text-card-foreground select-none',
        ghost ? 'card-ghostly' : 'shadow-md',
        SIZE[size],
        className,
      )}
      style={{ '--cat': `var(--cat-${card.category})` } as CSSProperties}
      data-category={card.category}
      aria-label={`${card.name}, ${CATEGORY_LABEL[card.category]}`}
    >
      <header className="flex items-center gap-1 px-1 py-1 font-bold text-white card-header-fill">
        <span className="flex size-[1.55em] shrink-0 items-center justify-center rounded-full bg-white/20 ring-1 ring-white/40">
          <Icon className="size-[0.95em]" aria-hidden />
        </span>
        <span className="truncate leading-tight [text-shadow:0_1px_2px_rgb(0_0_0/0.4)]">
          {card.name}
        </span>
      </header>

      <div className="relative flex flex-1 items-center justify-center overflow-hidden card-art-fill">
        {imageUrl ? (
          <img
            src={imageUrl}
            alt={card.characterName ?? card.name}
            className="size-full object-cover"
            loading="lazy"
            decoding="async"
            draggable={false}
            onError={() => setFailedUrl(imageUrl)}
          />
        ) : (
          <>
            <Icon
              className="absolute size-3/4 text-(--cat) opacity-15"
              strokeWidth={1.25}
              aria-hidden
            />
            <span
              className="relative font-heading text-[2.6em] font-black text-(--cat) opacity-70"
              aria-hidden
            >
              {initials(card.characterName ?? card.name)}
            </span>
          </>
        )}
        {ghost && <div className="pointer-events-none absolute inset-0 card-mist" aria-hidden />}
        <div
          className="pointer-events-none absolute inset-0 shadow-[inset_0_0_0.7em_rgb(0_0_0/0.35)]"
          aria-hidden
        />
        <div className="absolute top-1 right-1 flex flex-col items-end gap-0.5">
          {card.isReaction && (
            <span
              className="flex items-center gap-0.5 rounded-full bg-black/65 px-1.5 py-0.5 font-semibold text-white"
              title="Reação: usada fora do seu turno"
            >
              <ZapIcon className="size-[1em] text-amber-300" aria-hidden />
              {showText && 'Reação'}
            </span>
          )}
          {card.discardCost && (
            <span
              className="flex items-center gap-0.5 rounded-full bg-black/65 px-1.5 py-0.5 font-semibold text-white"
              title="Custo: descarte outra carta da mão para jogar esta"
            >
              <Trash2Icon className="size-[1em] text-red-300" aria-hidden />
              {showText && 'Custo'}
            </span>
          )}
        </div>
      </div>

      {showText && (
        <p className="min-h-[4.5em] px-2 py-1.5 leading-snug card-rules-fill">{card.rulesText}</p>
      )}

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
  const artUrl = useCardArtUrl(CARD_BACK_PATH[deckType], size === 'sm' ? 'thumb' : 'full')
  const [failedUrl, setFailedUrl] = useState<string>()
  const imageUrl = artUrl !== failedUrl ? artUrl : undefined

  return (
    <div
      className={cn(
        'relative flex aspect-card shrink-0 items-center justify-center overflow-hidden border-2 border-white/20 shadow-md',
        SIZE[size],
        ghost
          ? 'bg-linear-to-br from-[oklch(0.42_0.1_285)] via-[oklch(0.28_0.08_285)] to-[oklch(0.18_0.05_285)] card-ghostly'
          : 'bg-resenha',
        className,
      )}
      style={ghost ? ({ '--cat': 'var(--cat-ghost)' } as CSSProperties) : undefined}
      aria-hidden
    >
      {imageUrl ? (
        <>
          <img
            src={imageUrl}
            alt=""
            className="absolute inset-0 size-full object-cover"
            loading="lazy"
            decoding="async"
            draggable={false}
            onError={() => setFailedUrl(imageUrl)}
          />
          {/* O verso principal tem um medalhão vazio no centro: o "R" da marca entra ali. */}
          {!ghost && (
            <span className="relative -rotate-6 font-heading text-[2.6em] text-white [text-shadow:0_2px_0_oklch(0_0_0/0.35),0_0_14px_oklch(0.75_0.2_320/0.9)]">
              R
            </span>
          )}
        </>
      ) : (
        <>
          <span className="absolute inset-[6%] rounded-[inherit] border border-white/25" />
          {ghost && <span className="absolute inset-0 card-mist" />}
          <span className="relative flex aspect-square w-1/2 items-center justify-center rounded-full bg-white/10 ring-1 ring-white/30">
            {ghost ? (
              <GhostIcon className="size-1/2 text-white/80" />
            ) : (
              <span className="-rotate-6 font-heading text-[2.4em] text-white/85">R</span>
            )}
          </span>
        </>
      )}
    </div>
  )
}
