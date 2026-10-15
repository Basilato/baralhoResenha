import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { fromRpcError, isAppError } from '@/lib/errors'
import { roomKeys, type RoomStatus } from '@/features/rooms/rooms-service'
import type { ChannelStatus } from '@/features/rooms/use-room'

export type Participant = {
  id: string
  userId: string
  displayName: string
  avatarPath: string | null
  seat: number
  isHost: boolean
  hp: number
  maxHp: number
  alive: boolean
  cardsInHand: number
  ghostCardsInHand: number
  ghostTokens: number
  revivalUsed: boolean
  knockouts: number
}

export type HandCard = { instanceId: string; code: string }

/** Espelha app_private.game_view: só a minha mão; dos outros, contagens. */
export type GameView = {
  gameId: string
  version: number
  status: RoomStatus
  phase: string | null
  round: number
  maxRounds: number
  cardSetVersion: string
  hostUserId: string
  activePlayerId: string | null
  leaderPlayerId: string | null
  myPlayerId: string | null
  participants: Participant[]
  myHand: HandCard[]
  myGhostHand: HandCard[]
  mainDeckCount: number
  ghostDeckCount: number
  mainDiscardCount: number
  ghostDiscardCount: number
  mainDiscardTop: string | null
  ghostDiscardTop: string | null
}

export async function getGameView(gameId: string): Promise<GameView> {
  const { data, error } = await supabase.rpc('get_game_view', { p_game_id: gameId })
  if (error) throw fromRpcError(error)
  return data as unknown as GameView
}

export function useGameView(gameId: string | undefined, channelStatus: ChannelStatus) {
  return useQuery({
    queryKey: roomKeys.game(gameId ?? ''),
    queryFn: () => getGameView(gameId!),
    enabled: !!gameId,
    refetchInterval: channelStatus === 'connected' ? false : 5_000,
    retry: (failureCount, error) => !isAppError(error, 'ROOM_NOT_FOUND') && failureCount < 2,
  })
}
