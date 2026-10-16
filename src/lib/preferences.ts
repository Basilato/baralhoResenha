import { useSyncExternalStore } from 'react'

/**
 * Preferências deste aparelho (som e animações). Ficam no navegador, não no
 * perfil: dá para ter som na TV da sala e silêncio no celular.
 */
export type Preferences = {
  /** Sons da mesa. Desligado = modo silencioso. */
  sound: boolean
  /** Reduz animações mesmo que o sistema não peça (o pedido do sistema sempre vale). */
  reduceMotion: boolean
}

const KEY = 'resenha:preferences'
const DEFAULTS: Preferences = { sound: true, reduceMotion: false }

let current: Preferences = load()
const listeners = new Set<() => void>()

function load(): Preferences {
  try {
    const raw = window.localStorage.getItem(KEY)
    if (raw) return { ...DEFAULTS, ...(JSON.parse(raw) as Partial<Preferences>) }
  } catch {
    // Navegação privada ou armazenamento bloqueado: segue com o padrão.
  }
  return DEFAULTS
}

export function getPreferences(): Preferences {
  return current
}

export function setPreferences(patch: Partial<Preferences>) {
  current = { ...current, ...patch }
  try {
    window.localStorage.setItem(KEY, JSON.stringify(current))
  } catch {
    // Sem armazenamento: vale só até recarregar a página.
  }
  applyMotion()
  for (const listener of listeners) listener()
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function usePreferences(): Preferences {
  return useSyncExternalStore(subscribe, getPreferences, getPreferences)
}

/** Liga o atributo que o CSS usa para reduzir animações (index.css). */
export function applyMotion() {
  if (current.reduceMotion) document.documentElement.dataset.motion = 'reduced'
  else delete document.documentElement.dataset.motion
}
