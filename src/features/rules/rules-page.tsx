import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { CARD_CATEGORIES } from '@/lib/constants'

const BASICS = [
  ['Jogadores', '3 a 8, em ordem fixa no sentido horário'],
  ['Vida inicial', '16 com 3 jogadores · 18 com 4–5 · 16 com 6–8'],
  ['Mão inicial', '5 cartas'],
  ['Início do turno', 'compra 2 cartas'],
  ['Ações', 'até 2 por turno — reações não gastam ação'],
  ['Limite de mão', '7 cartas ao encerrar o seu turno'],
  ['Duração', 'até 10 rodadas completas'],
] as const

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
          <dl className="grid gap-x-6 gap-y-3 sm:grid-cols-[auto_1fr]">
            {BASICS.map(([term, description]) => (
              <div key={term} className="contents">
                <dt className="font-medium">{term}</dt>
                <dd className="text-muted-foreground">{description}</dd>
              </div>
            ))}
          </dl>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Categorias de cartas</CardTitle>
        </CardHeader>
        <CardContent>
          <ul className="grid gap-3 sm:grid-cols-2">
            {CARD_CATEGORIES.map((category) => (
              <li key={category.id} className="flex gap-3">
                <span
                  aria-hidden
                  className="mt-1 h-4 w-3 shrink-0 rounded-sm"
                  style={{ background: `var(--cat-${category.id})` }}
                />
                <div>
                  <p className="font-medium">{category.label}</p>
                  <p className="text-sm text-muted-foreground">{category.description}</p>
                </div>
              </li>
            ))}
          </ul>
        </CardContent>
      </Card>
    </div>
  )
}
