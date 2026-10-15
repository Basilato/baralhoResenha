import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/features/auth/auth-context'
import { isAppError } from '@/lib/errors'
import { supabase } from '@/lib/supabase'
import { getRoomView, roomKeys, sendHeartbeat } from './rooms-service'

export type ChannelStatus = 'connecting' | 'connected' | 'offline'

/**
 * Assina o canal privado game:<id>. O banco avisa "mudou para a versão N" e o
 * cliente refaz get_room_view — o aviso nunca carrega o estado em si.
 * Presence só indica quem está com a tela aberta; não decide nada.
 */
export function useGameChannel(gameId: string | undefined) {
  useHeartbeat(gameId)

  const queryClient = useQueryClient()
  const { user } = useAuth()
  const userId = user?.id
  const [status, setStatus] = useState<ChannelStatus>('connecting')
  const [onlineUserIds, setOnlineUserIds] = useState<ReadonlySet<string>>(new Set())

  useEffect(() => {
    if (!gameId || !userId) return

    let disposed = false
    // Sala de espera e mesa leem visões diferentes da mesma partida.
    const refresh = () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: roomKeys.view(gameId) }),
        queryClient.invalidateQueries({ queryKey: roomKeys.game(gameId) }),
      ])

    // O banco publica no tópico com o UUID em minúsculas.
    const channel = supabase.channel(`game:${gameId.toLowerCase()}`, {
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

const HEARTBEAT_MS = 20_000

/**
 * Sinal de presença gravado pelo servidor (horário do banco). É ele que decide
 * quem conta como conectado para passar o posto de host e, nas próximas fases,
 * para a remoção por ausência. Falhas são ignoradas: o próximo sinal tenta de novo.
 */
function useHeartbeat(gameId: string | undefined) {
  useEffect(() => {
    if (!gameId) return

    // Também em segundo plano: trocar de app não é desconectar. Se o sistema
    // suspender a página, o sinal para sozinho — aí sim é ausência.
    const beat = () => void sendHeartbeat(gameId).catch(() => {})
    const onVisible = () => {
      if (document.visibilityState === 'visible') beat()
    }

    beat()
    const timer = window.setInterval(beat, HEARTBEAT_MS)
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [gameId])
}
