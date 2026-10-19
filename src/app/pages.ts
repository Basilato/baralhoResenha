/**
 * Cada página vira um arquivo JS separado, baixado só quando a rota abre.
 * O navegador guarda o import(): chamar o mesmo carregador de novo não baixa
 * outra vez, então ele também serve para pré-carregar.
 */
export const pages = {
  login: () => import('@/features/auth/login-page'),
  signup: () => import('@/features/auth/signup-page'),
  lobby: () => import('@/features/lobby/lobby-page'),
  rules: () => import('@/features/rules/rules-page'),
  room: () => import('@/features/rooms/room-page'),
  game: () => import('@/features/game/game-page'),
  joinLink: () => import('@/features/rooms/join-link-page'),
}

type NetworkInformation = { saveData?: boolean }

/**
 * Com a sessão aberta, baixa em segundo plano as telas do caminho principal
 * (lobby → sala → mesa). Quando o host inicia, todos entram na mesa ao mesmo
 * tempo: sem isso, cada um esperaria o maior arquivo do app naquela hora.
 * Respeita o modo de economia de dados do aparelho.
 */
export function preloadPlayPages() {
  const connection = (navigator as Navigator & { connection?: NetworkInformation }).connection
  if (connection?.saveData) return

  const load = () => {
    void pages.lobby().catch(() => {})
    void pages.room().catch(() => {})
    void pages.game().catch(() => {})
  }
  // Safari não tem requestIdleCallback.
  if (typeof window.requestIdleCallback === 'function') {
    const id = window.requestIdleCallback(load, { timeout: 5_000 })
    return () => window.cancelIdleCallback(id)
  }
  const id = window.setTimeout(load, 2_000)
  return () => window.clearTimeout(id)
}
