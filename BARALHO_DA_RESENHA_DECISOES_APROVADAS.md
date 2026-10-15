# BARALHO DA RESENHA — DECISÕES APROVADAS

**Documento:** Registro consolidado de decisões de produto, regras e implementação  
**Versão:** 1.0  
**Data:** 15/10/2026  
**Referência:** `BARALHO_DA_RESENHA_PLANO_TECNICO.md`  
**Jogo:** Resenha Simples v7.1  
**Status:** Decisões aprovadas para orientar as próximas fases. Dependências externas de lançamento estão identificadas ao final.

> **Como aplicar:** este registro complementa o plano técnico. Havendo conflito entre o plano anterior e uma decisão explícita deste arquivo, **prevalece este arquivo** para os itens A–F. Não alterar outras regras ou efeitos de cartas sem aprovação.

---

## 1. Premissas do projeto (mantidas)

- **Frontend:** React, TypeScript, Vite, Tailwind CSS e shadcn/ui.
- **Dados, autenticação, motor autoritativo e multiplayer:** Supabase Auth, PostgreSQL, RPC transacional, RLS, Realtime e Storage.
- **Hospedagem:** Vercel.
- **Sem backend próprio separado** em Express, NestJS ou outro servidor de aplicação.
- **MVP:** salas privadas de **3 a 8 jogadores**, sem espectadores.
- **Catálogo:** **180 cartas**, sendo 160 do baralho principal e 20 do Baralho do Além, com **35 modelos de face** e **2 tipos de verso**.
- **Regras principais:** sem objetivos secretos ou Pontos de Resenha; vitória por sobrevivência; até 10 rodadas; uma ressurreição por jogador.
- **Autoridade:** toda decisão que altera estado da partida, cartas, vida, jogador da vez, ações, eliminações e vencedor é validada e aplicada no banco. Nenhum cálculo fornecido pelo cliente deve ser tratado como verdade.

---

## 2. A — Turnos (necessário antes da Fase 5)

| ID     | Decisão aprovada                                                                                   | Implementação / observação                                                                                                                      |
| ------ | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **A1** | **Sortear a ordem dos lugares** quando a partida iniciar.                                          | Sorteio executado no banco; persistir assentos e ordem para reconexão. Não usar a ordem de entrada na sala.                                     |
| **A2** | **O ocupante do lugar 1 começa a rodada 1.**                                                       | Como os lugares foram sorteados, o host não ganha preferência.                                                                                  |
| **A3** | **Todos compram 2 cartas no início de cada turno vivo**, inclusive o primeiro jogador na rodada 1. | Cada jogador começa com 5 cartas. O primeiro poderá ficar com 7 cartas antes de agir.                                                           |
| **A4** | **Mostrar somente a carta do topo do descarte** na mesa.                                           | Histórico de jogadas detalhado previsto para a Fase 9. O descarte público completo pode existir em dados/histórico autorizados sem poluir a UI. |

**Critérios de aceite da Fase 5:** sorteio feito uma única vez por partida; reload não muda assentos; a primeira compra funciona para todos; o turno avança corretamente; a pilha mostra a última carta descartada.

---

## 3. B — Cartas e regras (necessário antes das Fases 6–8)

