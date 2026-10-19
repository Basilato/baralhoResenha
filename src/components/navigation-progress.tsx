import { useNavigation } from 'react-router'

/**
 * Barra fina no topo enquanto a próxima tela carrega. A tela atual fica
 * parada até o arquivo da rota chegar; sem isso, o clique pareceria ignorado.
 */
export function NavigationProgress() {
  const navigation = useNavigation()
  if (navigation.state === 'idle') return null

  return (
    <div
      role="progressbar"
      aria-label="Carregando a página"
      className="pointer-events-none fixed inset-x-0 top-0 z-50 h-0.5 origin-left animate-nav-progress bg-neon shadow-[0_0_8px_var(--neon)]"
    />
  )
}
