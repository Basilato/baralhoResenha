import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/features/auth/auth-context'
import { isAppError } from '@/lib/errors'
import { supabase } from '@/lib/supabase'
import { getRoomView, roomKeys } from './rooms-service'

export type ChannelStatus = 'connecting' | 'connected' | 'offline'

/**
 * Assina o canal privado game:<id>. O banco avisa "mudou para a versão N" e o
 * cliente refaz get_room_view — o aviso nunca carrega o estado em si.
 * Presence só indica quem está com a tela aberta; não decide nada.
 */
export function useGameChannel(gameId: string | undefined) {
  const queryClient = useQueryClient()
  const { user } = useAuth()
  const userId = user?.id
  const [status, setStatus] = useState<ChannelStatus>('connecting')
  const [onlineUserIds, setOnlineUserIds] = useState<ReadonlySet<string>>(new Set())

  useEffect(() => {
    if (!gameId || !userId) return

    let disposed = false
    const refresh = () => queryClient.invalidateQueries({ queryKey: roomKeys.view(gameId) })

    const channel = supabase.channel(`game:${gameId}`, {
      config: { private: true, presence: { key: userId } },
    })

    channel
      .on('broadcast', { event: 'game_changed' }, refresh)
      .on('presence', { event: 'sync' }, () => {
        setOnlineUserIds(new Set(Object.keys(channel.presenceState())))
      })

    // Garante que o socket use o JWT atual antes de entrar no canal privado.
    void supabase.realtime.setAuth().then(() => {
      if (disposed) return
      channel.subscribe((state) => {
        if (disposed) return
        if (state === 'SUBSCRIBED') {
          setStatus('connected')
          void channel.track({ at: Date.now() })
          // Reconcilia o que possa ter mudado enquanto estava desconectado.
          void refresh()
        } else if (state === 'CHANNEL_ERROR' || state === 'TIMED_OUT' || state === 'CLOSED') {
          setStatus('offline')
        }
      })
    })

    return () => {
      disposed = true
      setStatus('connecting')
      setOnlineUserIds(new Set())
      void supabase.removeChannel(channel)
    }
  }, [gameId, userId, queryClient])

  return { status, onlineUserIds }
}

export function useRoomView(gameId: string | undefined, channelStatus: ChannelStatus) {
  return useQuery({
    queryKey: roomKeys.view(gameId ?? ''),
    queryFn: () => getRoomView(gameId!),
    enabled: !!gameId,
    // Sem tempo real, cai para consulta periódica até o canal voltar.
    refetchInterval: channelStatus === 'connected' ? false : 5_000,
    retry: (failureCount, error) => !isAppError(error, 'ROOM_NOT_FOUND') && failureCount < 2,
  })
}
