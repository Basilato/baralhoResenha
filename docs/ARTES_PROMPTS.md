# Baralho da Resenha — briefing de artes para IA de imagem

**Para quem é este arquivo:** uma IA (ou designer) que vai criar as artes das cartas.
**O que entregar:** 35 artes de face (uma por modelo de carta) e 2 versos. São **37 imagens**.
**Jogo:** Resenha Simples v7.1 · catálogo `7.1` · idioma do jogo: português do Brasil.

Leia as seções 1 a 5 antes de gerar qualquer imagem. Elas valem para **todas** as artes. Os blocos da seção 6 trazem o prompt pronto de cada carta.

---

## 1. Regras que não podem ser quebradas

1. **Sem nenhum texto na imagem.** Nada de letras, palavras, números, legendas, placas legíveis, logos ou marca d'água. O app desenha por cima o nome da carta, a categoria, a regra e o código. Balões de fala podem existir, mas só com símbolos (raio, caveira cartunesca, estrelas, notas musicais), nunca com escrita.
2. **Sem moldura e sem layout de carta.** Entregue só a ilustração, ocupando a imagem inteira (sangrada). O app aplica moldura, cantos e textos.
3. **Pessoas reais: só com autorização.** Os personagens são amigos reais do grupo. Siga a seção 4: sem autorização registrada, crie um personagem estilizado original, **sem semelhança com ninguém**.
4. **Humor de resenha, não ofensa.** Pode ser debochado, exagerado e cartunesco, mas sem nudez, sem conteúdo sexual, sem sangue nem violência gráfica, sem armas reais apontadas e sem estereótipos ofensivos. Bebida alcoólica pode aparecer em contexto de festa entre adultos, sem glamourizar excesso.
5. **Legível pequeno.** No celular, a carta aparece com uns 96 px de largura. Cada arte precisa de **um foco claro** e de silhueta forte, com o rosto ou a ação principal grandes e no centro.

---

## 2. Especificações técnicas

### 2.1 Arte de face (35 imagens)

| Item                      | Valor                                                                                                                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tamanho do arquivo mestre | **1536 × 1152 px** (proporção 4:3, paisagem)                                                                                                                                                    |
| Área segura               | O rosto e a ação principal ficam dentro do **quadrado central de 1024 × 1024 px**. Nada importante nos 15% de cada borda.                                                                       |
| Por que a área segura     | O app recorta a arte para caber na carta (`object-fit: cover`). Dependendo do tamanho da carta, o recorte vai de quase quadrado (~1:1, carta pequena da mão) a paisagem (~1,45:1, carta média). |
| Cor                       | sRGB, sem transparência (fundo pintado até a borda)                                                                                                                                             |
| Formato de entrega        | `PNG` mestre + `WebP` qualidade 85 no mesmo tamanho + `WebP` miniatura **512 × 384 px**                                                                                                         |
| Nome do arquivo           | código da carta: `ATK-01.png`, `ATK-01.webp`, `ATK-01_thumb.webp`                                                                                                                               |

Na carta, a arte fica entre o cabeçalho colorido (nome da carta) e a caixa de texto da regra. A tira de cima e a de baixo da arte podem aparecer pouco ou nada, dependendo do tamanho da carta.

### 2.2 Versos (2 imagens)

| Item                | Valor                                                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Tamanho             | **1575 × 2200 px** (63 × 88 mm, proporção exata de carta de pôquer, retrato)                                           |
| Margem de segurança | 80 px em todas as bordas (o app arredonda os cantos)                                                                   |
| Formato             | `PNG` + `WebP` qualidade 85 + `WebP` miniatura **450 × 629 px**                                                        |
| Nomes               | `BACK-MAIN.png` (baralho principal) e `BACK-GHOST.png` (Baralho do Além)                                               |
| Logo                | Ainda é provisório. **Não desenhe logo nem letra.** Deixe um medalhão vazio no centro para o logo ser aplicado depois. |

### 2.3 Onde os arquivos entram no projeto

Entregue **só o PNG**, com o código da carta como nome (`ATK-01.png`), na pasta `art/cards/7.1/source/` do repositório. O WebP e a miniatura são gerados por `pnpm art:build`. O passo a passo e a lista do que já está pronto estão em [art/README.md](../art/README.md).

Depois, `pnpm art:upload` envia as artes para o Storage do Supabase, no bucket privado `card-art`, no caminho `7.1/<CÓDIGO>.webp` (e `7.1/<CÓDIGO>_thumb.webp`), e preenche o campo `image_path` de cada carta com esse caminho. Trocar uma arte **não muda o efeito** da carta.

---

## 3. Guia de estilo (igual para as 37 artes)

**Estilo:** ilustração 2D cartunesca e vibrante, de carta colecionável. Contorno limpo e marcado, cores chapadas com sombreamento suave em células (cel shading), expressões de quadrinho bem exageradas e energia de meme. Clima de **resenha entre amigos brasileiros**: festa em casa, bar, churrasco, after de madrugada.

**Iluminação:** noite quente (luz de festa, neon e luz de geladeira), com uma luz de destaque na cor da categoria.

**Personagens:** adultos jovens, proporção levemente cabeçuda (cerca de 1:5), rostos grandes e expressivos, enquadrados da cintura para cima na maioria das cartas.

**Consistência:** o mesmo personagem precisa ter o **mesmo visual em todas as cartas** em que aparece (Léo aparece em 5 cartas, Lara em 4, Cadu em 3 e assim por diante). Gere primeiro uma folha de personagem (seção 4) e use-a como referência.

### 3.1 Cor de destaque por categoria

A cor da categoria deve dominar a luz de destaque, os efeitos (aura, raios, fumaça) ou o fundo. O app usa as mesmas cores no cabeçalho e na borda da carta. Os hex abaixo são aproximados.

| Categoria        | Cor                | Hex aprox. | Sensação                                               |
| ---------------- | ------------------ | ---------- | ------------------------------------------------------ |
| Ataque           | vermelho           | `#D93636`  | impacto, explosão, deboche agressivo                   |
| Defesa           | azul               | `#2F6FD0`  | escudo, desvio, tranquilidade                          |
| Sabotagem        | magenta/roxo       | `#A63AA8`  | furtivo, travesso, conspiração                         |
| Caos             | laranja            | `#E8892A`  | bagunça geral, confete, gente demais                   |
| Recuperação      | verde              | `#2E9E5B`  | alívio, energia voltando, brilho de cura               |
| Reviravolta      | ciano/turquesa     | `#1F9AAE`  | virada dramática, redemoinho, troca                    |
| Além (fantasmas) | índigo acinzentado | `#5A5590`  | fantasmagórico, translúcido, névoa, humor mórbido leve |

Cor da marca (versos e detalhes): roxo `#6D3FD1`.

### 3.2 Blocos de estilo para colar nos prompts

Os prompts da seção 6 estão em **inglês**, porque a maioria das IAs de imagem segue melhor instruções em inglês. Cada um já inclui o bloco de estilo abaixo. Se for preciso, use estes trechos de forma isolada.

