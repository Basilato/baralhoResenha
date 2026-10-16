import type { GameEvent } from './game-service'

/**
 * Zoeira do histórico: um comentário curto depois do texto factual.
 *
 * Regras:
 * - Só usa o que o evento público já traz (nomes, números, carta jogada).
 *   Nunca cita carta escondida: quem espia ou rouba não revela nada aqui.
 * - A frase sai do número do evento (seq), então todo mundo na mesa vê a
 *   mesma, e recarregar a página não troca.
 * - Eventos repetitivos (compra, "aceitou", "escolheu") ficam sem comentário.
 */

type Ctx = { actor: string; target: string; amount: number }
type Line = string | ((ctx: Ctx) => string)

const CARD_QUIPS: Record<string, Line[]> = {
  'ATK-01': ['Agora já foi, não tem como desdizer.', 'O silêncio que veio depois disse tudo.'],
  'ATK-02': ['Levou para o pessoal. E levou bem.', 'Alguém não deixou passar.'],
  'ATK-03': ['A peneira não perdoa ninguém.', 'Passou o pente fino e sobrou pouca coisa.'],
  'ATK-04': ['Fofoca boa se espalha rápido.', 'Ninguém sabe quem contou, mas todo mundo ouviu.'],
  'ATK-05': ['O print não mente.', 'Tinha print. Sempre tem print.'],
  'ATK-06': ['LOR!', 'Foi tão alto que o vizinho reclamou.'],
  'ATK-07': ['A Braba chegou e a mesa ficou em silêncio.', 'Bate, mas também se machuca.'],
  'DEF-01': ["It's not amazing. Mesmo.", 'Bateu e voltou. Nada aconteceu.'],
  'DEF-02': ['O cheiro afastou o ataque.', 'Ninguém quis chegar perto.'],
  'DEF-03': ['Estava dormindo. Desculpa perfeita.', 'Não ouviu nada, não viu nada.'],
  'DEF-04': ['Reverso do reverso: voltou para quem mandou.'],
  'DEF-05': ['Raro mesmo. Quase ninguém viu.'],
  'DEF-06': ['O último do after sempre aguenta mais um.'],
  'REV-01': ['Ressuscitou antes de cair. Coisa de Tio Paulo.'],
  'REV-03': ['Saiu, mas não sem levar alguém junto.'],
  'GHO-01': ['Voltou passando mal e ainda quis atrapalhar.'],
  'GHO-02': ['Fantasma também gosta de saber da vida alheia.'],
  'GHO-03': ['Uma mão gelada mexeu nas cartas de alguém.'],
  'GHO-04': ['A ressaca do Além está mirando o Mais Odiado.'],
  'GHO-05': ['O Além sabe de tudo. Melhor não perguntar como.'],
  'SAB-01': ['Pode pendurar na conta, a Tuca paga.'],
  'SAB-02': ['Terapia de boteco: rápida, barata e sem sigilo.'],
  'SAB-03': ['Tem alguém seguindo. Olha pra trás.', 'O alvo agora tem um alvo nas costas.'],
  'SAB-04': ['Mentiu com convicção.', 'Troca justa? Jamais.'],
  'SAB-05': ['O plano dental foi negado. O sorriso também.'],
  'CAO-01': ['Tio Paulo mandou girar. A mesa obedeceu.'],
  'CAO-02': ['Ninguém saiu ileso dessa.'],
  'CAO-03': ['A Família Basilato chegou e procurou quem estava bem demais.'],
  'CAO-04': ['O Acre existe, e agora todo mundo sabe.'],
  'REC-01': ['O after do after: onde a esperança se recupera.'],
  'REC-02': ['Inimiga do fim, amiga da vida.'],
  'REC-03': ['Consulta rápida, alta imediata.'],
  'REC-04': ['Anestesia de procedência duvidosa, mas funcionou.'],
  'REC-05': ['The book is on the table.', 'Recuperou o fôlego e o inglês.'],
  'REV-02': ['Trocaram tudo. Inclusive a dignidade.', 'Mão nova, problemas novos.'],
}

