import { act, renderHook } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { getPreferences, setPreferences, usePreferences } from './preferences'

describe('preferências do aparelho', () => {
  afterEach(() => setPreferences({ sound: true, reduceMotion: false }))

  it('começa com som ligado e animações normais', () => {
    expect(getPreferences()).toEqual({ sound: true, reduceMotion: false, tutorialSeen: false })
  })

  it('salva no navegador e avisa quem está usando', () => {
    const { result } = renderHook(() => usePreferences())
    act(() => setPreferences({ sound: false }))
    expect(result.current.sound).toBe(false)
    expect(JSON.parse(localStorage.getItem('resenha:preferences')!)).toMatchObject({ sound: false })
  })

  it('reduzir animações liga o atributo usado pelo CSS', () => {
    setPreferences({ reduceMotion: true })
    expect(document.documentElement.dataset.motion).toBe('reduced')
    setPreferences({ reduceMotion: false })
    expect(document.documentElement.dataset.motion).toBeUndefined()
  })
})