**Estilo (positivo):**

```
vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

**Negativo (sempre usar):**

```
text, letters, words, numbers, captions, readable signs, speech bubble text, logo, watermark, signature, card frame, border, UI elements, photorealistic, 3D render, nudity, sexual content, gore, blood, real weapons, hate symbols, offensive stereotypes, extra fingers, deformed hands, blurry, low contrast, cluttered background
```

---

## 4. Personagens (consentimento obrigatório)

Os personagens são pessoas reais do grupo. Pelas decisões **C1** e **C4** do projeto:

- **Cada pessoa aprova** o uso da própria imagem, do apelido e da piada da carta antes de a arte ser publicada.
- Se houver aprovação, o grupo preenche a descrição visual abaixo (e pode anexar fotos de referência **autorizadas**). A IA cria uma **caricatura estilizada**, nunca uma foto realista.
- Se **não houver aprovação**, use a descrição genérica da coluna "Sem aprovação", que é um personagem original sem semelhança com a pessoa. O nome na carta pode virar um apelido depois, sem mudar o efeito.

Nos prompts, cada personagem aparece como um **marcador** entre colchetes duplos, por exemplo `[[RYANE]]`. Substitua o marcador pela descrição aprovada ou pela descrição genérica.

| Marcador               | Aparece em                     | Descrição aprovada (o grupo preenche)                        | Sem aprovação (usar no lugar)                                                                 |
| ---------------------- | ------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| `[[RYANE]]`            | ATK-01, CAO-02                 | _cabelo, tom de pele, roupa típica, acessório marcante:_ ___ | young woman with bold curly hair, big hoop earrings, colorful party top                       |
| `[[ANA_VI]]`           | ATK-02, DEF-03                 | ___                                                          | young woman with straight dark bob haircut, denim jacket                                      |
| `[[ARTUR]]`            | ATK-03, GHO-04                 | ___                                                          | young man with short beard and backwards cap                                                  |
| `[[LARA]]`             | ATK-04, SAB-02, REV-02, GHO-02 | ___                                                          | young woman with long wavy auburn hair and round glasses                                      |
| `[[LEO]]`              | ATK-05, DEF-04, CAO-01, REV-01 | ___                                                          | young man with messy black hair and a hoodie                                                  |
| `[[ADEIR]]`            | ATK-06                         | ___                                                          | young man with buzz cut and a loud printed shirt                                              |
| `[[ESTEFANIA]]`        | ATK-07, REV-03                 | ___                                                          | young woman with high ponytail and leather jacket                                             |
| `[[VICTOR]]`           | DEF-01, GHO-01                 | ___                                                          | young man with neat side-part hair and plain t-shirt, permanently unimpressed face            |
| `[[MANU]]`             | DEF-02                         | ___                                                          | young woman with messy bun and oversized sweatshirt                                           |
| `[[DAVI]]`             | DEF-05, GHO-03                 | ___                                                          | young man with curly hair and a star-print shirt                                              |
| `[[CADU]]`             | DEF-06, SAB-01, REC-01         | ___                                                          | young man with sunglasses on his head and a tank top                                          |
| `[[JU_AMORIM]]`        | SAB-03, GHO-05                 | ___                                                          | young woman with short pixie cut and a trench coat                                            |
| `[[MIGUEL]]`           | SAB-04                         | ___                                                          | young man with charming smile and a blazer over a t-shirt                                     |
| `[[LUCIANO]]`          | SAB-05, REC-03, REV-02         | ___                                                          | young man with slicked hair and a white coat                                                  |
| `[[FAMILIA_BASILATO]]` | CAO-03                         | _quem aparece, quantas pessoas, traço de família:_ ___       | a big multigenerational family of six with a shared distinctive feature (same thick eyebrows) |
| `[[LETICIA]]`          | CAO-04, REC-05                 | ___                                                          | young woman with braids and an adventurous vest                                               |
| `[[ANNA]]`             | REC-02                         | ___                                                          | young woman with glitter makeup and a sequined jacket                                         |
| `[[GIOVANNA]]`         | REC-04                         | ___                                                          | young woman with a long ponytail and a playful nurse-style party costume                      |
| `[[TIO_PAULO]]`        | CAO-01, REV-01                 | _é o Léo caracterizado? outra pessoa? descrever:_ ___        | middle-aged uncle with mustache, polo shirt and a beer belly, very charismatic                |

**Primeiro passo recomendado:** gere uma **folha de personagens** (um personagem por quadro, de frente, corpo inteiro e fundo neutro) com o estilo da seção 3. Use essa folha como referência em todas as cartas, para manter os rostos iguais.

---

## 5. Como usar cada bloco da seção 6

Cada carta traz:

- **Arquivo:** nome exato do arquivo a entregar.
- **Categoria e cor:** a cor de destaque da seção 3.1.
- **O que a carta faz:** contexto da regra do jogo, para a arte "contar" o efeito.
- **Piada interna:** espaço para o grupo explicar a referência. Se estiver preenchido, ajuste a cena a ele.
- **Cena, composição e elementos obrigatórios:** o que precisa aparecer.
- **Prompt:** pronto para colar. Substitua os marcadores `[[...]]` e use sempre o negativo da seção 3.2.

Antes de entregar, confira o checklist da seção 7.

---

## 6. Artes, uma por uma

### Ataque (cor: vermelho `#D93636`)

#### ATK-01 · Falou Merda

- **Arquivo:** `ATK-01` · **Personagem:** Ryane `[[RYANE]]` · **Cópias no baralho:** 10
- **O que a carta faz:** causa 3 de dano a um adversário.
- **Piada interna (o grupo completa):** ___
- **Cena:** Ryane, no meio da mesa de uma festa, acabou de soltar o comentário mais desastroso da noite. Uma onda de choque vermelha sai da boca dela em direção a um amigo atingido.
- **Composição:** Ryane no centro, da cintura para cima, de frente, com a boca aberta e uma expressão de "falei mesmo"; o alvo desfocado ao fundo, de olhos arregalados.
- **Elementos obrigatórios:** onda de choque cartunesca vermelha, copo derramando, amigos chocados ao fundo.
- **Prompt:**

```
[[RYANE]] at a crowded house party table, mid-sentence after saying something outrageous, mouth open with a smug "yes I said it" expression, a red cartoon shockwave blasting from her mouth toward a shocked friend in the blurred background, a drink spilling, friends gasping, red accent lighting, waist-up, centered composition, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-02 · Não Vou Levar Numa Boa

- **Arquivo:** `ATK-02` · **Personagem:** Ana Vi `[[ANA_VI]]` · **Cópias:** 6
- **O que a carta faz:** causa 3 de dano a um adversário.
- **Piada interna:** ___
- **Cena:** Ana Vi arregaçando as mangas, com uma aura de fogo vermelha e um olhar de "agora é pessoal", apontando para quem a provocou.
- **Composição:** Ana Vi de frente e levemente de baixo para cima (ângulo heroico), braço apontando para a lateral da cena.
- **Elementos obrigatórios:** mangas arregaçadas, aura vermelha flamejante, veia de raiva cartunesca na testa.
- **Prompt:**

```
[[ANA_VI]] rolling up her sleeves with a fierce "now it's personal" glare, red flaming cartoon aura around her, comic anger vein on forehead, pointing decisively off to the side at someone who provoked her, low-angle heroic shot, waist-up, red accent lighting, living room party background softly blurred, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-03 · Peneira Suprema

