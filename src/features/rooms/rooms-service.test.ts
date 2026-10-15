import { describe, expect, it } from 'vitest'
import { extractRoomCode, formatRoomCode, roomPath } from './rooms-service'

describe('extractRoomCode', () => {
  it('normaliza o código digitado, com espaço ou hífen', () => {
    expect(extractRoomCode(' k7qx2 m9pla ')).toBe('K7QX2M9PLA')
    expect(extractRoomCode('K7QX2-M9PLA')).toBe('K7QX2M9PLA')
  })

  it('aceita o link de convite colado', () => {
    expect(extractRoomCode('https://resenha.app/entrar/k7qx2m9pla')).toBe('K7QX2M9PLA')
  })
})

describe('formatRoomCode', () => {
  it('separa o código de 10 caracteres em dois blocos', () => {
    expect(formatRoomCode('K7QX2M9PLA')).toBe('K7QX2 M9PLA')
  })
})

describe('roomPath', () => {
  it('manda para a mesa quando a partida está em andamento', () => {
    expect(roomPath('abc', 'playing')).toBe('/jogo/abc')
    expect(roomPath('abc', 'lobby')).toBe('/sala/abc')
  })
})
