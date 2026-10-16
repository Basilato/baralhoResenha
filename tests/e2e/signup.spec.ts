import { expect, test } from '@playwright/test'
import { expectNoHorizontalOverflow } from './support.ts'

// Autocadastro aberto: qualquer pessoa cria a conta e já entra logada.
// Cada execução usa um usuário novo (o banco local acumula as contas).
const fresh = () => `novo_${Date.now().toString(36)}${Math.floor(Math.random() * 100)}`

test('criar conta pela tela, entrar no lobby e voltar a entrar depois', async ({ page }) => {
  const username = fresh()

  await page.goto('/login')
  await page.getByRole('link', { name: 'Criar conta' }).click()
  await expect(page).toHaveURL(/\/cadastro$/)
  await expectNoHorizontalOverflow(page)

  // Validação na própria tela, antes de ir ao servidor.
  await page.getByLabel('Usuário').fill('Ab')
  await page.getByLabel('Nome na mesa').fill('Novato')
  await page.getByLabel('Senha', { exact: true }).fill('curta')
  await page.getByLabel('Repita a senha').fill('outra')
  await page.getByRole('button', { name: 'Criar conta' }).click()
  await expect(page.getByText('Use 3 a 20 letras')).toBeVisible()
  await expect(page.getByText('Use pelo menos 8 caracteres.')).toBeVisible()
  await expect(page.getByText('As senhas não batem.')).toBeVisible()

  // Maiúsculas e acentos viram o usuário normalizado.
  await page.getByLabel('Usuário').fill(username.toUpperCase())
  await page.getByLabel('Senha', { exact: true }).fill('senha-boa-123')
  await page.getByLabel('Repita a senha').fill('senha-boa-123')
  await page.getByRole('button', { name: 'Criar conta' }).click()

  await expect(page).toHaveURL(/\/lobby$/)
  await expect(page.getByRole('heading', { name: 'E aí, Novato!' })).toBeVisible()

  // Sai e entra de novo com o usuário e a senha criados.
  await page.getByRole('button', { name: /Novato/ }).click()
  await page.getByRole('menuitem', { name: 'Sair' }).click()
  await expect(page).toHaveURL(/\/login/)
  await page.getByLabel('Usuário').fill(username)
  await page.getByLabel('Senha', { exact: true }).fill('senha-boa-123')
  await page.getByRole('button', { name: 'Entrar' }).click()
  await expect(page).toHaveURL(/\/lobby$/)
})

test('usuário já existente mostra erro amigável', async ({ page }) => {
  await page.goto('/cadastro')
  await page.getByLabel('Usuário').fill('teste1')
  await page.getByLabel('Nome na mesa').fill('Impostor')
  await page.getByLabel('Senha', { exact: true }).fill('qualquer-senha-1')
  await page.getByLabel('Repita a senha').fill('qualquer-senha-1')
  await page.getByRole('button', { name: 'Criar conta' }).click()
  await expect(page.getByText('Esse usuário já existe. Escolha outro.')).toBeVisible()
  await expect(page).toHaveURL(/\/cadastro$/)
})