- **Arquivo:** `ATK-03` · **Personagem:** Artur `[[ARTUR]]` · **Cópias:** 8
- **O que a carta faz:** descarte outra carta como custo; causa 5 de dano (o ataque mais forte).
- **Piada interna:** ___
- **Cena:** Artur empunha uma peneira dourada gigante como se fosse uma arma lendária e "peneira" as pessoas: cartas e figurinhas de gente caem pelos furos. Uma carta queima na outra mão (o custo).
- **Composição:** pose de chefão final, centralizada, com a peneira brilhando atrás dele como um halo.
- **Elementos obrigatórios:** peneira dourada enorme, cartas caindo pelos furos, uma carta pegando fogo na mão (o custo), raios vermelhos.
- **Prompt:**

```
[[ARTUR]] in an epic final-boss pose wielding a giant glowing golden kitchen sieve like a legendary weapon, tiny cartoon people and playing cards falling through its holes, in his other hand a single card burning away as a sacrifice, dramatic red lightning and sparks, sieve glowing behind him like a halo, centered, waist-up, red accent lighting, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-04 · Fofoca Mortal

- **Arquivo:** `ATK-04` · **Personagem:** Lara `[[LARA]]` · **Cópias:** 8
- **O que a carta faz:** causa 2 de dano a até 2 adversários diferentes.
- **Piada interna:** ___
- **Cena:** Lara cochicha nos ouvidos de duas pessoas ao mesmo tempo, uma de cada lado. Das palavras saem dois raios vermelhos que atingem duas silhuetas ao fundo.
- **Composição:** Lara no centro, com dois amigos colados nas laterais; dois raios em "V" saindo do centro.
- **Elementos obrigatórios:** dois alvos (a carta acerta 2), cochicho com a mão em concha, expressão maliciosa.
- **Prompt:**

```
[[LARA]] in the center whispering into the ears of two friends at the same time, one on each side, hand cupped to her mouth, mischievous grin, two red cartoon lightning bolts shooting out of the whispers toward two shocked silhouettes in the background forming a V shape, bar table with drinks, red accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-05 · Print Comprometedor

- **Arquivo:** `ATK-05` · **Personagem:** Léo `[[LEO]]` · **Cópias:** 6
- **O que a carta faz:** causa 4 de dano ao adversário com mais cartas na mão.
- **Piada interna:** ___
- **Cena:** Léo ergue o celular como prova num tribunal. A tela brilha com um "print" borrado (barras de conversa sem texto legível) e um flash vermelho ilumina o acusado, que segura um leque enorme de cartas.
- **Composição:** Léo em primeiro plano, segurando o celular virado para a "câmera"; o acusado ao fundo, suando.
- **Elementos obrigatórios:** celular com tela brilhante sem texto, flash, o alvo com muitas cartas na mão.
- **Prompt:**

```
[[LEO]] dramatically holding up a smartphone like courtroom evidence, the screen glowing with a blurry chat screenshot made only of colored message bars with no readable text, a red camera-flash burst, in the background a sweating friend caught red-handed holding a huge fan of playing cards, gasping crowd, red accent lighting, phone and Leo's face in the center, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-06 · Lor!

- **Arquivo:** `ATK-06` · **Personagem:** Adeir `[[ADEIR]]` · **Cópias:** 6
- **O que a carta faz:** causa 2 de dano e quem jogou compra 1 carta.
- **Piada interna:** ___
- **Cena:** Adeir solta o grito característico. Ondas sonoras vermelhas derrubam o copo de alguém e, no mesmo movimento, ele pega no ar uma carta que voava.
- **Composição:** Adeir de perfil três quartos, boca bem aberta, uma mão esticada pegando a carta.
- **Elementos obrigatórios:** ondas sonoras em anéis, uma carta sendo pega no ar (a compra), energia de bordão.
- **Prompt:**

```
[[ADEIR]] shouting his signature catchphrase with mouth wide open, red concentric cartoon sound-wave rings blasting outward and knocking a friend's cup over, at the same time his other hand snatches a flying playing card out of the air, three-quarter view, energetic pose, red accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### ATK-07 · A Braba

- **Arquivo:** `ATK-07` · **Personagem:** Estefânia `[[ESTEFANIA]]` · **Cópias:** 6
- **O que a carta faz:** causa 4 de dano ao alvo e quem jogou sofre 1 de dano.
- **Piada interna:** ___
- **Cena:** Estefânia solta uma explosão poderosa contra o alvo. O coice chamusca a ponta do cabelo dela e solta um pouco de fumaça da jaqueta (o dano próprio), mas ela continua confiante.
- **Composição:** pose de golpe com o punho para frente, explosão vermelha saindo do punho e fiapos de fumaça nela mesma.
- **Elementos obrigatórios:** explosão grande, cabelo levemente chamuscado, expressão "valeu a pena".
- **Prompt:**

```
[[ESTEFANIA]] throwing a powerful punch that releases a huge red cartoon explosion toward an off-screen target, the recoil slightly singes the tips of her hair with small wisps of smoke rising from her jacket, she still has a confident "totally worth it" smirk, dynamic action pose, red accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Defesa (cor: azul `#2F6FD0`)

#### DEF-01 · It's Not Amazing

- **Arquivo:** `DEF-01` · **Personagem:** Victor `[[VICTOR]]` · **Cópias:** 8
- **O que a carta faz:** reação; anula o dano de 1 ataque.
- **Piada interna:** ___
- **Cena:** Victor, com a cara mais desinteressada do mundo, levanta a mão e um escudo azul translúcido desvia um ataque vermelho que se desfaz em faíscas.
- **Composição:** Victor de frente, com a mão espalmada; o escudo hexagonal na frente dele; o ataque quebrando no escudo.
- **Elementos obrigatórios:** cara de tédio total, escudo azul, ataque se desfazendo.
- **Prompt:**

```
[[VICTOR]] with the most bored, unimpressed deadpan face, casually raising one palm, a translucent blue hexagonal energy shield in front of him effortlessly shattering an incoming red cartoon attack into harmless sparks, calm blue accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### DEF-02 · Inimiga do Banho

- **Arquivo:** `DEF-02` · **Personagem:** Manu `[[MANU]]` · **Cópias:** 6
- **O que a carta faz:** reação; reduz em 3 o dano de um ataque.
- **Piada interna:** ___
- **Cena:** (humor leve, nada nojento) Manu, despreocupada e de moletom largo, tem uma "aura de cheirinho" cartunesca em ondas azul-esverdeadas que freia o ataque: o atacante tampa o nariz e o golpe perde força.
- **Composição:** Manu relaxada no centro; as ondas formam um campo de força; o atacante recuando na lateral.
- **Elementos obrigatórios:** ondas de cheiro estilizadas (como linhas de desenho animado, sem moscas nojentas), atacante tampando o nariz, Manu tranquila.
- **Prompt:**

```
[[MANU]] relaxed and carefree in an oversized sweatshirt, surrounded by a stylized cartoon "funky smell" aura drawn as wavy blue-green lines that act like a force field, an incoming attack slowing down and weakening against it, the attacker on the side pinching their nose comically, lighthearted and not gross, blue accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### DEF-03 · Eu Tava Dormindo

