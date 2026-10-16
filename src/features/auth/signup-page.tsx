import { useState } from 'react'
import { Link } from 'react-router'
import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { useMutation } from '@tanstack/react-query'
import { z } from 'zod'
import { CircleAlertIcon, EyeIcon, EyeOffIcon, Loader2Icon } from 'lucide-react'
import { BrandMark, BrandName } from '@/components/brand'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { toFriendlyMessage } from '@/lib/errors'
import { signUp } from './auth-service'
import { isValidUsername, normalizeUsername } from './username'

const signupSchema = z
  .object({
    username: z
      .string()
      .transform(normalizeUsername)
      .refine(isValidUsername, 'Use 3 a 20 letras, números ou _ (sem espaços nem acentos).'),
    displayName: z
      .string()
      .trim()
      .min(1, 'Como o grupo te chama?')
      .max(32, 'No máximo 32 caracteres.'),
    password: z.string().min(8, 'Use pelo menos 8 caracteres.'),
    confirm: z.string(),
  })
  .refine((values) => values.password === values.confirm, {
    path: ['confirm'],
    message: 'As senhas não batem.',
  })

type SignupInput = z.input<typeof signupSchema>
type SignupValues = z.output<typeof signupSchema>

export function SignupPage() {
  const [showPassword, setShowPassword] = useState(false)

  const form = useForm<SignupInput, unknown, SignupValues>({
    resolver: zodResolver(signupSchema),
    defaultValues: { username: '', displayName: '', password: '', confirm: '' },
  })

  // A conta já nasce logada: o guarda leva para o lobby quando a sessão muda.
  const signup = useMutation({
    mutationFn: ({ username, displayName, password }: SignupValues) =>
      signUp(username, displayName, password),
  })

  const { errors } = form.formState
  const isPending = signup.isPending
  const fieldError = (name: keyof SignupInput) =>
    errors[name] && (
      <p id={`${name}-error`} className="text-sm text-destructive">
        {errors[name]?.message}
      </p>
    )
  const describedBy = (name: keyof SignupInput) => (errors[name] ? `${name}-error` : undefined)

  return (
    <main className="flex min-h-svh items-center justify-center px-4 py-10 bg-resenha">
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center justify-center gap-3 text-white">
          <BrandMark />
          <BrandName className="text-2xl" />
        </div>

        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Criar conta</CardTitle>
            <CardDescription>
              Escolha um usuário e uma senha para entrar na resenha.
            </CardDescription>
          </CardHeader>

          <CardContent>
            <form
              noValidate
              className="flex flex-col gap-4"
              onSubmit={form.handleSubmit((values) => signup.mutate(values))}
            >
              {signup.isError && (
                <Alert variant="destructive">
                  <CircleAlertIcon />
                  <AlertDescription>{toFriendlyMessage(signup.error)}</AlertDescription>
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
                  placeholder="ex.: leo_basilato"
                  className="h-10"
                  aria-invalid={!!errors.username}
                  aria-describedby={describedBy('username') ?? 'username-hint'}
                  disabled={isPending}
                  {...form.register('username')}
                />
                {fieldError('username') ?? (
                  <p id="username-hint" className="text-xs text-muted-foreground">
                    É com ele que você entra. Não dá para trocar depois.
                  </p>
                )}
              </div>

              <div className="flex flex-col gap-2">
                <Label htmlFor="displayName">Nome na mesa</Label>
                <Input
                  id="displayName"
                  autoComplete="nickname"
                  placeholder="ex.: Léo"
                  className="h-10"
                  maxLength={32}
                  aria-invalid={!!errors.displayName}
                  aria-describedby={describedBy('displayName')}
                  disabled={isPending}
                  {...form.register('displayName')}
                />
                {fieldError('displayName')}
              </div>

              <div className="flex flex-col gap-2">
                <Label htmlFor="password">Senha</Label>
                <div className="relative">
                  <Input
                    id="password"
                    type={showPassword ? 'text' : 'password'}
                    autoComplete="new-password"
                    className="h-10 pr-10"
                    aria-invalid={!!errors.password}
                    aria-describedby={describedBy('password')}
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
                {fieldError('password')}
              </div>

              <div className="flex flex-col gap-2">
                <Label htmlFor="confirm">Repita a senha</Label>
                <Input
                  id="confirm"
                  type={showPassword ? 'text' : 'password'}
                  autoComplete="new-password"
                  className="h-10"
                  aria-invalid={!!errors.confirm}
                  aria-describedby={describedBy('confirm')}
                  disabled={isPending}
                  {...form.register('confirm')}
                />
                {fieldError('confirm')}
              </div>

              <Button type="submit" size="lg" className="h-10 w-full" disabled={isPending}>
                {isPending && <Loader2Icon className="animate-spin" />}
                {isPending ? 'Criando conta…' : 'Criar conta'}
              </Button>
            </form>
          </CardContent>
        </Card>

        <p className="mt-4 text-center text-sm text-white/70">
          Já tem conta?{' '}
          <Link to="/login" className="font-medium text-white underline underline-offset-4">
            Entrar
          </Link>
        </p>
      </div>
    </main>
  )
}
