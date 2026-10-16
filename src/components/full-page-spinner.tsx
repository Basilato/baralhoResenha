import { BrandMark } from '@/components/brand'

/** Carregando: a carta da marca girando devagar. */
export function FullPageSpinner({ label = 'Carregando…' }: { label?: string }) {
  return (
    <div
      className="flex min-h-svh flex-col items-center justify-center gap-4"
      role="status"
      aria-live="polite"
    >
      <BrandMark className="h-14 animate-pulse text-3xl" />
      <span className="font-heading text-sm tracking-widest text-muted-foreground uppercase">
        {label}
      </span>
    </div>
  )
}
