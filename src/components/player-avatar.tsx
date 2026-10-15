import { Avatar, AvatarFallback } from '@/components/ui/avatar'
import { initials } from '@/lib/format'
import { cn } from '@/lib/utils'

export function PlayerAvatar({
  name,
  online,
  className,
}: {
  name: string
  /** undefined = não mostra indicador. */
  online?: boolean
  className?: string
}) {
  return (
    <span className="relative inline-flex">
      <Avatar className={cn('size-9', className)}>
        <AvatarFallback>{initials(name)}</AvatarFallback>
      </Avatar>
      {online !== undefined && (
        <span
          className={cn(
            'absolute -right-0.5 -bottom-0.5 size-3 rounded-full ring-2 ring-card',
            online ? 'bg-emerald-500' : 'bg-muted-foreground/40',
          )}
          aria-hidden
        />
      )}
    </span>
  )
}
