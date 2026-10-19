/**
 * O arquivo de uma tela não chegou. O motivo mais comum é um deploy novo: os
 * arquivos da versão aberta no navegador deixaram de existir.
 */
export class PageLoadError extends Error {
  constructor(cause: unknown) {
    super('Não foi possível carregar a página.', { cause })
    this.name = 'PageLoadError'
  }
}

/** Abre a página de uma rota; a falha vira PageLoadError (a tela de erro trata). */
export async function loadPage<M>(load: () => Promise<M>): Promise<M> {
  try {
    return await load()
  } catch (error) {
    throw new PageLoadError(error)
  }
}

const RELOADED_AT_KEY = 'page-load:reloaded-at'
const RELOAD_WINDOW_MS = 10_000

/**
 * Recarregar busca a versão nova. Só vale com internet e uma vez a cada 10 s:
 * se a página continuar faltando, a tela de erro aparece em vez de um ciclo.
 */
export function canReloadForNewVersion(error: unknown) {
  if (!(error instanceof PageLoadError) || !navigator.onLine) return false
  try {
    const at = Number(sessionStorage.getItem(RELOADED_AT_KEY))
    return Date.now() - at >= RELOAD_WINDOW_MS
  } catch {
    // Sem sessionStorage não há como evitar o ciclo.
    return false
  }
}

export function reloadForNewVersion() {
  try {
    sessionStorage.setItem(RELOADED_AT_KEY, String(Date.now()))
  } catch {
    return
  }
  window.location.reload()
}