- **Arquivo:** `DEF-03` · **Personagem:** Ana Vi `[[ANA_VI]]` · **Cópias:** 4
- **O que a carta faz:** reação; reduz em 3 o dano de um ataque.
- **Piada interna:** ___
- **Cena:** Ana Vi dorme no sofá com máscara de dormir enquanto a festa acontece. O ataque bate numa almofada gigante e quica, perdendo força.
- **Composição:** Ana Vi deitada na diagonal, a almofada como escudo, luas e estrelas no lugar de "Zzz".
- **Elementos obrigatórios:** máscara de dormir, almofada gigante, símbolos de sono (lua e estrelas, **sem letras Z**).
- **Prompt:**

```
[[ANA_VI]] fast asleep on a couch wearing a sleep mask while a party goes on around her, an incoming red attack bouncing off a giant fluffy pillow and losing power, little crescent moons and stars floating above her head instead of letters, peaceful blue accent lighting, diagonal composition with her face near the center, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### DEF-04 · Reverso do Reverso

- **Arquivo:** `DEF-04` · **Personagem:** Léo `[[LEO]]` · **Cópias:** 4
- **O que a carta faz:** reação; devolve um ataque individual para quem o fez.
- **Piada interna:** ___
- **Cena:** Léo gira e, com um espelho redondo mágico, rebate um raio de ataque de volta para quem o atirou, que arregala os olhos.
- **Composição:** Léo no centro, em giro; setas circulares azuis indicando a volta; o atacante pequeno ao fundo.
- **Elementos obrigatórios:** espelho ou escudo refletor, trajetória que faz a curva e volta, cara de "toma".
- **Prompt:**

```
[[LEO]] spinning with a magical round mirror held like a shield, reflecting an incoming red attack beam that curves around and flies right back at the surprised attacker in the background, swirling blue circular arrows showing the reversal, cheeky "right back at you" grin, blue accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### DEF-05 · Evento Raro

- **Arquivo:** `DEF-05` · **Personagem:** Davi `[[DAVI]]` · **Cópias:** 8
- **O que a carta faz:** reação; anula uma sabotagem (a única defesa contra sabotagens).
- **Piada interna:** ___
- **Cena:** Durante um eclipse e um cometa (o evento raro), Davi fica envolto numa bolha azul brilhante que repele mãos roxas furtivas tentando pegar as cartas dele.
- **Composição:** Davi no centro, olhando para o céu; a bolha ao redor; as mãos roxas batendo de fora.
- **Elementos obrigatórios:** eclipse ou cometa no céu, bolha protetora, mãos ou tentáculos roxos de sabotagem sendo repelidos.
- **Prompt:**

```
[[DAVI]] looking up in awe at a rare sky event, a solar eclipse with a bright comet streaking across, while a glowing blue protective bubble surrounds him and repels sneaky purple cartoon hands trying to steal the playing cards he holds, starry night, blue accent lighting with purple contrast, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### DEF-06 · Último do After

- **Arquivo:** `DEF-06` · **Personagem:** Cadu `[[CADU]]` · **Cópias:** 6
- **O que a carta faz:** reação; reduz em 2 o dano e quem usou compra 1 carta.
- **Piada interna:** ___
- **Cena:** Amanhecendo, Cadu é o último de pé no after: óculos escuros, meio dormindo, bloqueia um ataque com uma caixa de pizza e, com a outra mão, pega uma carta.
- **Composição:** Cadu no centro, luz de amanhecer pela janela; a caixa de pizza como escudo.
- **Elementos obrigatórios:** amanhecer, caixa de pizza escudo, uma carta sendo pega, bagunça de festa acabada ao redor.
- **Prompt:**

```
[[CADU]] as the last person still standing at an after-party at dawn, sunglasses on, half-asleep, blocking an incoming attack with an open pizza box used as a shield while his other hand grabs a playing card, empty cups and party mess around, soft sunrise light through the window mixed with blue accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Sabotagem (cor: magenta/roxo `#A63AA8`)

#### SAB-01 · Anota na Conta da Tuca

- **Arquivo:** `SAB-01` · **Personagem:** Cadu `[[CADU]]` · **Cópias:** 8
- **O que a carta faz:** rouba 1 carta aleatória de um adversário.
- **Piada interna (quem é a Tuca?):** ___
- **Cena:** No balcão de um boteco, Cadu aponta despreocupado para a caderneta de fiado (páginas sem texto legível, só rabiscos) enquanto, com a outra mão, surrupia uma carta do bolso de alguém. A dona do bar, Tuca, aparece em silhueta ao fundo.
- **Composição:** Cadu em primeiro plano, de lado; a mão furtiva em destaque com luz roxa.
- **Elementos obrigatórios:** caderneta de fiado, carta sendo roubada do bolso, balcão de boteco.
- **Prompt:**

```
[[CADU]] leaning on a Brazilian neighborhood bar counter, casually pointing at an old tab notebook filled only with illegible scribbles, while his other hand sneakily slips a playing card out of a distracted friend's back pocket, the bar owner as a silhouette in the background, sneaky purple accent lighting on the stealing hand, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### SAB-02 · Terapia de Boteco

- **Arquivo:** `SAB-02` · **Personagem:** Lara `[[LARA]]` · **Cópias:** 4
- **O que a carta faz:** vê a mão de um adversário e escolhe 1 carta para ele descartar.
- **Piada interna:** ___
- **Cena:** Na mesa de bar, Lara é a "terapeuta": prancheta na mão e óculos de raio-X, enxergando através das cartas viradas do amigo que desabafa, e apontando uma delas para jogar fora.
- **Composição:** Lara de frente com os óculos brilhando em roxo; o amigo de costas segurando cartas que aparecem "transparentes".
- **Elementos obrigatórios:** óculos de raio-X, cartas vistas por dentro, garrafas na mesa, prancheta.
- **Prompt:**

```
[[LARA]] as a bar-table therapist holding a clipboard, wearing glowing purple x-ray glasses that let her see through the face-down playing cards of a venting friend seated across the table, she points at one card to throw away, beer bottles on the table, sneaky purple accent lighting, Lara's face centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### SAB-03 · Tem Alguém Seguindo

