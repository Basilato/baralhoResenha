import { afterEach, describe, expect, it, vi } from 'vitest'
import { canReloadForNewVersion, loadPage, PageLoadError } from './page-load'

describe('carregamento das páginas', () => {
  afterEach(() => {
    sessionStorage.clear()
    vi.restoreAllMocks()
  })

  it('devolve o módulo quando o arquivo chega', async () => {
    await expect(loadPage(async () => ({ Page: 'ok' }))).resolves.toEqual({ Page: 'ok' })
  })

  it('falha no arquivo vira PageLoadError, guardando a causa', async () => {
    const cause = new TypeError('Failed to fetch dynamically imported module')
    const error = await loadPage(() => Promise.reject(cause)).catch((e: unknown) => e)
    expect(error).toBeInstanceOf(PageLoadError)
    expect((error as PageLoadError).cause).toBe(cause)
  })

  it('recarrega só por arquivo ausente, nunca por outro erro', () => {
    expect(canReloadForNewVersion(new PageLoadError(null))).toBe(true)
    expect(canReloadForNewVersion(new Error('outro'))).toBe(false)
    expect(canReloadForNewVersion(undefined)).toBe(false)
  })

  it('não recarrega de novo logo depois de uma recarga (evita ciclo)', () => {
    sessionStorage.setItem('page-load:reloaded-at', String(Date.now() - 2_000))
    expect(canReloadForNewVersion(new PageLoadError(null))).toBe(false)

    sessionStorage.setItem('page-load:reloaded-at', String(Date.now() - 11_000))
    expect(canReloadForNewVersion(new PageLoadError(null))).toBe(true)
  })

  it('sem internet, mostra o erro em vez de recarregar', () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    expect(canReloadForNewVersion(new PageLoadError(null))).toBe(false)
  })
})
