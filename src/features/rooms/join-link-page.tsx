import { useEffect, useRef } from 'react'
import { Navigate, useParams } from 'react-router'
import { useMutation } from '@tanstack/react-query'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { joinRoom, roomPath } from './rooms-service'
import { RoomUnavailable } from './room-unavailable'

/** /entrar/:code — link de convite. Entra na sala e redireciona. */
export function JoinLinkPage() {
  const { code = '' } = useParams<{ code: string }>()
  const join = useMutation({ mutationFn: joinRoom })
  const requested = useRef(false)

  useEffect(() => {
    // Uma tentativa só (StrictMode monta duas vezes; código errado conta tentativa).
    if (requested.current) return
    requested.current = true
    join.mutate(code)
  }, [code, join])

  if (join.isSuccess) return <Navigate to={roomPath(join.data.gameId, join.data.status)} replace />
  if (join.isError) return <RoomUnavailable error={join.error} />
  return <FullPageSpinner label="Entrando na sala…" />
}