const EVENT_QUIPS: Record<string, Line[]> = {
  game_started: ['Que comece a resenha.', 'Ninguém aqui é amigo durante a partida.'],
  round_started: ['Mais uma volta na mesa.', 'A resenha continua.'],
  damage_dealt: [
    'Doeu no ego.',
    ({ target }) => `${target} sentiu essa.`,
    'Essa vai pro grupo.',
    'Ninguém viu nada. Todo mundo viu tudo.',
  ],
  big_damage: ['Que pancada!', ({ target }) => `${target} vai lembrar dessa amanhã.`],
  survived: ['Por um fio. Literalmente.', 'Ainda não foi dessa vez.'],
  no_damage: ['Passou de raspão.', 'Nem fez cócegas.'],
  self_damage: ['Fogo amigo é fogo também.', 'Às vezes o problema é você.'],
  last_word: ['Saiu, mas deixou recado.', 'A última palavra é sempre a mais cara.'],
  player_died: [
    'Virou lenda. Ou fantasma, no caso.',
    ({ actor }) => `Descanse em paz, ${actor}. Por enquanto.`,
    'Caiu, mas a resenha continua.',
  ],
  player_revived: ['Voltou do Além com fome de vingança.', 'Ninguém fica morto nessa mesa.'],
  revive_declined: ['Gostou do Além, pelo jeito.', 'A vida de fantasma tem as suas vantagens.'],
  healed: ['Hidratou e voltou.', 'Um copo d’água e tudo se resolve.', 'Recuperado para a próxima.'],
  reaction_played: ['Tinha resposta guardada.', 'Não foi dessa vez.', 'Defesa de respeito.'],
  sabotage_blocked: ['Evento raro mesmo.', 'Sabotagem desarmada.'],
  card_stolen: ['Ninguém viu a mão entrando.', 'Mão leve, consciência mais leve ainda.'],
  card_swapped: ['Troca suspeita.'],
  target_marked: ['Agora tem alvo nas costas.'],
  hands_swapped: ['Cada um que se vire com o que recebeu.'],
  ghost_peeked: ['O Além viu. Só o Além sabe.', 'Um arrepio passou pela mesa.'],
  card_to_bottom: ['Foi para o fundo, junto com a esperança.'],
  curse_cast: ['A ressaca vem aí, e vem cobrar.'],
  hangover: ['A conta da noite chegou para todo mundo.', 'Ninguém escapa da ressaca.'],
  cards_passed: ['Girou a roda da resenha.'],
  player_removed: ['Sumiu sem avisar. Clássico.'],
  game_finished: ['Fim de resenha. Amanhã ninguém lembra de nada.', 'GG. Ou quase.'],
}

/** Comentário do evento (ou null quando não cabe zoeira). */
export function eventQuip(event: GameEvent, name: (playerId: unknown) => string): string | null {
  const p = event.payload
  let key: string = event.kind
  let ctx: Ctx = { actor: name(event.actorPlayerId), target: '', amount: 0 }

  // Carta jogada ou usada como reação: a frase é da própria carta.
  if (event.kind === 'card_played' || event.kind === 'reaction_played') {
    const lines = typeof p.cardCode === 'string' ? CARD_QUIPS[p.cardCode] : undefined
    if (lines) return render(pick(lines, event.seq), ctx)
    if (event.kind === 'card_played') return null
  }

  if (event.kind === 'damage_dealt') {
    const results = Array.isArray(p.results)
      ? (p.results as { playerId: string; damage: number; survived: boolean }[])
      : []
    const worst = results.reduce<(typeof results)[number] | undefined>(
      (best, result) => (!best || result.damage > best.damage ? result : best),
      undefined,
    )
    if (!worst) return null
    ctx = { ...ctx, target: name(worst.playerId), amount: worst.damage }
    if (results.some((result) => result.survived)) key = 'survived'
    else if (worst.damage === 0) key = 'no_damage'
    else if (worst.damage >= 4) key = 'big_damage'
  }

  const lines = EVENT_QUIPS[key]
  return lines ? render(pick(lines, event.seq), ctx) : null
}

function pick<T>(lines: T[], seq: number): T {
  return lines[Math.abs(seq) % lines.length]!
}

function render(line: Line, ctx: Ctx) {
  return typeof line === 'string' ? line : line(ctx)
}
