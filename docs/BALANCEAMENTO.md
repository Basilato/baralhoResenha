# Balanceamento — simulações automatizadas

Gerado por `pnpm sim` em 2026-10-16: 60 partidas com o motor de regras real (as mesmas RPCs do app), semente 2026.

**Como os robôs jogam:** em cada turno, 85% de chance de jogar uma carta jogável (alvos escolhidos como na tela); reagem com 70% de chance quando têm defesa; fantasmas com 3 fichas ressuscitam com 85% de chance; descartam ao acaso. É um jogador "médio e distraído", não um estrategista: serve para medir ritmo e achar travamentos, não para decidir se uma carta é forte.

**Integridade:** depois de cada jogada, `admin_check_game_integrity` confere as 180 cartas, mãos, vida, fichas, fase e jogada pendente.

| Jogadores | Partidas | Rodadas (média) | Turnos | Jogadas | Cartas jogadas | Reações | Mortes | Mortes por Ressaca | Ressurreições | Fim por PV (rodada 10) | Último vivo | Todos caíram | Duração |
| --------- | -------- | --------------- | ------ | ------- | -------------- | ------- | ------ | ------------------ | ------------- | ---------------------- | ----------- | ------------ | ------- |
| 3         | 10       | 9.8             | 29     | 105     | 38             | 8.0     | 3.6    | 1.8                | 1.7           | 60%                    | 40%         | 0%           | 3.7s    |
| 4         | 10       | 9.8             | 39     | 160     | 54             | 12.6    | 3.4    | 1.8                | 0.9           | 50%                    | 40%         | 10%          | 6.0s    |
| 5         | 10       | 9.7             | 49     | 195     | 66             | 15.0    | 4.6    | 3.2                | 0.8           | 70%                    | 30%         | 0%           | 8.4s    |
| 6         | 10       | 9.9             | 58     | 234     | 78             | 15.3    | 6.8    | 3.2                | 2.4           | 60%                    | 40%         | 0%           | 10.5s   |
| 7         | 10       | 10.0            | 70     | 281     | 91             | 17.7    | 8.6    | 4.8                | 3.2           | 80%                    | 20%         | 0%           | 11.9s   |
| 8         | 10       | 10.0            | 80     | 338     | 106            | 21.0    | 8.1    | 4.3                | 2.4           | 100%                   | 0%          | 0%           | 12.9s   |

Partidas com problema: 0 de 60.
Jogadas recusadas pelo servidor: NO_VALID_TARGET ×18.

**Abandono:** os robôs não abandonam; remoção por ausência é coberta pelos testes e2e (endgame.spec.ts).