| ID     | Decisão aprovada                                                                 | Regra definitiva                                                                                                                                                                                                                                                                                                                         |
| ------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B1** | **Aprovar novo efeito de GHO-05 com informação privada.**                        | `Eu Sei o Que Você Fez — Ju Amorim`: escolha um vivo, veja **até 2 cartas aleatórias** da mão dele e escolha **1 das cartas vistas** para descartar. **Só o fantasma autor vê a identidade das cartas**; os demais veem apenas a ação e o descarte público resultante. Se o alvo não tiver cartas, não há descarte. Manter **2 cópias**. |
| **B2** | **Evento Raro não cancela `Lucboy & Laragirl` (REV-02).**                        | REV-02 pertence à categoria **Reviravolta**, não Sabotagem.                                                                                                                                                                                                                                                                              |
| **B3** | **Evento Raro não cancela cartas do Além.**                                      | Cartas do Além não pertencem à categoria Sabotagem.                                                                                                                                                                                                                                                                                      |
| **B4** | **`Família Basilato` não admite defesa comum, mas admite reação de dano fatal.** | Por ser carta de Caos, não pode ser anulada com defesas comuns contra ataques. Se o dano da carta for fatal, a vítima pode usar **uma** reação elegível: `Ressuscitou o Tio Paulo` (sobrevive com 1 PV) **ou** `Última Palavra` (morre e causa 2 ao responsável), não ambas.                                                             |
| **B5** | **Se o jogador morrer no próprio turno, o turno termina imediatamente.**         | Ações ainda não utilizadas são perdidas. Caso se torne fantasma, seu primeiro turno de fantasma ocorrerá na rodada seguinte.                                                                                                                                                                                                             |
| **B6** | **O dano próprio de `A Braba` pode ativar `Ressuscitou o Tio Paulo`.**           | `Última Palavra` **não** ativa, pois não houve eliminação causada por **outro jogador**. Resolver o ataque ao alvo e as respectivas reações antes de aplicar o dano próprio ao autor.                                                                                                                                                    |
| **B7** | **Manter os valores da versão 7.1 até testes reais.**                            | Ressaca: rodadas 1–4 = 0; 5–6 = 1; 7–8 = 2; 9–10 = 3. Limite de 10 rodadas. Desempate por eliminações conforme regras atuais. Não rebalancear antes do playtest.                                                                                                                                                                         |

### B.1 Reações: regra geral de implementação

- Cada jogador afetado pode usar **no máximo uma reação por ação**.
- Em ações que permitirem uma reação especial por dano fatal, o jogador deverá **escolher entre reações elegíveis**; não é permitido acumular `Ressuscitou o Tio Paulo` e `Última Palavra` para o mesmo evento.
- `Ressuscitou o Tio Paulo` é uma **sobrevivência preventiva**: o jogador permanece vivo com 1 PV, sem registrar eliminação.
- `Última Palavra` acontece **ao ser eliminado** por outro jogador e não impede a morte; o dano de 2 pode causar nova eliminação. Registrar a origem de cada dano e resolver os efeitos em ordem determinística.
- Os eventos devem ser processados de forma transacional, com idempotência e sem expor cartas privadas a outros clientes.
- **Dano ambiental da Ressaca Progressiva não permite** `Ressuscitou o Tio Paulo` ou `Última Palavra`.

### B.2 Balanço e condição de vitória preservados

1. O **último jogador vivo** vence quando não houver possibilidade válida de retorno de fantasmas dentro do limite da partida.
2. Se a partida chegar ao fim da rodada 10 com mais de um vivo, vence quem tiver **mais PV**; em empate, maior número de eliminações; persistindo, vitória compartilhada.
3. Se a Ressaca eliminar simultaneamente todos os sobreviventes, comparar os **PV imediatamente anteriores** ao dano; em empate, comparar eliminações; persistindo, vitória compartilhada.
4. Em outras eliminações simultâneas ou ausência de vivos, aplicar a regra determinística de desempate definida no plano técnico, sem inventar pontos adicionais.
5. A contabilização de eliminações existe **apenas como critério de desempate**, não como sistema de PR.

---

## 4. C — Visual e conteúdo (antes da Fase 9)

| ID     | Decisão aprovada                                                | Regra de trabalho                                                                                                                                                                  |
| ------ | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **C1** | **Autorização individual para imagens e frases provocativas.**  | Cada integrante aprova o uso de sua foto e das referências ligadas a ele antes da publicação. Oferecer opção de substituir imagem, frase ou personagem se não houver concordância. |
| **C2** | **35 artes de face e 2 versos**, inicialmente com placeholders. | O sistema deve exibir automaticamente a arte definitiva quando existir no Storage, sem mudar os IDs e efeitos das cartas.                                                          |
| **C3** | **Roxo, símbolo “R” e fonte Geist são provisórios.**            | Manter até ser definida a identidade visual final; criar tokens de tema para simplificar substituições.                                                                            |
| **C4** | **Usar nomes reais somente com aprovação.**                     | Permitir nome de exibição/apelido. Separar identificador técnico imutável do texto apresentado na carta.                                                                           |

