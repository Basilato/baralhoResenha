import type { ReactNode } from 'react'
import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { CardArtContext } from './card-art-context'
import type { CardDefinition } from './catalog'
import { GameCard } from './game-card'

const card: CardDefinition = {
  code: 'DEF-01',
  name: "It's Not Amazing",
  characterName: 'Victor',
  category: 'defense',
  deckType: 'main',
  copies: 8,
  targetRule: 'attack_reaction',
  effectCode: 'block_attack',
  isReaction: true,
  discardCost: false,
  rulesText: 'Reação: anula o dano de 1 ataque contra você.',
  imagePath: null,
  isProvisional: false,
}

const withArt: CardDefinition = { ...card, imagePath: '7.1/DEF-01.webp' }
const FULL_URL = 'https://exemplo.test/7.1/DEF-01.webp?token=a'
const THUMB_URL = 'https://exemplo.test/7.1/DEF-01_thumb.webp?token=a'

function renderWithArt(ui: ReactNode) {
  const urls = new Map([
    ['7.1/DEF-01.webp', FULL_URL],
    ['7.1/DEF-01_thumb.webp', THUMB_URL],
  ])
  return render(<CardArtContext value={urls}>{ui}</CardArtContext>)
}

describe('GameCard', () => {
  it('mostra nome, regra, código e selo de reação', () => {
    render(<GameCard card={card} />)
    expect(screen.getByRole('article', { name: "It's Not Amazing, Defesa" })).toBeInTheDocument()
    expect(screen.getByText(card.rulesText)).toBeInTheDocument()
    expect(screen.getByText('DEF-01')).toBeInTheDocument()
    expect(screen.getByText('Reação')).toBeInTheDocument()
  })

  it('usa placeholder com as iniciais quando não há arte', () => {
    render(<GameCard card={card} />)
    expect(screen.getByText('V')).toBeInTheDocument()
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('mostra a arte quando existe', () => {
    renderWithArt(<GameCard card={withArt} />)
    expect(screen.getByRole('img', { name: 'Victor' })).toHaveAttribute('src', FULL_URL)
  })

  it('usa a miniatura na carta pequena', () => {
    renderWithArt(<GameCard card={withArt} size="sm" />)
    expect(screen.getByRole('img', { name: 'Victor' })).toHaveAttribute('src', THUMB_URL)
  })

  it('volta ao placeholder se a arte não carregar', () => {
    renderWithArt(<GameCard card={withArt} />)
    fireEvent.error(screen.getByRole('img', { name: 'Victor' }))
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
    expect(screen.getByText('V')).toBeInTheDocument()
  })

  it('sem URL assinada (arte ainda não enviada) mostra o placeholder', () => {
    render(<GameCard card={withArt} />)
    expect(screen.queryByRole('img')).not.toBeInTheDocument()
  })

  it('no tamanho pequeno esconde o texto da regra', () => {
    render(<GameCard card={card} size="sm" />)
    expect(screen.queryByText(card.rulesText)).not.toBeInTheDocument()
  })
})
