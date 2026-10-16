import type { CSSProperties, ReactNode } from 'react'
import { BrandMark, BrandName } from '@/components/brand'
import { CardBack } from '@/features/cards/game-card'

// Cartas viradas flutuando ao fundo (só enfeite; somem do leitor de tela).
const FLOATING = [
  { className: 'top-[8%] left-[6%] w-28 sm:w-36', tilt: '-18deg', delay: '0s', deck: 'main' },
  { className: 'top-[58%] left-[2%] w-24 sm:w-32', tilt: '12deg', delay: '-2s', deck: 'ghost' },
  { className: 'top-[12%] right-[5%] w-24 sm:w-32', tilt: '16deg', delay: '-4s', deck: 'ghost' },
  { className: 'bottom-[6%] right-[8%] w-28 sm:w-36', tilt: '-10deg', delay: '-1s', deck: 'main' },
] as const

/** Moldura das telas de entrada (login e cadastro). */
export function AuthShell({ children, footer }: { children: ReactNode; footer: ReactNode }) {
  return (
    <main className="relative flex min-h-svh items-center justify-center overflow-hidden px-4 py-10">
      <div className="pointer-events-none absolute inset-0 max-sm:opacity-40" aria-hidden>
        {FLOATING.map((card, index) => (
          <div
            key={index}
            className={`absolute animate-float-slow opacity-60 ${card.className}`}
            style={{ '--tilt': card.tilt, animationDelay: card.delay } as CSSProperties}
          >
            <CardBack deckType={card.deck} size="lg" className="w-full shadow-2xl" />
          </div>
        ))}
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_center,transparent_30%,oklch(0.12_0.03_285/0.85)_75%)]" />
      </div>

      <div className="relative w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-3 text-center">
          <BrandMark className="h-20 text-4xl" />
          <BrandName className="text-4xl text-white drop-shadow-[0_4px_12px_oklch(0_0_0/0.6)]" />
          <p className="font-heading text-sm tracking-[0.25em] text-white/60 uppercase">
            O jogo de cartas da resenha
          </p>
        </div>
        {children}
        <div className="mt-5 text-center text-sm text-white/70">{footer}</div>
      </div>
    </main>
  )
}
