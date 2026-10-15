# Baralho da Resenha

Jogo de cartas multiplayer online e privado, feito com os memes, fotos, apelidos e histórias de um grupo de amigos.

A ideia é ser fácil de pegar: **comprar cartas, usar até duas ações por turno, atacar e defender, sobreviver e vencer**. Quem é derrotado vira **fantasma**, continua atrapalhando a partida e pode ressuscitar uma única vez.

> **Status:** M0 (fundação) pronto, com login privado, navegação protegida e base do Supabase. Próximo passo: salas (Fase 3). A especificação completa está em [BARALHO_DA_RESENHA_PLANO_TECNICO.md](BARALHO_DA_RESENHA_PLANO_TECNICO.md).

## O que o MVP vai ter

- Login privado com **usuário e senha** (sem cadastro aberto)
- Lobby para criar uma sala ou entrar por código
- Salas de **3 a 8 jogadores** com a mesa sincronizada em tempo real
- Baralho principal com **160 cartas** (30 modelos) e Baralho do Além com **20 cartas** (5 modelos)
- Turnos, mãos privadas, dano, reações, cura, efeitos temporários, ressaca progressiva, fantasmas, ressurreição e vitória, tudo calculado automaticamente
- Visual personalizado por personagem, painel de regras, histórico de jogadas e revanche
- Interface web responsiva, que funciona no desktop e no celular

**Fora do MVP:** pagamentos, ranking global, chat elaborado, adversário controlado por IA, torneios, modo offline, app nativo e espectadores.

## Regras em resumo (Resenha Simples v7.1)

| Item                | Regra                                                   |
| ------------------- | ------------------------------------------------------- |
| Jogadores           | 3 a 8, em ordem fixa no sentido horário                 |
| Vida inicial/máxima | 3 jogadores: 16 · 4–5 jogadores: 18 · 6–8 jogadores: 16 |
| Mão inicial         | 5 cartas                                                |
| Início do turno     | compra 2 cartas                                         |
| Ações por turno     | até 2 (reações não gastam ação)                         |
| Limite de mão       | 7 cartas ao encerrar o próprio turno                    |
| Duração máxima      | 10 rodadas completas                                    |

As regras completas, com os casos limite e o catálogo de cartas, estão nas seções 5 e 6 do plano técnico.

## Stack

| Camada            | Tecnologia                                                                   |
| ----------------- | ---------------------------------------------------------------------------- |
| Frontend          | React, TypeScript e Vite                                                     |
| UI                | Tailwind CSS v4, shadcn/ui, Radix UI e lucide-react                          |
| Navegação e dados | React Router e TanStack Query                                                |
| Formulários       | React Hook Form e Zod                                                        |
| Backend           | Supabase: Auth, PostgreSQL com RPC em PL/pgSQL, Realtime Broadcast e Storage |
| Testes            | Vitest, Testing Library, pgTAP e Playwright                                  |
| Deploy            | Vercel ou Cloudflare Pages                                                   |

**Decisão de arquitetura:** o projeto **não tem backend Node, Nest ou Express separado**. Toda a lógica de jogo que precisa ser confiável roda no banco, em funções RPC transacionais. O navegador só envia comandos e mostra o estado que o servidor autorizou, então ninguém consegue espiar a mão dos outros nem alterar vida ou turno pelo DevTools.

## Como rodar localmente

Pré-requisitos: Node.js 22 ou mais novo, pnpm 9, Git e Docker Desktop aberto (o Supabase local roda em containers).

```bash
pnpm install
pnpm db:start                # sobe o Supabase local e aplica as migrações e o seed
cp .env.example .env.local   # cole a "Publishable key" impressa pelo db:start
pnpm dev                     # http://localhost:5173
```

O seed cria três contas de teste: **teste1**, **teste2** e **teste3**. A senha de todas é `resenha123`.

O painel do banco local fica em http://127.0.0.1:54323.

### Scripts

| Comando                               | O que faz                                                                            |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `pnpm dev`                            | Servidor de desenvolvimento                                                          |
| `pnpm build`                          | Typecheck e build de produção em `dist/`                                             |
| `pnpm check`                          | Typecheck, lint, formatação e testes unitários                                       |
| `pnpm test`                           | Testes unitários (Vitest)                                                            |
| `pnpm test:db`                        | Testes do banco: RLS e permissões (pgTAP)                                            |
| `pnpm test:e2e`                       | Testes ponta a ponta no desktop e no celular (Playwright, precisa do Supabase local) |
| `pnpm db:reset`                       | Recria o banco local do zero: migrações e seed                                       |
| `pnpm db:types`                       | Regenera `src/types/database.generated.ts` depois de mudar o schema                  |
| `pnpm user:create <usuario> "<Nome>"` | Cria uma conta de jogador (precisa do `.env.admin`)                                  |

### Contas e login

O Supabase Auth só aceita senha junto com e-mail ou telefone. Por isso, cada usuário (`leo`, por exemplo) corresponde a um e-mail técnico `leo@<VITE_AUTH_EMAIL_DOMAIN>`. O jogador nunca vê esse e-mail.

- Não existe cadastro público. Ele está bloqueado no Auth (`enable_signup = false`).
- Quem cria as contas é o administrador, com `pnpm user:create`. O script gera uma senha aleatória e o perfil é criado automaticamente a partir do `app_metadata.username`.
- O `.env.admin` guarda a secret key. Copie de `.env.admin.example` e nunca faça commit desse arquivo.

> Só `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` e `VITE_AUTH_EMAIL_DOMAIN` podem ficar em variáveis `VITE_*`. Elas vão para o navegador. A secret key / `service_role` nunca pode ir para lá.

### Estrutura

```text
src/
  app/          # App, rotas e providers
  components/   # layout e componentes compartilhados (ui/ = shadcn)
  features/     # auth, lobby, profile, rules... (uma pasta por área)
  lib/          # cliente Supabase, env, query client, erros, constantes
  types/        # tipos gerados do banco
supabase/
  migrations/   # schema versionado (fonte da verdade)
  seed.sql      # dados de desenvolvimento local
  tests/        # testes pgTAP
scripts/        # ferramentas do administrador
tests/e2e/      # Playwright
```

## Roadmap

| Entrega                     | Fases | O que dá para demonstrar                               |
| --------------------------- | ----- | ------------------------------------------------------ |
| **M0 — Fundação**           | 0–2   | Login e navegação protegida                            |
| **M1 — Multiplayer básico** | 3–5   | 3 contas na mesma sala, mãos privadas, compra e turnos |
| **M2 — Combate**            | 6     | Ataques e defesas com reações e histórico              |
| **M3 — Partida completa**   | 7–8   | Todas as cartas, fantasmas, ressaca e vencedor         |
| **M4 — Beta divertido**     | 9–10  | Artes reais e partidas estáveis com 3, 5 e 8 pessoas   |
| **M5 — Lançamento**         | 11    | URL online com as contas dos amigos                    |

## Documentação

- [Plano técnico completo](BARALHO_DA_RESENHA_PLANO_TECNICO.md): produto, regras, catálogo de cartas, arquitetura, banco de dados, segurança, fases e critérios de aceite
