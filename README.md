# Baralho da Resenha

Jogo de cartas multiplayer online e privado, feito com os memes, fotos, apelidos e histórias de um grupo de amigos.

A ideia é ser fácil de pegar: **comprar cartas, usar até duas ações por turno, atacar e defender, sobreviver e vencer**. Quem é derrotado vira **fantasma**, continua atrapalhando a partida e pode ressuscitar uma única vez.

> **Status:** Fases 1 a 6 prontas: login privado, salas em tempo real, catálogo e baralhos, motor de turnos e combate (7 ataques, defesas, Reverso do Reverso, Mais Odiado, golpe fatal com Ressuscitou o Tio Paulo e Última Palavra). Próximo passo: sabotagem, caos, recuperação e reviravoltas (Fase 7). A especificação completa está em [BARALHO_DA_RESENHA_PLANO_TECNICO.md](BARALHO_DA_RESENHA_PLANO_TECNICO.md).

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

O seed cria dez contas de teste, de **teste1** a **teste10** (a teste10 é reservada a um teste automático). A senha de todas é `resenha123`. Para testar uma sala, abra janelas anônimas diferentes, uma para cada conta.

O painel do banco local fica em http://127.0.0.1:54323.

### Scripts

| Comando                | O que faz                                                                            |
| ---------------------- | ------------------------------------------------------------------------------------ |
| `pnpm dev`             | Servidor de desenvolvimento                                                          |
| `pnpm build`           | Typecheck e build de produção em `dist/`                                             |
| `pnpm check`           | Typecheck, lint, formatação e testes unitários                                       |
| `pnpm test`            | Testes unitários (Vitest)                                                            |
| `pnpm test:db`         | Testes do banco: RLS e permissões (pgTAP)                                            |
| `pnpm test:e2e`        | Testes ponta a ponta no desktop e no celular (Playwright, precisa do Supabase local) |
| `pnpm db:reset`        | Recria o banco local do zero: migrações e seed                                       |
| `pnpm db:types`        | Regenera `src/types/database.generated.ts` depois de mudar o schema                  |
| `pnpm users <comando>` | Gestão de contas pelo administrador (veja abaixo; precisa do `.env.admin`)           |

### Contas e login

O Supabase Auth só aceita senha junto com e-mail ou telefone. Por isso, cada usuário (`leo`, por exemplo) corresponde a um e-mail técnico `leo@<VITE_AUTH_EMAIL_DOMAIN>`. O jogador nunca vê esse e-mail.

- Não existe cadastro público. Ele está bloqueado no Auth (`enable_signup = false`).
- Quem cria e gerencia as contas é o administrador. Senhas novas são geradas aleatoriamente e aparecem uma única vez no terminal:

  ```bash
  pnpm users create leo "Leo"      # cria a conta (o perfil nasce do app_metadata.username)
  pnpm users reset-password leo    # recuperação de senha (não existe "esqueci a senha" por e-mail)
  pnpm users disable leo           # bloqueia no Auth e derruba a sessão aberta no app
  pnpm users enable leo
  pnpm users list
  pnpm users remove leo --confirmar  # exclui; se já jogou, anonimiza em vez de excluir
  ```

- O `.env.admin` guarda a secret key. Copie de `.env.admin.example` e nunca faça commit desse arquivo.

> Só `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` e `VITE_AUTH_EMAIL_DOMAIN` podem ficar em variáveis `VITE_*`. Elas vão para o navegador. A secret key / `service_role` nunca pode ir para lá.

### Salas e tempo real

- As tabelas das salas ficam no schema `app_private`, que não é exposto. O navegador só usa as RPCs (`create_room`, `join_room`, `start_game` e as outras), e cada uma confere quem está chamando e se a pessoa faz parte da sala.
- Toda mudança aumenta `games.version` e o banco manda um aviso `game_changed` no canal privado `game:<id>`. O aviso só leva o id e a versão. Quem recebe busca o estado de novo.
- Se o tempo real cair, a tela passa a consultar a cada 5 segundos até reconectar.
- O código da sala tem 10 caracteres, nunca se repete e o host pode trocar por um novo a qualquer momento. Quem o host remove só volta se ele liberar.
- Cada tela aberta manda um sinal de presença ao banco a cada 20 segundos. É esse sinal, com o horário do servidor, que define quem está conectado: quando o host sai, o posto passa ao conectado mais antigo.
- Os lugares da partida são sorteados no banco ao iniciar.
- **Em produção:** em Realtime → Settings, desligue o acesso público (deixe só canais privados).

### Cartas

- O catálogo (`app_private.card_definitions`) é versionado por `set_version`. Se mudar um efeito, crie uma versão nova em vez de editar a atual: partidas que já começaram continuam na versão em que começaram.
- Cada partida cria 180 linhas em `game_cards`, uma por cópia, com zona (baralho, descarte, mão) e posição. O embaralhamento acontece no banco.
- O navegador nunca lê `game_cards`. A RPC `get_game_view` devolve a sua mão; dos outros jogadores, só a quantidade de cartas. A ordem dos baralhos nunca sai do banco.
- **GHO-05 ("Eu Sei o Que Você Fez")** está marcada como provisória (`is_provisional`) até o grupo aprovar o efeito novo.

### Turnos

- Toda jogada passa por `submit_game_command`, com a versão da mesa e um `request_id` por clique. O banco trava a partida, valida quem está na vez e a fase, aplica tudo numa transação e grava um evento público. O mesmo `request_id` nunca é aplicado duas vezes, então clique duplo e retry de rede são seguros.
- O histórico (`game_events`) mostra compras só como contagem. Descartes aparecem com as cartas, porque a pilha é aberta.

### Combate

- `PLAY_CARD` valida carta, alvos e custo, gasta a ação e abre uma janela de reação com o dano já fixado (inclui o +1 do Mais Odiado).
- Cada alvo responde com `RESPOND`, mesmo fora da vez: aceitar ou usar uma reação permitida. A lista de reações válidas vem do banco e só aparece para a própria pessoa.
- Com todas as respostas, o banco aplica o dano em lote, transforma os mortos em fantasmas, conta as eliminações e trata Última Palavra, o dano próprio da A Braba e a morte no próprio turno.

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
- [Decisões aprovadas](BARALHO_DA_RESENHA_DECISOES_APROVADAS.md): regras e escolhas de produto que prevalecem sobre o plano em caso de conflito