- **Arquivo:** `SAB-03` · **Personagem:** Ju Amorim `[[JU_AMORIM]]` · **Cópias:** 6
- **O que a carta faz:** marca um adversário; o próximo ataque contra ele causa +2.
- **Piada interna:** ___
- **Cena:** Ju Amorim espia de trás de um poste com binóculos e um sobretudo de detetive. Sobre a cabeça do alvo, distraído no fundo, flutua uma mira roxa brilhante.
- **Composição:** Ju em primeiro plano, metade escondida atrás do poste; o alvo pequeno ao fundo, com a mira.
- **Elementos obrigatórios:** binóculos, mira ou alvo brilhante sobre a vítima, clima de espionagem.
- **Prompt:**

```
[[JU_AMORIM]] peeking from behind a street lamp post with binoculars, wearing a detective trench coat, sneaky expression, in the background a distracted friend at a party with a glowing purple crosshair target floating above their head, night street with neon, purple accent lighting, Ju's face centered in the foreground, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### SAB-04 · Eu Amo Mentir

- **Arquivo:** `SAB-04` · **Personagem:** Miguel `[[MIGUEL]]` · **Cópias:** 6
- **O que a carta faz:** troca 1 carta sua por 1 carta aleatória do adversário.
- **Piada interna:** ___
- **Cena:** Miguel sorri com uma auréola de anjo, mas cruza os dedos atrás das costas, onde troca uma carta dele por uma de alguém num truque de mágica.
- **Composição:** Miguel de frente, inocente; atrás dele, as duas mãos trocando cartas, com brilho roxo.
- **Elementos obrigatórios:** auréola falsa, dedos cruzados, duas cartas trocando de mão.
- **Prompt:**

```
[[MIGUEL]] smiling innocently with a fake golden halo above his head, while behind his back his fingers are crossed and his hands perform a magic-trick card swap, exchanging his own playing card for one taken from a friend, purple sparkles around the swapping hands, playful sneaky purple accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### SAB-05 · Plano Dental Negado

- **Arquivo:** `SAB-05` · **Personagem:** Luciano `[[LUCIANO]]` · **Cópias:** 4
- **O que a carta faz:** o adversário descarta 2 cartas, à escolha dele.
- **Piada interna:** ___
- **Cena:** Luciano, de dentista, bate um carimbo gigante com um "X" vermelho (sem texto) numa ficha. O paciente na cadeira deixa cair duas cartas da boca, como dentes.
- **Composição:** Luciano em pé com o carimbo erguido; o paciente na cadeira, em perspectiva.
- **Elementos obrigatórios:** carimbo com "X" (sem palavra "negado"), cadeira de dentista, duas cartas caindo.
- **Prompt:**

```
[[LUCIANO]] dressed as a dentist slamming down a giant rubber stamp with a big red X symbol (no words) onto a patient chart, the patient in the dental chair comically dropping two playing cards out of their mouth like lost teeth, bright dental office lamp, purple accent lighting, Luciano centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Caos (cor: laranja `#E8892A`)

#### CAO-01 · Tio Paulo

- **Arquivo:** `CAO-01` · **Personagem:** Tio Paulo `[[TIO_PAULO]]` (personagem do Léo) · **Cópias:** 4
- **O que a carta faz:** cada jogador vivo passa 1 carta para o próximo à direita, todos ao mesmo tempo.
- **Piada interna (quem é o Tio Paulo?):** ___
- **Cena:** Tio Paulo, carismático, comanda a mesa do almoço de família como mestre de cerimônias. Todos passam uma carta para a pessoa da direita ao mesmo tempo, formando uma roda.
- **Composição:** vista de cima, levemente inclinada, de uma mesa redonda; Tio Paulo em destaque no topo da roda; setas laranja em círculo.
- **Elementos obrigatórios:** mesa redonda, todos passando carta para a direita, setas em sentido horário, Tio Paulo regendo.
- **Prompt:**

```
[[TIO_PAULO]] as a charismatic master of ceremonies conducting a family lunch table, everyone around a round table passing one playing card to the person on their right at the same time, glowing orange circular clockwise arrows connecting the hands, slightly top-down tilted view, Tio Paulo prominent at the top of the circle with arms raised, chaotic happy energy, orange accent lighting, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### CAO-02 · Bucetada

- **Arquivo:** `CAO-02` · **Personagem:** Ryane `[[RYANE]]` · **Cópias:** 4
- **O que a carta faz:** cada jogador vivo descarta 1 carta à escolha.
- **Piada interna:** ___
- **Atenção:** o nome é gíria pesada. A arte representa **só o caos cômico**, sem nada sexual.
- **Cena:** Ryane solta uma explosão de bagunça (confete, copos voando, luz laranja) no meio da festa. Todo mundo, de susto, deixa cair uma carta.
- **Composição:** Ryane no centro, braços abertos; um anel de amigos ao redor deixando cartas caírem.
- **Elementos obrigatórios:** explosão de confete laranja, várias cartas caindo (uma de cada pessoa), caras de susto.
- **Prompt:**

```
[[RYANE]] in the middle of a house party throwing her arms open and unleashing a huge comedic orange chaos explosion of confetti, flying cups and streamers, all the friends around her jump in surprise and each one drops a single playing card, cards falling everywhere, lighthearted slapstick, absolutely non-sexual, orange accent lighting, Ryane centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### CAO-03 · Família Basilato

- **Arquivo:** `CAO-03` · **Personagem:** Família Basilato `[[FAMILIA_BASILATO]]` · **Cópias:** 4
- **O que a carta faz:** causa 3 de dano ao adversário com mais PV (não é ataque; dano de caos).
- **Piada interna:** ___
- **Cena:** Retrato de família ameaçador e cômico: todos posam juntos, braços cruzados, e apontam ao mesmo tempo para a pessoa mais "forte" da mesa, que leva uma onda de energia laranja.
- **Composição:** a família em grupo no centro, como pôster de filme; o alvo apenas sugerido na borda da cena.
- **Elementos obrigatórios:** grupo familiar com traço em comum, um brasão de família sem texto ao fundo, todos apontando para o mesmo alvo.
- **Prompt:**

```
[[FAMILIA_BASILATO]] posing together like a dramatic movie poster family portrait, arms crossed, all pointing at the same time toward the strongest person at the table who gets hit by an orange energy wave at the edge of the frame, a golden family crest with no text behind them, menacing but funny, orange accent lighting, group centered, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### CAO-04 · O Acre Existe!

- **Arquivo:** `CAO-04` · **Personagem:** Letícia `[[LETICIA]]` · **Cópias:** 4
- **O que a carta faz:** cada jogador vivo compra 1 carta e depois descarta 1.
- **Piada interna:** ___
- **Cena:** Letícia, vestida de exploradora, finca uma bandeira lisa (sem texto) num mapa enorme de floresta, com o formato do estado do Acre brilhando. Do céu chove uma tempestade de cartas que todo mundo tenta pegar e soltar.
- **Composição:** Letícia em pose triunfal no centro; mapa e floresta ao fundo; cartas caindo de cima.
- **Elementos obrigatórios:** contorno do Acre brilhando no mapa, bandeira sem texto, chuva de cartas.
- **Prompt:**

```
[[LETICIA]] dressed as a jungle explorer triumphantly planting a plain flag with no text on top of a giant glowing map shaped like the Brazilian state of Acre, lush rainforest around, a storm of playing cards raining from the sky while tiny friends try to catch one and toss one away, epic discovery mood, orange accent lighting, Leticia centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Recuperação (cor: verde `#2E9E5B`)

