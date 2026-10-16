import { useEffect, useRef } from 'react'
import { playSound, type SoundName } from '@/lib/sounds'
import type { PlayerEffect, TableEffects } from './use-table-effects'

// Um som por leva de efeitos: o mais importante ganha.
const PRIORITY: readonly [PlayerEffect['kind'], SoundName][] = [
  ['death', 'death'],
  ['revive', 'revive'],
  ['damage', 'damage'],
  ['heal', 'heal'],
]

/**
 * Toca os sons da mesa a partir dos mesmos efeitos das animações. Só soa o
 * que acabou de acontecer: abrir ou recarregar a tela fica em silêncio.
 */
export function useTableSounds(fx: TableEffects, isMyTurn: boolean, finished: boolean) {
  const heard = useRef(new Set<number>())
  const wasMyTurn = useRef(isMyTurn)
  const wasFinished = useRef(finished)

  useEffect(() => {
    if (fx.spotlight && !heard.current.has(fx.spotlight.id)) {
      heard.current.add(fx.spotlight.id)
      playSound('card')
    }
  }, [fx.spotlight])

  useEffect(() => {
    const fresh = [...fx.byPlayer.values()].flat().filter((effect) => !heard.current.has(effect.id))
    if (fresh.length === 0) return
    for (const effect of fresh) heard.current.add(effect.id)
    const kinds = new Set(fresh.map((effect) => effect.kind))
    const sound = PRIORITY.find(([kind]) => kinds.has(kind))?.[1]
    // Pequeno atraso: o som do golpe vem depois do som da carta.
    if (sound) window.setTimeout(() => playSound(sound), 150)
  }, [fx.byPlayer])

  useEffect(() => {
    if (fx.drawnIds.size > 0) playSound('draw')
  }, [fx.drawnIds])

  useEffect(() => {
    if (isMyTurn && !wasMyTurn.current) playSound('turn')
    wasMyTurn.current = isMyTurn
  }, [isMyTurn])

  useEffect(() => {
    if (finished && !wasFinished.current) playSound('win')
    wasFinished.current = finished
  }, [finished])
}
