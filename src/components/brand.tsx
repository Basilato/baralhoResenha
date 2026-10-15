import { cn } from '@/lib/utils'

export function BrandMark({ className }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        'inline-flex size-9 -rotate-6 items-center justify-center rounded-md bg-primary font-heading text-lg font-black text-primary-foreground shadow-md',
        className,
      )}
    >
      R
    </span>
  )
}

export function BrandName({ className }: { className?: string }) {
  return (
    <span className={cn('font-heading font-black tracking-tight', className)}>
      Baralho da Resenha
    </span>
  )
}
