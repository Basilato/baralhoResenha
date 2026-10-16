import { useState } from 'react'
import { Link } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation } from '@tanstack/react-query'
import { z } from 'zod'
import { CircleAlertIcon, EyeIcon, EyeOffIcon, Loader2Icon } from 'lucide-react'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { toFriendlyMessage } from '@/lib/errors'
import { AuthShell } from './auth-shell'
import { signIn } from './auth-service'
import { isValidUsername, normalizeUsername } from './username'

const loginSchema = z.object({
  username: z
    .string()
    .transform(normalizeUsername)
    .refine(isValidUsername, 'Use 3 a 20 letras, números ou _.'),
  password: z.string().min(1, 'Digite sua senha.'),
})

type LoginInput = z.input<typeof loginSchema>
type LoginValues = z.output<typeof loginSchema>

const FOOTER = (
  <>
    Não tem conta?{' '}
    <Link to="/cadastro" className="font-medium text-white underline underline-offset-4">
      Criar conta
    </Link>
  </>
)

export function LoginPage() {
  const [showPassword, setShowPassword] = useState(false)

  const form = useForm<LoginInput, unknown, LoginValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: { username: '', password: '' },
  })

  // O redirecionamento acontece no guarda quando a sessão muda.
  const login = useMutation({
    mutationFn: ({ username, password }: LoginValues) => signIn(username, password),
  })

  const { errors } = form.formState
  const isPending = login.isPending

  return (
    <AuthShell footer={FOOTER}>
      <Card>
        <CardHeader>
          <CardTitle className="text-2xl">Entrar na resenha</CardTitle>
          <CardDescription>Use seu usuário e senha.</CardDescription>
        </CardHeader>

        <CardContent>
          <form
            noValidate
            className="flex flex-col gap-4"
            onSubmit={form.handleSubmit((values) => login.mutate(values))}
          >
            {login.isError && (
              <Alert variant="destructive">
                <CircleAlertIcon />
                <AlertDescription>{toFriendlyMessage(login.error)}</AlertDescription>
              </Alert>
            )}

            <div className="flex flex-col gap-2">
              <Label htmlFor="username">Usuário</Label>
              <Input
                id="username"
                autoComplete="username"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                className="h-10"
                aria-invalid={!!errors.username}
                aria-describedby={errors.username ? 'username-error' : undefined}
                disabled={isPending}
                {...form.register('username')}
              />
              {errors.username && (
                <p id="username-error" className="text-sm text-destructive">
                  {errors.username.message}
                </p>
              )}
            </div>

            <div className="flex flex-col gap-2">
              <Label htmlFor="password">Senha</Label>
              <div className="relative">
                <Input
                  id="password"
                  type={showPassword ? 'text' : 'password'}
                  autoComplete="current-password"
                  className="h-10 pr-10"
                  aria-invalid={!!errors.password}
                  aria-describedby={errors.password ? 'password-error' : undefined}
                  disabled={isPending}
                  {...form.register('password')}
                />
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-lg"
                  className="absolute top-0.5 right-0.5"
                  onClick={() => setShowPassword((value) => !value)}
                  aria-label={showPassword ? 'Esconder senha' : 'Mostrar senha'}
                  aria-pressed={showPassword}
                >
                  {showPassword ? <EyeOffIcon /> : <EyeIcon />}
                </Button>
              </div>
              {errors.password && (
                <p id="password-error" className="text-sm text-destructive">
                  {errors.password.message}
                </p>
              )}
            </div>

            <Button type="submit" size="lg" className="mt-1 w-full" disabled={isPending}>
              {isPending && <Loader2Icon className="animate-spin" />}
              {isPending ? 'Entrando…' : 'Entrar'}
            </Button>
          </form>
        </CardContent>
      </Card>
    </AuthShell>
  )
}