**Dados de apresentação recomendados:** `card_id`, `character_id` (quando existir), `display_name`, `nickname`, `art_path`, `flavor_text`, `theme_category`. Alterar artes, textos e nomes **não deve alterar efeitos nem resultados das cartas**.

---

## 5. D — Infraestrutura e lançamento (antes da Fase 11)

| ID     | Decisão aprovada                                                           | Encaminhamento                                                                                                                                                                                             |
| ------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D1** | **Domínio próprio ou subdomínio controlado para as contas técnicas.**      | Ex.: `contas.seudominio.com`. Não usar endereços fictícios sob domínios de terceiros. Planejar confirmação de contas e recuperação administrativa segura.                                                  |
| **D2** | **Hospedagem na Vercel.**                                                  | Manter deploy por ambiente com variáveis públicas do Supabase correspondentes; jamais publicar credencial `service_role` em build frontend.                                                                |
| **D3** | **Produção em Supabase na região São Paulo (`sa-east-1`), se disponível.** | Proprietário do projeto cria a instância e configura acesso mínimo necessário. Conferir disponibilidade da região e custos no momento da criação.                                                          |
| **D4** | **Contas provisionadas pelo administrador via CLI.**                       | Comando previsto: `pnpm users create`. Receber lista de usernames/nomes autorizados; executar somente em ambiente seguro, sem chaves administrativas no browser ou logs.                                   |
| **D5** | **Apagar partidas encerradas há mais de 90 dias.**                         | Política documentada e rotina de limpeza confiável (por exemplo, Supabase Cron). Eliminar registros relacionados e dados de sessão; manter estatísticas agregadas não identificáveis apenas se necessário. |
| **D6** | **Staging em projeto Supabase separado.**                                  | Preferencialmente segundo projeto gratuito **se houver capacidade/limites disponíveis**. Não replicar dados pessoais de produção; migrações e seeds separados.                                             |

**Dependências de lançamento ainda não preenchidas:** domínio real, projeto Supabase de produção e suas credenciais configuradas, lista de contas e consentimento dos participantes. Essas dependências **não impedem** o desenvolvimento com ambiente de staging e dados de teste.

---

## 6. E — Decisões técnicas revisadas

### E1 — Código da sala recuperável pelo host **[APROVADO COM RESTRIÇÕES]**

- Armazenar o código de sala em **texto legível em tabela/esquema privado**, em vez de obrigatoriamente armazená-lo como hash, para permitir ao host consultá-lo após reload.
- Usar código aleatório com **pelo menos 10 caracteres**, gerado no servidor; não usar códigos sequenciais ou previsíveis.
- O código **não** deve ser acessível em consultas públicas, listagens abertas ou eventos Realtime.
- Expor leitura apenas por **RPC que verifica autenticação e participação/autorização**. O host pode rever o código; a UI só o mostra a quem é autorizado.
- Impor limitação de tentativas e permitir rotação/invalidação do código.
- **Observação de segurança:** código da sala é um segredo de acesso compartilhado, não uma senha de usuário. Mesmo com tabela privada, quem obtiver o código poderá tentar entrar; manter controles de ingresso e rate limit.

### E2 — Saída/desconexão durante a partida **[MODIFICADO]**

- **Fechar aba, perder internet ou atualizar página não equivale a desistir.** Preservar estado para reconexão.
- O jogador desconectado **não é eliminado automaticamente**.
- Depois de **mais de 2 minutos** sem conexão confirmada, o host **pode solicitar remoção manual**; a remoção não é automática.
- A RPC de remoção deve validar autoridade do host, ausência do alvo e período de tolerância; o status de conexão deve usar registros do servidor de forma conservadora, e não apenas uma indicação manipulável pelo navegador.
- Exibir confirmação para o host, registrar motivo e autoria da remoção.
- O jogador removido passa a **desistente**, não fantasma, **sem direito a ressuscitar ou retornar à mesma partida**. Suas cartas são descartadas de forma consistente e ele sai da disputa por vitória.
- Se houver ação pendente, definir resolução determinística e transacional antes de avançar turno; nunca deixar a partida travada por uma reação de um participante removido.
- Host **não pode expulsar um jogador conectado durante uma partida normal**. É permitido remover jogadores do lobby conforme permissões.

### E3 — Limites antisspam e de participação **[APROVADO]**

