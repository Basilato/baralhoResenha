import { useState } from 'react'
import { useMatch } from 'react-router'
import { getPreferences } from '@/lib/preferences'

/**
 * Abre o tutorial sozinho no primeiro acesso deste aparelho, menos no meio de
 * uma partida (aí a pessoa abre pelo menu quando quiser).
 */
export function useTutorial() {
  const inGame = useMatch('/jogo/:gameId') !== null
  const [open, setOpen] = useState(() => !getPreferences().tutorialSeen && !inGame)
  return { open, setOpen }
}
