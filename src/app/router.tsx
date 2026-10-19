import { createBrowserRouter, Navigate } from 'react-router'
import { AppLayout } from '@/components/app-layout'
import { FullPageSpinner } from '@/components/full-page-spinner'
import { RootLayout } from '@/components/root-layout'
import { RouteError } from '@/components/route-error'
import { RedirectIfAuthenticated, RequireAuth } from '@/features/auth/guards'
import { loadPage } from '@/lib/page-load'
import { pages } from './pages'

// As páginas são carregadas sob demanda (pages.ts). Guardas e layout ficam no
// arquivo principal: rodam em toda tela.
//
// O lazy é sempre a forma de função: na forma de objeto ({ Component }), o
// React Router 8 ignora a falha de uma rota sem loader e mostra a tela vazia,
// em vez de levar o erro à RouteError.
export const router = createBrowserRouter([
  {
    Component: RootLayout,
    errorElement: <RouteError />,
    // Primeira abertura: enquanto o arquivo da rota chega.
    hydrateFallbackElement: <FullPageSpinner />,
    children: [
      { index: true, element: <Navigate to="/lobby" replace /> },
      {
        element: <RedirectIfAuthenticated />,
        children: [
          {
            path: 'login',
            lazy: async () => ({ Component: (await loadPage(pages.login)).LoginPage }),
          },
          {
            path: 'cadastro',
            lazy: async () => ({ Component: (await loadPage(pages.signup)).SignupPage }),
          },
        ],
      },
      {
        element: <RequireAuth />,
        children: [
          {
            element: <AppLayout />,
            children: [
              {
                path: 'lobby',
                lazy: async () => ({ Component: (await loadPage(pages.lobby)).LobbyPage }),
              },
              {
                path: 'regras',
                lazy: async () => ({ Component: (await loadPage(pages.rules)).RulesPage }),
              },
              {
                path: 'sala/:gameId',
                lazy: async () => ({ Component: (await loadPage(pages.room)).RoomPage }),
              },
              {
                path: 'jogo/:gameId',
                lazy: async () => ({ Component: (await loadPage(pages.game)).GamePage }),
              },
              {
                path: 'entrar/:code',
                lazy: async () => ({ Component: (await loadPage(pages.joinLink)).JoinLinkPage }),
              },
            ],
          },
        ],
      },
      { path: '*', element: <RouteError /> },
    ],
  },
])
