# Artes das cartas

Briefing completo (estilo, tamanhos e o prompt de cada carta): [docs/ARTES_PROMPTS.md](../docs/ARTES_PROMPTS.md).

## Onde colocar cada arquivo

```text
art/cards/7.1/
├── source/          ← originais em PNG, com o código da carta como nome (versionados no git)
│   ├── ATK-01.png
│   ├── ...
│   ├── BACK-MAIN.png
│   └── BACK-GHOST.png
├── web/             ← gerado por `pnpm art:build` (fora do git)
│   ├── ATK-01.webp
│   ├── ATK-01_thumb.webp
│   └── contact-sheet.webp
└── manifest.json    ← gerado: o que está pronto e o que falta
```

- **Nome:** só o código da carta, em maiúsculas: `ATK-01.png`, `GHO-05.png`, `BACK-MAIN.png`. Nada de nome da carta, aspas ou espaços.
- **Formato:** PNG, proporção 4:3 nas faces (ideal 1536 × 1152) e 63:88 nos versos (1575 × 2200).
- `7.1` é a versão do catálogo. Se um dia o efeito de uma carta mudar, as artes da versão nova ficam em outra pasta.

## Adicionar ou trocar uma arte

1. Salve o PNG em `art/cards/7.1/source/` com o nome do código. Para trocar uma arte, sobrescreva o arquivo.
2. Rode `pnpm art:build`. O script:
   - confere a proporção e o tamanho;
   - gera o WebP e a miniatura em `web/`;
   - atualiza a folha de contato (`web/contact-sheet.webp`), para revisar tudo de uma vez;
   - lista o que ainda falta.
3. Confira a folha de contato: sem texto na imagem, personagem certo, foco no centro.
4. Rode `pnpm art:upload` para enviar as artes ao Storage (bucket privado `card-art`) e ligar cada carta à sua arte. O script lê `.env.admin` (`SUPABASE_URL` e `SUPABASE_SECRET_KEY`): use o arquivo do ambiente local para testar e o de produção para publicar. Pode rodar de novo quantas vezes quiser.

O app mostra a arte sozinho quando ela existe no Storage. Sem arte, a carta continua com o placeholder. Depois de `pnpm db:reset`, rode `pnpm art:upload` de novo: o reset apaga a ligação entre carta e arte.

## Andamento (catálogo 7.1)

**31 de 37 prontas.**

| Código     | Carta                      | Status    |
| ---------- | -------------------------- | --------- |
| ATK-01     | Falou Merda                | ✅ pronta |
| ATK-02     | Não Vou Levar Numa Boa     | ✅ pronta |
| ATK-03     | Peneira Suprema            | ✅ pronta |
| ATK-04     | Fofoca Mortal              | ✅ pronta |
| ATK-05     | Print Comprometedor        | ✅ pronta |
| ATK-06     | Lor!                       | ✅ pronta |
| ATK-07     | A Braba                    | ✅ pronta |
| DEF-01     | It's Not Amazing           | ✅ pronta |
| DEF-02     | Inimiga do Banho           | ✅ pronta |
| DEF-03     | Eu Tava Dormindo           | ✅ pronta |
| DEF-04     | Reverso do Reverso         | ✅ pronta |
| DEF-05     | Evento Raro                | ✅ pronta |
| DEF-06     | Último do After            | ✅ pronta |
| SAB-01     | Anota na Conta da Tuca     | ✅ pronta |
| SAB-02     | Terapia de Boteco          | ✅ pronta |
| SAB-03     | Tem Alguém Seguindo        | ✅ pronta |
| SAB-04     | Eu Amo Mentir              | ✅ pronta |
| SAB-05     | Plano Dental Negado        | ✅ pronta |
| CAO-01     | Tio Paulo                  | ✅ pronta |
| CAO-02     | Bucetada                   | ✅ pronta |
| CAO-03     | Família Basilato           | ⬜ falta  |
| CAO-04     | O Acre Existe!             | ✅ pronta |
| REC-01     | After do After             | ✅ pronta |
| REC-02     | Inimiga do Fim             | ⬜ falta  |
| REC-03     | Consultório Lucboy         | ✅ pronta |
| REC-04     | Anestesia Alcoólica        | ⬜ falta  |
| REC-05     | English Mode               | ⬜ falta  |
| REV-01     | Ressuscitou o Tio Paulo    | ✅ pronta |
| REV-02     | Lucboy & Laragirl          | ✅ pronta |
| REV-03     | Última Palavra             | ✅ pronta |
| GHO-01     | Victor Voltou Passando Mal | ✅ pronta |
| GHO-02     | Fantasma Fofoqueiro        | ✅ pronta |
| GHO-03     | Mão de Defunto             | ✅ pronta |
| GHO-04     | Maldição da Ressaca        | ✅ pronta |
| GHO-05     | Eu Sei o Que Você Fez      | ✅ pronta |
| BACK-MAIN  | Verso do baralho principal | ⬜ falta  |
| BACK-GHOST | Verso do Baralho do Além   | ⬜ falta  |

As 31 prontas têm 1448 × 1086 px, a proporção certa (4:3) e dentro da tolerância do script. Para as próximas, prefira 1536 × 1152.

A lista sempre atualizada fica em `manifest.json`, depois de rodar `pnpm art:build`.
