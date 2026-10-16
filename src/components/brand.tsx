import { cn } from '@/lib/utils'

/** Selo da marca: uma carta inclinada com o "R", em degradê e com brilho. */
export function BrandMark({ className }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        'relative inline-flex aspect-[63/88] h-10 -rotate-8 items-center justify-center rounded-md bg-linear-to-br from-[oklch(0.72_0.22_330)] via-[oklch(0.58_0.24_300)] to-[oklch(0.42_0.2_275)] font-heading text-xl text-white shadow-[0_0_0_1.5px_oklch(1_0_0/0.35),0_8px_20px_-6px_oklch(0.6_0.24_310/0.8)] [text-shadow:0_2px_0_oklch(0_0_0/0.3)]',
        className,
      )}
    >
      <span className="absolute inset-[3px] rounded-[4px] border border-white/30" />R
    </span>
  )
}

export function BrandName({ className }: { className?: string }) {
  return (
    <span className={cn('font-heading tracking-wide', className)}>
      Baralho da <span className="text-gradient-brand">Resenha</span>
    </span>
  )
}
