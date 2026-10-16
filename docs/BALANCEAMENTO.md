# Balanceamento — simulações automatizadas

Gerado por `pnpm sim` em 2026-10-16: 60 partidas com o motor de regras real (as mesmas RPCs do app), semente 2026.

**Como os robôs jogam:** em cada turno, 85% de chance de jogar uma carta jogável (alvos escolhidos como na tela); reagem com 70% de chance quando têm defesa; fantasmas com 3 fichas ressuscitam com 85% de chance; descartam ao acaso. É um jogador "médio e distraído", não um estrategista: serve para medir ritmo e achar travamentos, não para decidir se uma carta é forte.

**Integridade:** depois de cada jogada, `admin_check_game_integrity` confere as 180 cartas, mãos, vida, fichas, fase e jogada pendente.

| Jogadores | Partidas | Rodadas (média) | Turnos | Jogadas | Cartas jogadas | Reações | Mortes | Mortes por Ressaca | Ressurreições | Fim por PV (rodada 10) | Último vivo | Todos caíram | Duração |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 3 | 10 | 9.7 | 29 | 104 | 38 | 7.6 | 2.8 | 1.3 | 1.2 | 70% | 20% | 10% | 5.1s |
| 4 | 10 | 9.9 | 39 | 149 | 53 | 12.3 | 4.1 | 2.2 | 1.6 | 80% | 20% | 0% | 7.1s |
| 5 | 10 | 9.9 | 50 | 196 | 67 | 16.3 | 5.2 | 3.0 | 1.8 | 90% | 10% | 0% | 9.5s |
| 6 | 10 | 10.0 | 60 | 241 | 80 | 16.8 | 6.8 | 3.8 | 2.3 | 90% | 10% | 0% | 11.8s |
| 7 | 10 | 10.0 | 70 | 281 | 92 | 20.2 | 7.9 | 3.7 | 3.0 | 100% | 0% | 0% | 14.0s |
| 8 | 10 | 10.0 | 78 | 318 | 103 | 19.8 | 9.9 | 4.3 | 3.6 | 50% | 50% | 0% | 15.8s |

Partidas com problema: 0 de 60.
Jogadas recusadas pelo servidor: nenhuma.

**Abandono:** os robôs não abandonam; remoção por ausência é coberta pelos testes e2e (endgame.spec.ts).
