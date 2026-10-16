import { useState, type ReactNode } from 'react'
import { BookOpenIcon, FlameIcon, GhostIcon, HeartIcon, ShieldIcon, SwordsIcon } from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { setPreferences } from '@/lib/preferences'
import { cn } from '@/lib/utils'

type Step = { title: string; summary: string; icon: ReactNode; points: ReactNode[] }

const STEPS: Step[] = [
  {
    title: 'Sobreviva à resenha',
    summary: 'Derrube os outros e não caia.',
    icon: <HeartIcon className="size-8 text-cat-attack" />,
    points: [
      'Todo mundo começa com a mesma vida (16 ou 18 PV) e 5 cartas.',
      'Vence quem ficar de pé sozinho, ou quem tiver mais PV ao fim da rodada 10.',
      <>
        Quem tem mais PV no começo da rodada vira o <b>Mais Odiado</b>{' '}
        <FlameIcon className="inline size-4 text-cat-attack" aria-hidden />: os ataques nele causam
        +1.
      </>,
      'A partir da rodada 5 vem a Ressaca: todo fim de rodada, todos os vivos perdem vida.',
    ],
  },
  {
    title: 'Na sua vez',
    summary: 'Compre, jogue e passe a vez.',
    icon: <SwordsIcon className="size-8 text-primary" />,
    points: [
      'Você compra 2 cartas e pode jogar até 2. As que dá para jogar agora ficam em destaque.',
      'Toque numa carta para ler e jogar. Se ela pede um alvo, escolha quem.',
      'Ao encerrar o turno, fique com no máximo 7 cartas na mão.',
      <>
        Atacaram você? O jogo pergunta na hora: use uma defesa{' '}
        <ShieldIcon className="inline size-4 text-cat-defense" aria-hidden /> ou aceite o dano.
        Reações não gastam ação.
      </>,
    ],
  },
  {
    title: 'Caiu? Vira fantasma',
    summary: 'A resenha continua do Além.',
    icon: <GhostIcon className="size-8 text-cat-ghost" />,
    points: [
      'Quem chega a 0 PV vira fantasma e perde a mão, mas continua jogando.',
      'Na vez do fantasma: ganha 1 ficha de ressaca, compra do Baralho do Além e pode jogar 1 carta.',
      'Com 3 fichas, pode ressuscitar com 6 PV e 3 cartas. Só uma vez por partida.',
      <>
        Tudo fica no histórico, e as regras estão sempre à mão no botão{' '}
        <BookOpenIcon className="inline size-4" aria-hidden /> da mesa e no menu.
      </>,
    ],
  },
]

/** Tutorial de 3 passos. Fechar por qualquer caminho conta como visto. */
export function TutorialDialog({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const [index, setIndex] = useState(0)
  const step = STEPS[index]!
  const last = index === STEPS.length - 1

  const close = () => {
    setPreferences({ tutorialSeen: true })
    onOpenChange(false)
    setIndex(0)
  }

  return (
    <Dialog open={open} onOpenChange={(next) => (next ? onOpenChange(true) : close())}>
      <DialogContent className="sm:max-w-md" data-testid="tutorial">
        <DialogHeader className="items-center text-center sm:text-center">
          <span className="flex size-20 items-center justify-center rounded-full bg-radial from-white/15 to-white/[0.03] shadow-[0_0_40px_-8px_var(--primary)] ring-1 ring-white/15 [&_svg]:size-10 [&_svg]:drop-shadow-[0_0_10px_currentColor]">
            {step.icon}
          </span>
          <p className="font-heading text-xs tracking-[0.25em] text-muted-foreground uppercase">
            Passo {index + 1} de {STEPS.length}
          </p>
          <DialogTitle className="text-3xl">{step.title}</DialogTitle>
          <DialogDescription>{step.summary}</DialogDescription>
        </DialogHeader>

        <ul className="flex flex-col gap-2 text-sm">
          {step.points.map((point, i) => (
            <li key={i} className="flex gap-2">
              <span className="mt-1.5 size-1.5 shrink-0 rounded-full bg-primary" aria-hidden />
              <span>{point}</span>
            </li>
          ))}
        </ul>

        <div className="flex justify-center gap-1.5" aria-hidden>
          {STEPS.map((item, i) => (
            <span
              key={item.title}
              className={cn(
                'h-1.5 rounded-full transition-all',
                i === index ? 'w-6 bg-primary' : 'w-1.5 bg-muted-foreground/30',
              )}
            />
          ))}
        </div>

        <DialogFooter className="flex-row justify-between gap-2 sm:justify-between">
          {index === 0 ? (
            <Button variant="ghost" onClick={close}>
              Pular
            </Button>
          ) : (
            <Button variant="ghost" onClick={() => setIndex(index - 1)}>
              Voltar
            </Button>
          )}
          <Button onClick={last ? close : () => setIndex(index + 1)}>
            {last ? 'Bora jogar!' : 'Próximo'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
