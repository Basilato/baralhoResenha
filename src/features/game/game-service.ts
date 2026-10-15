import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
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

export type GamePhase = 'turn_main' | 'turn_ghost' | 'awaiting_reactions'

export type ResponseRole = 'target' | 'counter' | 'self'

/** Jogada esperando respostas (pública: não diz o que cada um tem na mão). */
export type PendingAction = {
  id: string
  actorPlayerId: string
  cardCode: string
  stage: 'defense' | 'counter' | 'self_fatal'
  responses: {
    playerId: string
    role: ResponseRole
    baseDamage: number
    responded: boolean
    reactionCode: string | null
  }[]
}

/** Decisão esperando o próprio jogador (privada). */
export type MyDecision = {
  pendingActionId: string
  role: ResponseRole
  baseDamage: number
  actorPlayerId: string
  cardCode: string
  eligibleCardIds: string[]
}

export type GameResult = {
  reason: 'round_limit'
  criteria: 'hp' | 'knockouts' | 'shared'
  winnerPlayerIds: string[]
}

export type GameEvent = {
  seq: number
  kind: string
  actorPlayerId: string | null
  payload: Record<string, unknown>
  at: string
}

/** Espelha app_private.game_view: só a minha mão; dos outros, contagens. */
export type GameView = {
  gameId: string
  version: number
  status: RoomStatus
  phase: GamePhase | null
  round: number
  maxRounds: number
  cardSetVersion: string
  hostUserId: string
  activePlayerId: string | null
  actionsUsed: number
  maxActions: number
  handLimit: number
  ghostHandLimit: number
  leaderPlayerId: string | null
  result: GameResult | null
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
  events: GameEvent[]
  pendingAction: PendingAction | null
  myDecision: MyDecision | null
}

export type GameCommand =
  | { type: 'END_TURN'; discardCardIds?: string[] }
  | {
      type: 'PLAY_CARD'
      cardInstanceId: string
      targetPlayerIds: string[]
      discardCostCardId?: string | null
    }
  | {
      type: 'RESPOND'
      pendingActionId: string
      response: 'PASS' | 'REACT'
      cardInstanceId?: string
    }

export async function getGameView(gameId: string): Promise<GameView> {
  const { data, error } = await supabase.rpc('get_game_view', { p_game_id: gameId })
  if (error) throw fromRpcError(error)
  return data as unknown as GameView
}

export async function submitGameCommand(
  gameId: string,
  expectedVersion: number,
  requestId: string,
  command: GameCommand,
) {
  const { data, error } = await supabase.rpc('submit_game_command', {
    p_game_id: gameId,
    p_expected_version: expectedVersion,
    p_request_id: requestId,
    p_command: command,
  })
  if (error) throw fromRpcError(error)
  return data as { ok: boolean; version: number; replayed?: boolean }
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

/**
 * Envia uma jogada. Cada clique ganha um request_id próprio, reaproveitado nos
 * retries automáticos: o banco aplica a jogada uma vez só. Versão desatualizada
 * recarrega a mesa.
 */
export function useGameCommand(game: Pick<GameView, 'gameId' | 'version'>) {
  const queryClient = useQueryClient()
  const refresh = () => queryClient.invalidateQueries({ queryKey: roomKeys.game(game.gameId) })

  return useMutation({
    mutationFn: ({ command, requestId }: { command: GameCommand; requestId: string }) =>
      submitGameCommand(game.gameId, game.version, requestId, command),
    retry: (failureCount, error) => !isAppError(error) && failureCount < 2,
    onSettled: refresh,
  })
}

export function newRequestId() {
  return crypto.randomUUID()
}