#### REC-01 · After do After

- **Arquivo:** `REC-01` · **Personagem:** Cadu `[[CADU]]` · **Cópias:** 4
- **O que a carta faz:** recupera 4 PV.
- **Piada interna:** ___
- **Cena:** O after do after: Cadu numa rede ao sol da manhã, com água de coco (ou energético), renascendo com uma aura verde de energia e corações de vida subindo.
- **Composição:** Cadu relaxado no centro, raios de sol atrás, brilho verde ao redor.
- **Elementos obrigatórios:** rede, sol nascendo, aura verde de cura, corações subindo.
- **Prompt:**

```
[[CADU]] lying in a hammock in the morning sun at the after-party of the after-party, sipping coconut water, coming back to life with a glowing green healing aura and small green hearts floating upward, sunrays behind him, blissful relieved face, green accent lighting, Cadu centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REC-02 · Inimiga do Fim

- **Arquivo:** `REC-02` · **Personagem:** Anna `[[ANNA]]` · **Cópias:** 3
- **O que a carta faz:** recupera 4 PV.
- **Piada interna:** ___
- **Cena:** As luzes estão sendo apagadas e alguém aponta para a porta, mas Anna se recusa a deixar a festa acabar: dança sozinha sob o globo espelhado e a energia dela volta com brilho verde.
- **Composição:** Anna dançando no centro, um feixe de luz do globo nela; o resto da sala escurecendo.
- **Elementos obrigatórios:** globo espelhado, alguém desligando a luz ao fundo, aura verde e brilho de lantejoula.
- **Prompt:**

```
[[ANNA]] refusing to let the party end, dancing alone under a sparkling disco ball while someone in the background flips the lights off and points at the door, a spotlight from the disco ball on her, her energy recharging with a sparkling green healing glow and floating hearts, rest of the room darkening, green accent lighting, Anna centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REC-03 · Consultório Lucboy

- **Arquivo:** `REC-03` · **Personagem:** Luciano `[[LUCIANO]]` · **Cópias:** 5
- **O que a carta faz:** recupera 3 PV e compra 1 carta.
- **Piada interna (o que é o "Lucboy"?):** ___
- **Cena:** Luciano como médico estiloso num consultório neon, entregando com charme uma poção verde brilhante e uma "receita" que, na verdade, é uma carta de baralho.
- **Composição:** Luciano de frente, estendendo a poção e a carta para a "câmera".
- **Elementos obrigatórios:** jaleco, poção verde, carta como receita, letreiro neon **sem letras** (só uma cruz).
- **Prompt:**

```
[[LUCIANO]] as a stylish cool doctor in a neon-lit clinic with a glowing green cross sign (no letters), confidently handing toward the viewer a bubbling green healing potion and a "prescription" that is actually a playing card, white coat, charming wink, green accent lighting, Luciano centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REC-04 · Anestesia Alcoólica

- **Arquivo:** `REC-04` · **Personagem:** Giovanna `[[GIOVANNA]]` · **Cópias:** 3
- **O que a carta faz:** descarte outra carta como custo; recupera 5 PV.
- **Piada interna:** ___
- **Cena:** Giovanna, com fantasia festiva de enfermeira (nada sensual), aplica a "anestesia": um drinque colorido servido numa taça em forma de seringa. Uma carta voa para o lixo (o custo) e uma onda verde de alívio a envolve.
- **Composição:** Giovanna no centro erguendo a taça-seringa; a carta descartada indo para a lateral.
- **Elementos obrigatórios:** taça-seringa de brinquedo, carta sendo jogada fora, brilho verde de alívio.
- **Prompt:**

```
[[GIOVANNA]] in a playful festive nurse-style party costume (not sexy, fully covered), raising a colorful cocktail served in a giant toy syringe-shaped glass as a funny "anesthesia", a playing card flying off toward a trash bin as a sacrifice, a wave of green relief glow surrounding her, cheerful expression, green accent lighting, Giovanna centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REC-05 · English Mode

- **Arquivo:** `REC-05` · **Personagem:** Letícia `[[LETICIA]]` · **Cópias:** 3
- **O que a carta faz:** recupera 2 PV e compra 2 cartas.
- **Piada interna:** ___
- **Cena:** Letícia ativa o "modo inglês": monóculo, chapéu-coco, xícara de chá com o dedinho levantado, pose chique. Duas cartas flutuam até a mão dela, com um leve brilho verde.
- **Composição:** Letícia de três quartos, elegante; duas cartas flutuando ao lado.
- **Elementos obrigatórios:** xícara de chá, monóculo, duas cartas chegando.
- **Prompt:**

```
[[LETICIA]] switching into a posh "English mode", wearing a monocle and bowler hat, sipping tea from a fancy cup with pinky raised, elegant three-quarter pose, two playing cards floating gracefully into her free hand, soft green healing sparkles, refined background with a hint of rainy window, green accent lighting, Leticia centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Reviravolta (cor: ciano/turquesa `#1F9AAE`)

#### REV-01 · Ressuscitou o Tio Paulo

- **Arquivo:** `REV-01` · **Personagem:** Tio Paulo `[[TIO_PAULO]]` · **Cópias:** 4
- **O que a carta faz:** reação; diante de um golpe fatal, fica com 1 PV.
- **Piada interna:** ___
- **Cena:** Quando todos achavam que era o fim, Tio Paulo se levanta do chão de forma dramática e cômica, com uma luz celestial turquesa vinda de cima e um único coração brilhando sobre ele.
- **Composição:** Tio Paulo levantando no centro, braços para cima; luz em feixe de cima.
- **Elementos obrigatórios:** feixe de luz celestial, um único coração (1 PV), amigos chocados.
- **Prompt:**

```
[[TIO_PAULO]] dramatically rising back up from the floor at a party when everyone thought it was over, arms raised in triumph, a heavenly turquoise light beam shining down on him, one single glowing heart floating above his head, shocked friends jumping back, comic miracle moment, turquoise accent lighting, centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REV-02 · Lucboy & Laragirl

- **Arquivo:** `REV-02` · **Personagens:** Luciano `[[LUCIANO]]` e Lara `[[LARA]]` · **Cópias:** 4
- **O que a carta faz:** troca a mão inteira com um adversário vivo.
- **Piada interna:** ___
- **Cena:** Luciano e Lara como dupla de super-heróis, em pose de capa de quadrinho. Um redemoinho turquesa troca o leque de cartas deles pelo leque de um rival espantado.
- **Composição:** a dupla no centro, lado a lado; o redemoinho entre eles e o rival na lateral.
- **Elementos obrigatórios:** pose de dupla heroica, capas, troca de leques de cartas num redemoinho.
- **Prompt:**

```
[[LUCIANO]] and [[LARA]] as a superhero duo in a comic-book-cover pose side by side, capes flowing, a swirling turquoise vortex between them and a stunned rival on the side, their whole fan of playing cards swapping places with the rival's fan of cards through the vortex, dramatic twist energy, turquoise accent lighting, duo centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### REV-03 · Última Palavra

