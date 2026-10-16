import { createBrowserRouter, Navigate } from 'react-router'
import { AppLayout } from '@/components/app-layout'
import { RouteError } from '@/components/route-error'
import { RedirectIfAuthenticated, RequireAuth } from '@/features/auth/guards'
import { LoginPage } from '@/features/auth/login-page'
import { SignupPage } from '@/features/auth/signup-page'
import { GamePage } from '@/features/game/game-page'
import { LobbyPage } from '@/features/lobby/lobby-page'
import { JoinLinkPage } from '@/features/rooms/join-link-page'
import { RoomPage } from '@/features/rooms/room-page'
import { RulesPage } from '@/features/rules/rules-page'

export const router = createBrowserRouter([
  {
    errorElement: <RouteError />,
    children: [
      { index: true, element: <Navigate to="/lobby" replace /> },
      {
        element: <RedirectIfAuthenticated />,
        children: [
          { path: 'login', element: <LoginPage /> },
          { path: 'cadastro', element: <SignupPage /> },
        ],
      },
      {
        element: <RequireAuth />,
        children: [
          {
            element: <AppLayout />,
            children: [
              { path: 'lobby', element: <LobbyPage /> },
              { path: 'regras', element: <RulesPage /> },
              { path: 'sala/:gameId', element: <RoomPage /> },
              { path: 'jogo/:gameId', element: <GamePage /> },
              { path: 'entrar/:code', element: <JoinLinkPage /> },
            ],
          },
        ],
      },
      { path: '*', element: <RouteError /> },
    ],
  },
])
