import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
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
  isReaction: true,
  discardCost: false,
  rulesText: 'Reação: anula o dano de 1 ataque contra você.',
  imagePath: null,
  isProvisional: false,
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
    render(<GameCard card={card} imageUrl="https://exemplo.test/victor.webp" />)
    expect(screen.getByRole('img', { name: 'Victor' })).toHaveAttribute(
      'src',
      'https://exemplo.test/victor.webp',
    )
  })

  it('no tamanho pequeno esconde o texto da regra', () => {
    render(<GameCard card={card} size="sm" />)
    expect(screen.queryByText(card.rulesText)).not.toBeInTheDocument()
  })
})