- **Arquivo:** `REV-03` · **Personagem:** Estefânia `[[ESTEFANIA]]` · **Cópias:** 4
- **O que a carta faz:** reação; ao ser eliminada por alguém, causa 2 de dano nessa pessoa.
- **Piada interna:** ___
- **Cena:** Estefânia cai para trás em câmera lenta, mas ainda aponta o dedo e solta um último raio turquesa certeiro em quem a derrubou. Expressão de "isso não fica assim".
- **Composição:** Estefânia na diagonal, caindo; o braço esticado; o raio atravessando a cena.
- **Elementos obrigatórios:** queda dramática, dedo apontado, raio de retaliação, ar de vingança.
- **Prompt:**

```
[[ESTEFANIA]] falling backward in dramatic slow motion, yet still pointing her finger and firing one last precise turquoise energy blast at the person who knocked her down, "this isn't over" vengeful smirk, motion lines, diagonal dynamic composition with her face near the center, turquoise accent lighting, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, Brazilian friends party vibe, warm night lighting, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Baralho do Além (cor: índigo acinzentado `#5A5590`)

Todas as cartas do Além mostram o personagem **como fantasma**: translúcido, levemente azulado e flutuando com cauda de fumaça. O humor é mórbido e leve (nada assustador de verdade, nada de caveiras realistas).

#### GHO-01 · Victor Voltou Passando Mal

- **Arquivo:** `GHO-01` · **Personagem:** Victor `[[VICTOR]]` (fantasma) · **Cópias:** 5
- **O que a carta faz:** um jogador vivo descarta 1 carta aleatória.
- **Piada interna:** ___
- **Cena:** O fantasma de Victor volta do além enjoado, esverdeado e com a mão na barriga. A simples presença dele faz um amigo vivo derrubar uma carta, assustado.
- **Composição:** o fantasma flutuando no centro; o vivo pequeno embaixo, soltando a carta.
- **Elementos obrigatórios:** fantasma translúcido e enjoado (sem vômito), uma carta caindo da mão de um vivo.
- **Prompt:**

```
the ghost of [[VICTOR]], translucent pale blue-green with a wispy smoke tail, floating and looking very queasy with a hand on his stomach (no vomit), his haunting presence makes a startled living friend below drop a single playing card, misty indigo atmosphere, eerie but funny, indigo accent lighting, ghost centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### GHO-02 · Fantasma Fofoqueiro

- **Arquivo:** `GHO-02` · **Personagem:** Lara `[[LARA]]` (fantasma) · **Cópias:** 5
- **O que a carta faz:** vê até 2 cartas aleatórias de um vivo; só o fantasma vê.
- **Piada interna:** ___
- **Cena:** A fantasma Lara espia por cima do ombro de um vivo distraído, vendo as cartas dele, com o dedo nos lábios pedindo silêncio para a "câmera".
- **Composição:** a fantasma em primeiro plano, de lado; o vivo de costas; duas cartas com leve brilho.
- **Elementos obrigatórios:** dedo nos lábios, espiada por cima do ombro, duas cartas destacadas.
- **Prompt:**

```
the ghost of [[LARA]], translucent pale blue with a wispy smoke tail, sneakily peeking over the shoulder of an oblivious living friend to see their playing cards, two of the cards softly glowing, she holds a finger to her lips toward the viewer as if saying "shh", misty indigo atmosphere, playful and secretive, indigo accent lighting, ghost's face centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### GHO-03 · Mão de Defunto

- **Arquivo:** `GHO-03` · **Personagem:** Davi `[[DAVI]]` (fantasma) · **Cópias:** 4
- **O que a carta faz:** um vivo coloca 1 carta aleatória da mão no fundo do baralho.
- **Piada interna:** ___
- **Cena:** Uma mão fantasma, enorme e cartunesca, do fantasma Davi sai do chão, puxa uma carta da mão de um vivo e a enfia por baixo de um monte de cartas.
- **Composição:** o fantasma Davi ao fundo, sorrindo; a mão gigante em primeiro plano, entre o vivo e o baralho.
- **Elementos obrigatórios:** mão fantasma translúcida (nada de esqueleto realista), monte de cartas, carta indo para baixo do monte.
- **Prompt:**

```
the ghost of [[DAVI]], translucent pale blue with a wispy smoke tail, grinning mischievously in the background while his giant cartoon ghostly hand rises from the floor in the foreground, plucks a playing card from a living friend's hand and slides it under the bottom of a deck of cards, not a realistic skeleton, misty indigo atmosphere, playful spooky mood, indigo accent lighting, centered composition, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### GHO-04 · Maldição da Ressaca

- **Arquivo:** `GHO-04` · **Personagem:** Artur `[[ARTUR]]` (fantasma) · **Cópias:** 4
- **O que a carta faz:** o próximo ataque contra o Mais Odiado causa +1.
- **Piada interna:** ___
- **Cena:** O fantasma Artur lança uma maldição: uma nuvem roxa de ressaca, com garrafas e estrelinhas girando, vai na direção de uma coroa flamejante (o símbolo do "Mais Odiado").
- **Composição:** o fantasma no centro com as mãos para frente; a nuvem e a coroa na lateral.
- **Elementos obrigatórios:** nuvem de ressaca, coroa flamejante como alvo, clima de feitiço.
- **Prompt:**

```
the ghost of [[ARTUR]], translucent pale blue with a wispy smoke tail, casting a hangover curse with both hands, a swirling purple-indigo cloud full of spinning bottles and dizzy stars flying toward a flaming crown that represents the most hated player, witchy spell energy, misty indigo atmosphere, indigo accent lighting, ghost centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

#### GHO-05 · Eu Sei o Que Você Fez

- **Arquivo:** `GHO-05` · **Personagem:** Ju Amorim `[[JU_AMORIM]]` (fantasma) · **Cópias:** 2
- **O que a carta faz:** vê até 2 cartas de um vivo (só ela vê) e escolhe 1 para ele descartar.
- **Piada interna:** ___
- **Cena:** A fantasma Ju Amorim segura uma lupa brilhante que revela, só para ela, duas cartas de um vivo nervoso. Ela aponta uma delas com um sorriso de quem sabe de tudo.
- **Composição:** a fantasma no centro; duas cartas flutuando entre ela e o vivo suando ao fundo.
- **Elementos obrigatórios:** lupa brilhante, duas cartas reveladas, vivo nervoso, sorriso de "eu sei".
- **Prompt:**

```
the ghost of [[JU_AMORIM]], translucent pale blue with a wispy smoke tail, holding a glowing magnifying glass that reveals two playing cards floating out of a nervous sweating living friend's hand, she points at one of the two cards with a knowing "I know what you did" smile, mysterious misty indigo atmosphere, indigo accent lighting, ghost centered, waist-up, vibrant 2D cartoon trading-card illustration, bold clean outlines, flat colors with soft cel shading, exaggerated comic expressions, meme humor, strong readable silhouette, single clear focal point centered, full-bleed artwork, no text
```

