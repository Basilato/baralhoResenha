import { useState } from 'react'
import { Skeleton } from '@/components/ui/skeleton'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { useCardCatalog, type CardDefinition } from '@/features/cards/catalog'
import { CardDetailsDialog } from '@/features/cards/card-details-dialog'
import { CATEGORY_ICON } from '@/features/cards/category-icons'
import { GameCard } from '@/features/cards/game-card'
import { CARD_CATEGORIES } from '@/lib/constants'
import { toFriendlyMessage } from '@/lib/errors'
import { QuickRulesList } from './quick-rules'

export function RulesPage() {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="font-heading text-2xl font-black tracking-tight">Regras rápidas</h1>
        <p className="text-muted-foreground">
          Compre, use até duas ações, ataque, defenda e sobreviva. Quem cai vira fantasma e pode
          voltar uma vez.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>O básico</CardTitle>
        </CardHeader>
        <CardContent>
          <QuickRulesList />
        </CardContent>
      </Card>

      <CardCatalogSection />
    </div>
  )
}

function CardCatalogSection() {
  const catalog = useCardCatalog()
  const [selected, setSelected] = useState<CardDefinition | null>(null)

  if (catalog.isPending) return <Skeleton className="h-64 w-full" />
  if (catalog.isError) {
    return <p className="text-sm text-destructive">{toFriendlyMessage(catalog.error)}</p>
  }

  return (
    <section className="flex flex-col gap-6" aria-labelledby="catalog-title">
      <div>
        <h2 id="catalog-title" className="font-heading text-xl font-black tracking-tight">
          Todas as cartas
        </h2>
        <p className="text-sm text-muted-foreground">
          Baralho principal com 180 cartas e Baralho do Além com 20. Toque numa carta para ampliar.
        </p>
      </div>

      {CARD_CATEGORIES.map((category) => {
        const cards = catalog.data.list.filter((card) => card.category === category.id)
        const Icon = CATEGORY_ICON[category.id]
        const copies = cards.reduce((sum, card) => sum + card.copies, 0)
        return (
          <div key={category.id} className="flex flex-col gap-3">
            <h3 className="flex items-center gap-2 font-heading font-bold">
              <Icon className="size-5" style={{ color: `var(--cat-${category.id})` }} aria-hidden />
              {category.label}
              <span className="text-sm font-normal text-muted-foreground">
                · {cards.length} {cards.length === 1 ? 'modelo' : 'modelos'}, {copies} cartas
              </span>
            </h3>
            <p className="-mt-2 text-sm text-muted-foreground">{category.description}</p>
            <ul className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
              {cards.map((card) => (
                <li key={card.code} className="flex flex-col items-center gap-1">
                  <button
                    type="button"
                    onClick={() => setSelected(card)}
                    className="rounded-xl transition-transform hover:-translate-y-1"
                    aria-label={`Ampliar ${card.name}`}
                  >
                    <GameCard card={card} size="md" />
                  </button>
                  <span className="text-xs text-muted-foreground">×{card.copies} no baralho</span>
                </li>
              ))}
            </ul>
          </div>
        )
      })}

      <CardDetailsDialog card={selected} onOpenChange={(open) => !open && setSelected(null)} />
    </section>
  )
}
