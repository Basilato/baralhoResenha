import { Badge } from '@/components/ui/badge'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { CATEGORY_LABEL } from '@/lib/constants'
import type { CardDefinition } from './catalog'
import { GameCard } from './game-card'

/** Carta ampliada com o texto completo da regra. */
export function CardDetailsDialog({
  card,
  onOpenChange,
}: {
  card: CardDefinition | null
  onOpenChange: (open: boolean) => void
}) {
  return (
    <Dialog open={card !== null} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-sm">
        {card && (
          <>
            <DialogHeader>
              <DialogTitle>{card.name}</DialogTitle>
              <DialogDescription className="flex flex-wrap items-center gap-1.5">
                <Badge variant="secondary">{CATEGORY_LABEL[card.category]}</Badge>
                {card.isReaction && <Badge variant="outline">Reação</Badge>}
                {card.isProvisional && <Badge variant="outline">Regra em teste</Badge>}
              </DialogDescription>
            </DialogHeader>
            <div className="flex justify-center">
              <GameCard card={card} size="lg" />
            </div>
          </>
        )}
      </DialogContent>
    </Dialog>
  )
}