### Versos

#### BACK-MAIN · Verso do baralho principal

- **Arquivo:** `BACK-MAIN` · **Tamanho:** 1575 × 2200 px (retrato) · **Margem:** 80 px
- **Uso:** costas de todas as 160 cartas do baralho principal.
- **Ideia:** padrão simétrico de festa sobre um fundo roxo profundo, com um **medalhão vazio no centro** onde o logo será aplicado depois.
- **Elementos obrigatórios:** simetria (a carta pode aparecer de cabeça para baixo), confete, copos, cartinhas e estrelas em padrão; brilhos laranja e magenta; nada de texto nem letra.
- **Prompt:**

```
symmetrical playing card back design, portrait orientation, deep purple background (#6D3FD1 to dark indigo gradient), ornate party-themed pattern with tiny confetti, cocktail glasses, stars and mini playing cards arranged in a mirrored pattern, warm orange and magenta neon glows, an empty circular medallion in the exact center reserved for a future logo, decorative border pattern inset from the edges, rotationally symmetric so it looks the same upside down, flat vector-like cartoon style with bold clean outlines, no text, no letters, no logo
```

#### BACK-GHOST · Verso do Baralho do Além

- **Arquivo:** `BACK-GHOST` · **Tamanho:** 1575 × 2200 px (retrato) · **Margem:** 80 px
- **Uso:** costas das 20 cartas do Além. Precisa ser **muito diferente** do verso principal à primeira vista.
- **Ideia:** névoa índigo, redemoinhos fantasmagóricos, velas e pequenas luzes, com um medalhão central vazio contendo só um fantasminha cartunesco simpático.
- **Elementos obrigatórios:** simetria, névoa, tom índigo acinzentado `#5A5590`, nada de texto.
- **Prompt:**

```
symmetrical playing card back design for a ghost deck, portrait orientation, misty indigo-gray background (#5A5590 fading into deep navy), swirling ghostly wisps and tiny floating candle lights arranged in a mirrored pattern, a central circular medallion containing only a small cute friendly cartoon ghost silhouette, soft pale-blue glow, decorative border inset from the edges, rotationally symmetric so it looks the same upside down, flat vector-like cartoon style with bold clean outlines, spooky but friendly, no text, no letters, no logo
```

---

## 7. Checklist de entrega

Antes de entregar cada imagem:

- [ ] Nenhuma letra, número, logo ou marca d'água em lugar nenhum (inclusive placas, telas e roupas).
- [ ] Sem moldura nem layout de carta: a ilustração preenche a imagem inteira.
- [ ] Rosto ou ação principal dentro do quadrado central de 1024 × 1024 (faces) ou da margem de 80 px (versos).
- [ ] Ainda é legível reduzida a **96 px de largura**: dá para entender quem é e o que está acontecendo.
- [ ] Cor de destaque da categoria presente.
- [ ] O personagem tem o mesmo visual das outras cartas em que aparece (compare com a folha de personagens).
- [ ] Personagem real só com autorização registrada; sem ela, foi usada a descrição genérica.
- [ ] Nada de nudez, conteúdo sexual, sangue ou ofensa.
- [ ] Arquivos com o nome do código: `PNG` mestre + `WebP` + miniatura `_thumb.webp`.
- [ ] Os versos são simétricos e têm o medalhão central vazio.

### Resumo das 37 imagens

|   # | Arquivo    | Nome                       | Personagem       | Categoria   |
| --: | ---------- | -------------------------- | ---------------- | ----------- |
|   1 | ATK-01     | Falou Merda                | Ryane            | Ataque      |
|   2 | ATK-02     | Não Vou Levar Numa Boa     | Ana Vi           | Ataque      |
|   3 | ATK-03     | Peneira Suprema            | Artur            | Ataque      |
|   4 | ATK-04     | Fofoca Mortal              | Lara             | Ataque      |
|   5 | ATK-05     | Print Comprometedor        | Léo              | Ataque      |
|   6 | ATK-06     | Lor!                       | Adeir            | Ataque      |
|   7 | ATK-07     | A Braba                    | Estefânia        | Ataque      |
|   8 | DEF-01     | It's Not Amazing           | Victor           | Defesa      |
|   9 | DEF-02     | Inimiga do Banho           | Manu             | Defesa      |
|  10 | DEF-03     | Eu Tava Dormindo           | Ana Vi           | Defesa      |
|  11 | DEF-04     | Reverso do Reverso         | Léo              | Defesa      |
|  12 | DEF-05     | Evento Raro                | Davi             | Defesa      |
|  13 | DEF-06     | Último do After            | Cadu             | Defesa      |
|  14 | SAB-01     | Anota na Conta da Tuca     | Cadu             | Sabotagem   |
|  15 | SAB-02     | Terapia de Boteco          | Lara             | Sabotagem   |
|  16 | SAB-03     | Tem Alguém Seguindo        | Ju Amorim        | Sabotagem   |
|  17 | SAB-04     | Eu Amo Mentir              | Miguel           | Sabotagem   |
|  18 | SAB-05     | Plano Dental Negado        | Luciano          | Sabotagem   |
|  19 | CAO-01     | Tio Paulo                  | Tio Paulo (Léo)  | Caos        |
|  20 | CAO-02     | Bucetada                   | Ryane            | Caos        |
|  21 | CAO-03     | Família Basilato           | Família Basilato | Caos        |
|  22 | CAO-04     | O Acre Existe!             | Letícia          | Caos        |
|  23 | REC-01     | After do After             | Cadu             | Recuperação |
|  24 | REC-02     | Inimiga do Fim             | Anna             | Recuperação |
|  25 | REC-03     | Consultório Lucboy         | Luciano          | Recuperação |
|  26 | REC-04     | Anestesia Alcoólica        | Giovanna         | Recuperação |
|  27 | REC-05     | English Mode               | Letícia          | Recuperação |
|  28 | REV-01     | Ressuscitou o Tio Paulo    | Tio Paulo (Léo)  | Reviravolta |
|  29 | REV-02     | Lucboy & Laragirl          | Luciano e Lara   | Reviravolta |
|  30 | REV-03     | Última Palavra             | Estefânia        | Reviravolta |
|  31 | GHO-01     | Victor Voltou Passando Mal | Victor           | Além        |
|  32 | GHO-02     | Fantasma Fofoqueiro        | Lara             | Além        |
|  33 | GHO-03     | Mão de Defunto             | Davi             | Além        |
|  34 | GHO-04     | Maldição da Ressaca        | Artur            | Além        |
|  35 | GHO-05     | Eu Sei o Que Você Fez      | Ju Amorim        | Além        |
|  36 | BACK-MAIN  | Verso do baralho principal | —                | Verso       |
|  37 | BACK-GHOST | Verso do Baralho do Além   | —                | Verso       |
