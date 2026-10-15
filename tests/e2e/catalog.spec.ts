import { expect, test } from '@playwright/test'
import { expectNoHorizontalOverflow, login } from './support.ts'

test('página de regras mostra as 35 cartas do catálogo', async ({ page }) => {
  await login(page, 'teste9')
  await page.goto('/regras')
  await expect(page.getByRole('button', { name: /^Ampliar / })).toHaveCount(35)
  await expectNoHorizontalOverflow(page)
  await expect(page.getByRole('heading', { name: /Ataque · 7 modelos, 50 cartas/ })).toBeVisible()
  await expect(page.getByRole('heading', { name: /Além · 5 modelos, 20 cartas/ })).toBeVisible()

  await page.getByRole('button', { name: 'Ampliar Eu Sei o Que Você Fez' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByText('Regra em teste')).toHaveCount(0)
  await expect(dialog.getByText(/só você vê/)).toBeVisible()
  await expect(dialog.getByRole('article')).toBeInViewport({ ratio: 1 })
})
