import { supabase } from '@/lib/supabase'
import { AppError, fromRpcError } from '@/lib/errors'

export type RoomStatus = 'lobby' | 'playing' | 'finished' | 'cancelled'

export type RoomPlayer = {
  id: string
  userId: string
  seat: number
  isReady: boolean
  isHost: boolean
  displayName: string
  username: string
  avatarPath: string | null
}

export type RoomView = {
  id: string
  status: RoomStatus
  version: number
  hostUserId: string
  createdAt: string
  startedAt: string | null
  /** Só existe enquanto a sala está em lobby. */
  code: string | null
  myPlayerId: string | null
  players: RoomPlayer[]
}

export type RoomSummary = {
  id: string
  status: RoomStatus
  createdAt: string
  isHost: boolean
  hostName: string
  playerCount: number
}

export const roomKeys = {
  all: ['rooms'] as const,
  mine: () => [...roomKeys.all, 'mine'] as const,
  view: (gameId: string) => [...roomKeys.all, 'view', gameId] as const,
}

/** Caminho certo para uma sala de acordo com o status. */
export function roomPath(gameId: string, status: RoomStatus) {
  return status === 'playing' ? `/jogo/${gameId}` : `/sala/${gameId}`
}

// As RPCs devolvem jsonb montado no banco; os tipos acima espelham esse formato.

export async function createRoom(): Promise<RoomView> {
  const { data, error } = await supabase.rpc('create_room')
  if (error) throw fromRpcError(error)
  return data as unknown as RoomView
}

export async function joinRoom(code: string): Promise<{ gameId: string; status: RoomStatus }> {
  const { data, error } = await supabase.rpc('join_room', { p_code: code })
  if (error) throw fromRpcError(error)
  const result = data as { gameId?: string; status?: RoomStatus; error?: string }
  if (result.error || !result.gameId || !result.status) {
    throw new AppError(
      result.error ?? 'INVALID_CODE',
      'Código não encontrado. Confira com quem criou a sala.',
    )
  }
  return { gameId: result.gameId, status: result.status }
}

export async function getRoomView(gameId: string): Promise<RoomView> {
  const { data, error } = await supabase.rpc('get_room_view', { p_game_id: gameId })
  if (error) throw fromRpcError(error)
  return data as unknown as RoomView
}

export async function listMyRooms(): Promise<RoomSummary[]> {
  const { data, error } = await supabase.rpc('list_my_rooms')
  if (error) throw fromRpcError(error)
  return data as unknown as RoomSummary[]
}

export async function setReady(gameId: string, ready: boolean) {
  const { error } = await supabase.rpc('set_ready', { p_game_id: gameId, p_ready: ready })
  if (error) throw fromRpcError(error)
}

export async function leaveRoom(gameId: string) {
  const { error } = await supabase.rpc('leave_room', { p_game_id: gameId })
  if (error) throw fromRpcError(error)
}

export async function kickPlayer(gameId: string, playerId: string) {
  const { error } = await supabase.rpc('kick_player', { p_game_id: gameId, p_player_id: playerId })
  if (error) throw fromRpcError(error)
}

export async function startGame(gameId: string, expectedVersion: number) {
  const { error } = await supabase.rpc('start_game', {
    p_game_id: gameId,
    p_expected_version: expectedVersion,
  })
  if (error) throw fromRpcError(error)
}

export async function closeRoom(gameId: string) {
  const { error } = await supabase.rpc('close_room', { p_game_id: gameId })
  if (error) throw fromRpcError(error)
}

/** Aceita o código puro ou um link /entrar/CODIGO colado. */
export function extractRoomCode(input: string): string {
  const fromLink = input.match(/\/entrar\/([A-Za-z0-9]+)/)?.[1]
  return (fromLink ?? input).replace(/[^A-Za-z0-9]/g, '').toUpperCase()
}

export function inviteLink(code: string): string {
  return `${window.location.origin}/entrar/${code}`
}
