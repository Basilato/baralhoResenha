import { describe, expect, it } from 'vitest'
import { extractRoomCode, roomPath } from './rooms-service'

describe('extractRoomCode', () => {
  it('normaliza o código digitado', () => {
    expect(extractRoomCode(' k7qx-2m ')).toBe('K7QX2M')
  })

  it('aceita o link de convite colado', () => {
    expect(extractRoomCode('https://resenha.app/entrar/k7qx2m')).toBe('K7QX2M')
  })
})

describe('roomPath', () => {
  it('manda para a mesa quando a partida está em andamento', () => {
    expect(roomPath('abc', 'playing')).toBe('/jogo/abc')
    expect(roomPath('abc', 'lobby')).toBe('/sala/abc')
  })
})
