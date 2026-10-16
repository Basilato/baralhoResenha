# Beta fechado: roteiro de teste

Para o grupo jogar as primeiras partidas de verdade e anotar o que der errado. Leva uns 40 minutos.

## Antes de começar (administrador)

1. Crie as contas: `pnpm users create <usuário> "<Nome>"`. Mande cada senha no privado.
2. Envie as artes: `pnpm art:upload`.
3. Combine um grupo de mensagens para os relatos (print + o que você fez + o que esperava).

## Partidas

Cada partida com um tamanho de mesa e uma mistura de aparelhos diferente. Marque ✅ ou ❌.

| #   | Jogadores | Aparelhos                        | O que observar                                                 |
| --- | --------- | -------------------------------- | -------------------------------------------------------------- |
| 1   | 3         | 2 celulares + 1 computador       | Login, criar sala, entrar pelo link, tutorial, primeira rodada |
| 2   | 5         | celulares Android e iPhone       | Ataques e defesas, a janela de reação, sons, histórico         |
| 3   | 8         | o máximo de aparelhos diferentes | Mesa cheia no celular, ritmo da partida, Ressaca e fantasmas   |

## Em cada partida, tente pelo menos uma vez

- [ ] Recarregar a página no meio da partida (e no meio de um ataque contra você).
- [ ] Trocar de aba ou bloquear o celular por 1 minuto e voltar.
- [ ] Desligar o Wi-Fi por uns segundos e religar.
- [ ] Clicar duas vezes rápido em "Jogar" ou "Encerrar turno".
- [ ] Abrir a mesma partida em duas abas.
- [ ] Silenciar os sons pelo botão da mesa e ativar "Reduzir animações" no menu.
- [ ] Morrer, jogar como fantasma e (se der) ressuscitar.
- [ ] Ao fim, pedir revanche.

## Como relatar um problema

- **O que aconteceu:** "cliquei em Jogar e a carta sumiu da mão, mas ninguém levou dano".
- **O que você esperava.**
- **Aparelho e navegador:** "iPhone 13, Safari".
- **Print da tela** e, se possível, a hora aproximada.

O administrador investiga uma partida suspeita com `admin_check_game_integrity` (Supabase, SQL Editor), que lista qualquer inconsistência nas cartas, na vida ou na vez.

## Já verificado automaticamente

- Auditoria de segurança no banco (`security.test.sql`): só as RPCs do app ficam expostas, intruso não vê nem joga, e o Realtime não carrega cartas.
- Integridade conferida depois de cada jogada em 60 partidas simuladas (`pnpm sim`, relatório em [BALANCEAMENTO.md](BALANCEAMENTO.md)).
- Cliques duplos e duas abas ao mesmo tempo (`concurrency.spec.ts`), recarregar no meio de uma reação e queda de conexão (`reconnect.spec.ts`).
