import { useState } from 'react'
import { Link } from 'react-router'
import { BookOpenIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { CATEGORY_ICON } from '@/features/cards/category-icons'
import { CARD_CATEGORIES } from '@/lib/constants'
import { cn } from '@/lib/utils'

const BASICS = [
  ['Jogadores', '3 a 8, em ordem fixa no sentido horário'],
  ['Vida inicial', '16 com 3 jogadores · 18 com 4–5 · 16 com 6–8'],
  ['Mão inicial', '5 cartas'],
  ['Início do turno', 'compra 2 cartas'],
  ['Ações', 'até 2 por turno — reações não gastam ação; sem ações, a vez passa sozinha'],
  ['Limite de mão', '7 cartas ao encerrar o seu turno'],
  ['Tempo', '60 s por turno (renova após cada jogada) · 20 s para reagir · 30 s para escolher'],
  ['Fantasma', 'quem cai junta fichas de ressaca; com 3, pode voltar uma vez com 6 PV'],
  ['Duração', 'até 10 rodadas completas'],
] as const

/** O básico das regras, numa lista curta. */
export function QuickRulesList({ className }: { className?: string }) {
  return (
    <dl className={cn('grid gap-x-6 gap-y-3 sm:grid-cols-[auto_1fr]', className)}>
      {BASICS.map(([term, description]) => (
        <div key={term} className="contents">
          <dt className="font-medium">{term}</dt>
          <dd className="text-muted-foreground">{description}</dd>
        </div>
      ))}
    </dl>
  )
}

/** O que cada categoria faz, com o ícone e a cor das cartas. */
export function CategoryList() {
  return (
    <ul className="grid gap-2 sm:grid-cols-2">
      {CARD_CATEGORIES.map((category) => {
        const Icon = CATEGORY_ICON[category.id]
        return (
          <li key={category.id} className="flex items-start gap-2 text-sm">
            <Icon
              className="mt-0.5 size-4 shrink-0"
              style={{ color: `var(--cat-${category.id})` }}
              aria-hidden
            />
            <span>
              <span className="font-medium">{category.label}:</span>{' '}
              <span className="text-muted-foreground">{category.description}</span>
            </span>
          </li>
        )
      })}
    </ul>
  )
}

/** Regras rápidas sem sair da mesa. */
export function QuickRulesButton() {
  const [open, setOpen] = useState(false)
  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label="Regras rápidas">
        <BookOpenIcon />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[90svh] overflow-y-auto sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>Regras rápidas</DialogTitle>
            <DialogDescription>
              Compre, use até duas ações, ataque, defenda e sobreviva.
            </DialogDescription>
          </DialogHeader>
          <QuickRulesList className="text-sm" />
          <div className="flex flex-col gap-2">
            <h3 className="font-heading font-bold">Tipos de carta</h3>
            <CategoryList />
          </div>
          <Button asChild variant="outline" className="self-start">
            <Link to="/regras" target="_blank" rel="noopener">
              Ver todas as cartas
            </Link>
          </Button>
        </DialogContent>
      </Dialog>
    </>
  )
}
