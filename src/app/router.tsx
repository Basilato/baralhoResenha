import { createBrowserRouter, Navigate } from 'react-router-dom'
import { AppLayout } from '@/components/app-layout'
import { RouteError } from '@/components/route-error'
import { RedirectIfAuthenticated, RequireAuth } from '@/features/auth/guards'
import { LoginPage } from '@/features/auth/login-page'
import { LobbyPage } from '@/features/lobby/lobby-page'
import { RulesPage } from '@/features/rules/rules-page'

export const router = createBrowserRouter([
  {
    errorElement: <RouteError />,
    children: [
      { index: true, element: <Navigate to="/lobby" replace /> },
      {
        element: <RedirectIfAuthenticated />,
        children: [{ path: 'login', element: <LoginPage /> }],
      },
      {
        element: <RequireAuth />,
        children: [
          {
            element: <AppLayout />,
            children: [
              { path: 'lobby', element: <LobbyPage /> },
              { path: 'regras', element: <RulesPage /> },
            ],
          },
        ],
      },
      { path: '*', element: <RouteError /> },
    ],
  },
])
