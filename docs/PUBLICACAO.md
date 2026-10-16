# Publicação (Fase 11)

Roteiro para colocar o Baralho da Resenha no ar: Supabase Free e Vercel com subdomínio `.vercel.app`. Cada passo diz quem faz: **você** (precisa da sua conta ou do painel) ou o **Claude** (pelas CLIs, depois dos logins).

## 0. Logins (você)

No prompt do Claude Code:

```text
! supabase login
! vercel login
```

## 1. Projeto do Supabase (Claude, com sua confirmação)

1. `supabase orgs list` para escolher a organização.
2. `supabase projects create baralho-resenha --org-id <org> --region sa-east-1 --db-password <senha gerada>`. A região é São Paulo e o plano é o Free.
3. A senha do banco e as chaves (`supabase projects api-keys`) vão para `.env.production.admin`, que fica fora do git.
4. `supabase link --project-ref <ref>` seguido de `supabase db push --dry-run`. Depois de você conferir a lista, `supabase db push`. Isso aplica **só as migrações**: o `seed.sql`, com as contas de teste, não vai para a produção.

## 2. Configurações do Supabase (você, no painel)

| Onde                                         | O que                                                                      |
| -------------------------------------------- | -------------------------------------------------------------------------- |
| Authentication → Sign In / Providers         | Deixar **ligado** "Allow new users to sign up" (autocadastro em /cadastro) |
| Authentication → Sign In / Providers → Email | Desligar **Confirm email** (o e-mail é técnico e nunca recebe mensagem)    |
| Authentication → URL Configuration           | **Site URL** = endereço da Vercel (passo 3)                                |
| Realtime → Settings                          | Desligar **Allow public access** (só canais privados)                      |

## 3. Vercel (Claude, com sua confirmação)

1. `vercel link` para criar o projeto `baralho-resenha`. O endereço fica algo como `https://baralho-resenha.vercel.app`.
2. Variáveis de produção (`vercel env add … production`):
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
   - `VITE_AUTH_EMAIL_DOMAIN`, igual ao host do site (ex.: `baralho-resenha.vercel.app`). Ele só forma os e-mails técnicos de login e **não pode mudar depois** que as contas existirem.
3. `vercel git connect` para que cada push na `main` publique sozinho. Depois, `vercel --prod` para o primeiro deploy.

Só as chaves públicas vão para a Vercel. A secret key nunca sai do `.env.production.admin`.

## 4. Conteúdo (Claude)

- Artes: `pnpm art:upload:prod`.
- Contas: cada pessoa cria a própria em **https://baralho-resenha.vercel.app/cadastro**. Para criar uma conta manualmente, trocar uma senha esquecida ou desativar alguém: `pnpm users:prod create|reset-password|disable …`. Se alguém ficar com "Conta criada, mas ainda precisa ser ativada", o **Confirm email** foi religado no painel: desligue de novo e rode `pnpm users:prod confirm-pending` para ativar quem ficou preso.

## 5. Verificação (Claude)

`pnpm prod:check` confere, sem alterar nada:

- o site em HTTPS, as rotas e os cabeçalhos de segurança;
- se o site aponta para este Supabase e se a secret key ficou fora do bundle;
- o autocadastro aberto sem confirmação de e-mail, nada respondendo sem login, as tabelas internas e as artes fora do acesso público;
- se as migrações e as artes estão no lugar e se não sobrou nenhuma conta de teste.

## 6. Teste final (vocês)

Uma partida com pelo menos 3 contas reais, seguindo [BETA.md](BETA.md).

## Depois do ar

- **Pausa do plano Free:** sem uso por 7 dias, o Supabase pausa o projeto. Para voltar, use **Restore** no painel; leva alguns minutos e os dados continuam lá. Se incomodar, suba para o Pro.
- **Backup (o Free não tem):** de vez em quando, `supabase db dump --linked --data-only -f backups/AAAA-MM-DD.sql`. A pasta `backups/` fica fora do git.
- **Erros e uso:** Supabase → Logs (API, Auth, Realtime) e Reports; Vercel → Deployments e Logs.
- **Partida suspeita:** no SQL Editor do Supabase, `select public.admin_check_game_integrity('<id da partida>');`.
- **Nova migração:** `supabase db push` depois do merge na `main`.