- **10 tentativas inválidas de código em 10 minutos por conta**, com bloqueio temporário das novas tentativas. Implementar no servidor/RPC, não apenas no React.
- **Máximo de 5 salas de espera por usuário**. Validar atomicamente ao entrar/criar sala.
- Considerar proteção adicional contra abuso por IP/rede se surgir necessidade operacional, sem bloquear injustamente usuários de uma mesma rede.

### E4 — Status “Pronto” **[APROVADO]**

- `Pronto` é **informativo**, nunca condição obrigatória para o host iniciar.
- O host só poderá iniciar se houver quantidade permitida de participantes (3–8) e demais validações do estado do lobby.

### E5 — Retorno após remoção no lobby **[MODIFICADO]**

- Quem foi **removido/expulso do lobby pelo host não pode voltar usando apenas o mesmo código**.
- O host poderá **autorizar explicitamente** sua reentrada, caso queira.
- Registrar a restrição por usuário + sala (não apenas por sessão), com validação na RPC de entrada.
- **Desconexão simples** não equivale a expulsão: participantes não expulsos continuam podendo reconectar normalmente.

### E6 — Transferência de host **[APROVADO COM AJUSTE]**

- Se o host **sair voluntariamente de um lobby**, transferir função ao **participante conectado mais antigo** elegível; usar ordem de ingresso como desempate.
- Durante uma partida, **mera perda temporária de conexão não deve transferir host imediatamente**: respeitar tolerância e política de continuidade da partida.
- Se for necessária sucessão durante partida (ex.: host abandonou de fato), implementar transferência por regra segura do servidor, sem perda de estado nem ampliação de acesso a cartas privadas.
- Nunca permitir que dois hosts sejam promovidos simultaneamente (operação transacional).

### E7 — Exclusão de usuários **[MODIFICADO]**

- **Desativar conta** é a opção administrativa padrão para preservar a integridade dos históricos.
- Não tornar exclusão impossível: suportar **exclusão e/ou anonimização** quando houver fundamento legítimo, respeitando dados pessoais e integridade referencial.
- Desativação remove a capacidade de autenticação/participação conforme política, mas não apaga arbitrariamente partidas em andamento; especificar tratamento de vínculo com sessões ativas.

### E8 — Ferramentas de lint **[APROVADO]**

- Usar **oxlint** no lugar de ESLint no projeto inicial.
- Complementar com **Prettier**, verificação `tsc --noEmit` e testes automatizados.
- Revisar necessidade de regras adicionais de React/TypeScript que não sejam cobertas pelo oxlint instalado; manter qualidade equivalente em CI.

### E9 — Ordem das cartas na mão **[APROVADO]**

- Exibir inicialmente na **ordem de recebimento/compra**.
- Manter IDs de instância estáveis para impedir duplicações e confusões após reload.
- A reorganização manual por arrastar poderá ser adicionada em versão futura, sem afetar a ordem real do baralho.

---

## 7. F — Fora do MVP **[CONFIRMADO]**

| Funcionalidade                           | Decisão                                                      |
| ---------------------------------------- | ------------------------------------------------------------ |
| Cronômetro automático por turno e reação | **Fora do MVP**. Não implementar timeout de 60 s/20 s agora. |
| Espectadores                             | Fora do MVP.                                                 |
| Partidas de 9–15 jogadores               | Fora do MVP; foco em 3–8.                                    |
| Painel administrativo visual             | Fora do MVP; administração por CLI/painel Supabase.          |
| Recuperação de senha por e-mail          | Fora do MVP; redefinição administrativa segura.              |

**Importante:** a retirada do cronômetro automático **revoga a recomendação anterior de incluí-lo no MVP**. A regra E2 permite ao host tratar jogadores comprovadamente desconectados por mais de dois minutos, mas **não resolve um jogador conectado e inativo**. No MVP, o grupo deverá solicitar que ele jogue ou encerrar a partida se a situação impedir a continuidade. Essa é uma limitação aceita, não uma funcionalidade implementada.

---

## 8. Ordem de aplicação por fase

