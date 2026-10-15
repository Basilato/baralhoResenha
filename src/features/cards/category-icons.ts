import {
  BombIcon,
  GhostIcon,
  HeartPulseIcon,
  RefreshCcwIcon,
  ShieldIcon,
  SwordsIcon,
  TornadoIcon,
  type LucideIcon,
} from 'lucide-react'
import type { CardCategoryId } from '@/lib/constants'

export const CATEGORY_ICON: Record<CardCategoryId, LucideIcon> = {
  attack: SwordsIcon,
  defense: ShieldIcon,
  sabotage: BombIcon,
  chaos: TornadoIcon,
  recovery: HeartPulseIcon,
  reversal: RefreshCcwIcon,
  ghost: GhostIcon,
}
