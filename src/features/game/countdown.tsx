import { HourglassIcon } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useSecondsLeft } from './use-deadline'

/** Segundos até o prazo; nos últimos 10, fica vermelho e pulsa. */
export function Countdown({ deadline, skewMs }: { deadline: string | null; skewMs: number }) {
  const seconds = useSecondsLeft(deadline, skewMs)
  if (seconds === null) return null
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 text-sm tabular-nums opacity-80',
        seconds <= 10 && 'animate-pulse font-bold text-cat-attack opacity-100',
      )}
      title="Tempo restante"
      data-testid="countdown"
    >
      <HourglassIcon className="size-3.5" aria-hidden />
      {seconds}s
    </span>
  )
}