| Antes da fase                                        | Decisões a incorporar | Entregas esperadas                                                                                                         |
| ---------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Fase 5 — Turnos**                                  | A1–A4, E4, E6, E9     | Ordem sorteada, primeiro turno, compra inicial, descarte visível, sucessão de host e consistência pós-reload.              |
| **Fases 6–8 — Cartas, reações, fantasmas e vitória** | B1–B7, E2, E3, E5     | Resolução determinística de efeitos e reações, validação de desconexões/abandono, regras de vitória e regras de segurança. |
| **Fase 9 — Visual**                                  | C1–C4                 | Assets provisórios e definitivos substituíveis, identidade visual, consentimento e nomes/apelidos.                         |
| **Fase 11 — Implantação**                            | D1–D6, E1, E7, E8     | Infraestrutura de produção/staging, contas, segurança, limpeza de dados e CI.                                              |
| **Planejamento geral/MVP**                           | F                     | Excluir das entregas iniciais os recursos explicitamente adiados.                                                          |

> As fases indicam **quando cada decisão se torna indispensável**. Decisões de segurança e estrutura de dados podem exigir preparação anterior às fases listadas; não adiar RLS, validação transacional ou testes de autorização se já forem necessários na Fase 5.

---

## 9. Checklist de verificação para a IA de desenvolvimento

- [ ] Atualizar o plano técnico principal de acordo com A1–A4, B1–B7, C1–C4, D1–D6, E1–E9 e F.
- [ ] Remover regras contraditórias antigas (principalmente cronômetro no MVP e expulsão/reentrada de jogadores).
- [ ] Manter 160 cartas principais + 20 do Além = **180**, com **35 faces/modelos** e **2 versos**.
- [ ] Aplicar o efeito privado aprovado de GHO-05 sem vazamento de informações.
- [ ] Implementar histórico suficiente para explicar ações, danos, mortes, retornos e desempates.
- [ ] Garantir que RPCs usem `auth.uid()`, verifiquem a participação/autorização e executem mudanças de estado em transações idempotentes.
- [ ] Testar ataque fatal, reação fatal, dano próprio, Ressaca, múltiplas mortes, primeiro turno e ressurreição.
- [ ] Testar reconexão, remoção autorizada após ausência, transferência de host e reentrada negada após expulsão.
- [ ] Testar que um jogador não lê mãos, objetivos inexistentes, ordem dos baralhos nem códigos de salas sem autorização.
- [ ] Preparar staging e produção com configuração separada, dados de teste e migrações versionadas.
- [ ] Validar permissões de imagem e apelidos antes da divulgação pública.
- [ ] Não implementar funcionalidades fora do MVP sem nova decisão explícita.

---

## 10. Dependências que permanecem externas (não são dúvidas de regra)

1. **Autorização dos participantes** para uso de imagens, nomes e frases; obter individualmente antes de publicar conteúdo definitivo.
2. **Identidade visual definitiva:** logo, cores e fonte; placeholders podem ser usados até lá.
3. **Domínio ou subdomínio real** controlado pelo projeto para contas técnicas, com fluxo administrativo seguro de credenciais.
4. **Projeto Supabase de produção** e região confirmada, além de staging separado conforme orçamento e limites disponíveis.
5. **Lista autorizada de usuários** para provisionamento das contas.
6. **Playtests com 3, 5 e 8 jogadores** para validar duração, Ressaca e diversão antes de considerar o balanceamento encerrado.

Esses pontos **não impedem iniciar a Fase 5** com dados e imagens de teste.

---

## 11. Instrução para aplicar estas decisões ao documento mestre

```text
Leia BARALHO_DA_RESENHA_DECISOES_APROVADAS.md e BARALHO_DA_RESENHA_PLANO_TECNICO.md.
Incorpore ao documento mestre todas as decisões dos grupos A–F deste registro.
Quando houver conflito, prevaleça o documento de decisões aprovado.
Preserve o catálogo de 180 cartas e a arquitetura React + TypeScript + shadcn/ui + Supabase,
sem backend de aplicação separado.
Atualize regras, fluxo de telas, modelos de dados, funções RPC, RLS, cenários de teste,
planejamento das fases e critérios de aceite afetados.
Não implemente novas funcionalidades nesta tarefa e não modifique outras regras silenciosamente.
Liste as seções alteradas e eventuais dependências externas remanescentes.
```

---

**Fim do registro de decisões — v1.0.**
