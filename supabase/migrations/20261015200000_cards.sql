-- =============================================================================
-- Fase 4: catálogo de cartas, baralhos por partida e leitura segura da mesa
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Catálogo (versionado e imutável por versão)
-- -----------------------------------------------------------------------------
-- Mudou um efeito? Crie uma nova set_version em vez de editar a existente:
-- partidas iniciadas continuam apontando para a versão com que começaram.
-- effect_code/effect_params alimentam handlers explícitos no banco (Fases 5–7);
-- nunca são código executável.

create table app_private.card_definitions (
  set_version text not null,
  code text not null check (code ~ '^(ATK|DEF|SAB|CAO|REC|REV|GHO)-[0-9]{2}$'),
  name text not null check (char_length(name) between 1 and 60),
  character_name text,
  category text not null
    check (category in ('attack', 'defense', 'sabotage', 'chaos', 'recovery', 'reversal', 'ghost')),
  deck_type text not null check (deck_type in ('main', 'ghost')),
  copies smallint not null check (copies between 1 and 20),
  effect_code text not null check (effect_code ~ '^[a-z_]+$'),
  effect_params jsonb not null default '{}'::jsonb,
  target_rule text not null check (target_rule in (
    'opponent', 'up_to_two_opponents', 'opponent_most_cards', 'opponent_highest_hp',
    'self', 'all_alive', 'alive_player',
    'attack_reaction', 'sabotage_reaction', 'fatal_reaction'
  )),
  is_reaction boolean not null default false,
  rules_text text not null check (char_length(rules_text) between 1 and 300),
  image_path text,
  -- Efeito ainda em validação com o grupo (ex.: GHO-05).
  is_provisional boolean not null default false,
  enabled boolean not null default true,
  primary key (set_version, code),
  check ((category = 'ghost') = (deck_type = 'ghost'))
);

alter table app_private.card_definitions enable row level security;
revoke all on table app_private.card_definitions from public, anon, authenticated;

insert into app_private.card_definitions
  (set_version, code, category, deck_type, name, character_name, copies,
   effect_code, effect_params, target_rule, is_reaction, rules_text, is_provisional)
values
  -- Ataque (50)
  ('7.1', 'ATK-01', 'attack', 'main', 'Falou Merda', 'Ryane', 10,
   'damage', '{"amount": 3}', 'opponent', false,
   'Causa 3 de dano a um adversário.', false),
  ('7.1', 'ATK-02', 'attack', 'main', 'Não Vou Levar Numa Boa', 'Ana Vi', 6,
   'damage', '{"amount": 3}', 'opponent', false,
   'Causa 3 de dano a um adversário.', false),
  ('7.1', 'ATK-03', 'attack', 'main', 'Peneira Suprema', 'Artur', 8,
   'damage', '{"amount": 5, "discard_cost": 1}', 'opponent', false,
   'Descarte outra carta como custo. Causa 5 de dano a um adversário.', false),
  ('7.1', 'ATK-04', 'attack', 'main', 'Fofoca Mortal', 'Lara', 8,
   'damage_split', '{"amount": 2, "max_targets": 2}', 'up_to_two_opponents', false,
   'Causa 2 de dano a até 2 adversários diferentes.', false),
  ('7.1', 'ATK-05', 'attack', 'main', 'Print Comprometedor', 'Léo', 6,
   'damage', '{"amount": 4}', 'opponent_most_cards', false,
   'Causa 4 de dano ao adversário com mais cartas na mão.', false),
  ('7.1', 'ATK-06', 'attack', 'main', 'Lor!', 'Adeir', 6,
   'damage_draw', '{"amount": 2, "draw": 1}', 'opponent', false,
   'Causa 2 de dano a um adversário e você compra 1 carta.', false),
  ('7.1', 'ATK-07', 'attack', 'main', 'A Braba', 'Estefânia', 6,
   'damage_self', '{"amount": 4, "self_damage": 1}', 'opponent', false,
   'Causa 4 de dano a um adversário. Você sofre 1 de dano.', false),
  -- Defesa (36)
  ('7.1', 'DEF-01', 'defense', 'main', 'It''s Not Amazing', 'Victor', 8,
   'block_attack', '{}', 'attack_reaction', true,
   'Reação: anula o dano de 1 ataque contra você.', false),
  ('7.1', 'DEF-02', 'defense', 'main', 'Inimiga do Banho', 'Manu', 6,
   'reduce_attack', '{"amount": 3}', 'attack_reaction', true,
   'Reação: reduz em 3 o dano de 1 ataque contra você.', false),
  ('7.1', 'DEF-03', 'defense', 'main', 'Eu Tava Dormindo', 'Ana Vi', 4,
   'reduce_attack', '{"amount": 3}', 'attack_reaction', true,
   'Reação: reduz em 3 o dano de 1 ataque contra você.', false),
  ('7.1', 'DEF-04', 'defense', 'main', 'Reverso do Reverso', 'Léo', 4,
   'redirect_attack', '{}', 'attack_reaction', true,
   'Reação: devolve um ataque individual para quem o fez.', false),
  ('7.1', 'DEF-05', 'defense', 'main', 'Evento Raro', 'Davi', 8,
   'block_sabotage', '{}', 'sabotage_reaction', true,
   'Reação: anula uma sabotagem direcionada a você.', false),
  ('7.1', 'DEF-06', 'defense', 'main', 'Último do After', 'Cadu', 6,
   'reduce_attack_draw', '{"amount": 2, "draw": 1}', 'attack_reaction', true,
   'Reação: reduz em 2 o dano de 1 ataque e você compra 1 carta.', false),
  -- Sabotagem (28)
  ('7.1', 'SAB-01', 'sabotage', 'main', 'Anota na Conta da Tuca', 'Cadu', 8,
   'steal_random', '{"count": 1}', 'opponent', false,
   'Roube 1 carta aleatória da mão de um adversário.', false),
  ('7.1', 'SAB-02', 'sabotage', 'main', 'Terapia de Boteco', 'Lara', 4,
   'inspect_discard', '{"count": 1}', 'opponent', false,
   'Veja a mão de um adversário e escolha 1 carta para ele descartar.', false),
  ('7.1', 'SAB-03', 'sabotage', 'main', 'Tem Alguém Seguindo', 'Ju Amorim', 6,
   'mark_target', '{"bonus": 2}', 'opponent', false,
   'Marque um adversário: o próximo ataque contra ele causa +2 de dano.', false),
  ('7.1', 'SAB-04', 'sabotage', 'main', 'Eu Amo Mentir', 'Miguel', 6,
   'swap_card', '{}', 'opponent', false,
   'Troque 1 carta sua por 1 carta aleatória da mão de um adversário.', false),
  ('7.1', 'SAB-05', 'sabotage', 'main', 'Plano Dental Negado', 'Luciano', 4,
   'force_discard', '{"count": 2}', 'opponent', false,
   'Um adversário descarta 2 cartas, à escolha dele.', false),
  -- Caos (16)
  ('7.1', 'CAO-01', 'chaos', 'main', 'Tio Paulo', 'Léo', 4,
   'pass_right', '{"count": 1}', 'all_alive', false,
   'Cada jogador vivo passa 1 carta para o próximo vivo à direita.', false),
  ('7.1', 'CAO-02', 'chaos', 'main', 'Bucetada', 'Ryane', 4,
   'all_discard', '{"count": 1}', 'all_alive', false,
   'Cada jogador vivo descarta 1 carta à escolha.', false),
  ('7.1', 'CAO-03', 'chaos', 'main', 'Família Basilato', 'Família Basilato', 4,
   'chaos_damage', '{"amount": 3}', 'opponent_highest_hp', false,
   'Causa 3 de dano ao adversário vivo com mais PV. Não é ataque.', false),
  ('7.1', 'CAO-04', 'chaos', 'main', 'O Acre Existe!', 'Letícia', 4,
   'all_draw_discard', '{"draw": 1, "discard": 1}', 'all_alive', false,
   'Cada jogador vivo compra 1 carta e depois descarta 1.', false),
  -- Recuperação (18)
  ('7.1', 'REC-01', 'recovery', 'main', 'After do After', 'Cadu', 4,
   'heal', '{"amount": 4}', 'self', false,
   'Recupere 4 PV.', false),
  ('7.1', 'REC-02', 'recovery', 'main', 'Inimiga do Fim', 'Anna', 3,
   'heal', '{"amount": 4}', 'self', false,
   'Recupere 4 PV.', false),
  ('7.1', 'REC-03', 'recovery', 'main', 'Consultório Lucboy', 'Luciano', 5,
   'heal_draw', '{"amount": 3, "draw": 1}', 'self', false,
   'Recupere 3 PV e compre 1 carta.', false),
  ('7.1', 'REC-04', 'recovery', 'main', 'Anestesia Alcoólica', 'Giovanna', 3,
   'heal', '{"amount": 5, "discard_cost": 1}', 'self', false,
   'Descarte outra carta como custo. Recupere 5 PV.', false),
  ('7.1', 'REC-05', 'recovery', 'main', 'English Mode', 'Letícia', 3,
   'heal_draw', '{"amount": 2, "draw": 2}', 'self', false,
   'Recupere 2 PV e compre 2 cartas.', false),
  -- Reviravolta (12)
  ('7.1', 'REV-01', 'reversal', 'main', 'Ressuscitou o Tio Paulo', 'Léo', 4,
   'survive_fatal', '{"hp": 1}', 'fatal_reaction', true,
   'Reação: ao sofrer dano fatal de uma carta, fique com 1 PV.', false),
  ('7.1', 'REV-02', 'reversal', 'main', 'Lucboy & Laragirl', 'Luciano/Lara', 4,
   'swap_hands', '{}', 'opponent', false,
   'Troque a sua mão inteira com a de um adversário vivo.', false),
  ('7.1', 'REV-03', 'reversal', 'main', 'Última Palavra', 'Estefânia', 4,
   'last_word', '{"amount": 2}', 'fatal_reaction', true,
   'Reação: ao ser eliminado por outro jogador, cause 2 de dano nele.', false),
  -- Além (20)
  ('7.1', 'GHO-01', 'ghost', 'ghost', 'Victor Voltou Passando Mal', 'Victor', 5,
   'ghost_random_discard', '{"count": 1}', 'alive_player', false,
   'Um jogador vivo descarta 1 carta aleatória.', false),
  ('7.1', 'GHO-02', 'ghost', 'ghost', 'Fantasma Fofoqueiro', 'Lara', 5,
   'ghost_peek', '{"count": 2}', 'alive_player', false,
   'Veja até 2 cartas aleatórias da mão de um vivo. Só você vê.', false),
  ('7.1', 'GHO-03', 'ghost', 'ghost', 'Mão de Defunto', 'Davi', 4,
   'ghost_bottom_deck', '{"count": 1}', 'alive_player', false,
   'Um vivo coloca 1 carta aleatória da mão no fundo do baralho principal.', false),
  ('7.1', 'GHO-04', 'ghost', 'ghost', 'Maldição da Ressaca', 'Artur', 4,
   'ghost_curse', '{"bonus": 1}', 'self', false,
   'O próximo ataque contra o Mais Odiado causa +1 de dano.', false),
  ('7.1', 'GHO-05', 'ghost', 'ghost', 'Eu Sei o Que Você Fez', 'Ju Amorim', 2,
   'ghost_expose_discard', '{"reveal": 2, "discard": 1}', 'alive_player', false,
   'Revele a todos 2 cartas aleatórias da mão de um vivo. Escolha 1 delas para ele descartar.',
   true);

-- -----------------------------------------------------------------------------
-- Estado do jogador na partida
-- -----------------------------------------------------------------------------

alter table app_private.game_players
  add column life_status text not null default 'alive'
    check (life_status in ('alive', 'ghost')),
  add column hp smallint not null default 0 check (hp >= 0),
  add column max_hp smallint not null default 0 check (max_hp >= 0),
  add column ghost_tokens smallint not null default 0 check (ghost_tokens >= 0),
  add column revival_used boolean not null default false,
  add column knockouts smallint not null default 0 check (knockouts >= 0),
  add constraint game_players_hp_max check (hp <= max_hp);

alter table app_private.games
  add column card_set_version text not null default '7.1';

-- -----------------------------------------------------------------------------
-- Cartas da partida: uma linha por cópia física virtual
-- -----------------------------------------------------------------------------
-- Pilhas (deck/descarte): dono nulo, topo = maior pile_position.
-- Mãos: dono obrigatório, pile_position = ordem de chegada (exibição estável).

create table app_private.game_cards (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references app_private.games (id) on delete cascade,
  set_version text not null,
  card_code text not null,
  deck_type text not null check (deck_type in ('main', 'ghost')),
  zone text not null check (zone in (
    'main_deck', 'main_discard', 'player_hand',
    'ghost_deck', 'ghost_discard', 'ghost_hand',
    'in_resolution'
  )),
  owner_player_id uuid references app_private.game_players (id),
  pile_position integer not null,
  foreign key (set_version, card_code)
    references app_private.card_definitions (set_version, code),
  -- Carta em mão tem dono; carta em pilha não.
  check ((zone in ('player_hand', 'ghost_hand')) = (owner_player_id is not null)
         or zone = 'in_resolution'),
  -- Baralho principal e Além nunca se misturam.
  check (
    (deck_type = 'main' and zone in ('main_deck', 'main_discard', 'player_hand', 'in_resolution'))
    or (deck_type = 'ghost' and zone in ('ghost_deck', 'ghost_discard', 'ghost_hand', 'in_resolution'))
  )
);

create unique index game_cards_pile_position_key
  on app_private.game_cards (game_id, zone, pile_position)
  where owner_player_id is null;

create unique index game_cards_hand_position_key
  on app_private.game_cards (game_id, owner_player_id, zone, pile_position)
  where owner_player_id is not null;

create index game_cards_owner_idx on app_private.game_cards (owner_player_id, zone);

alter table app_private.game_cards enable row level security;
revoke all on table app_private.game_cards from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Primitivas de cartas (internas; sem grant para o navegador)
-- -----------------------------------------------------------------------------

create function app_private.pile_zone(p_deck_type text, p_kind text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_kind = 'deck' then p_deck_type || '_deck'
    when p_kind = 'discard' then p_deck_type || '_discard'
    when p_kind = 'hand' then case p_deck_type when 'main' then 'player_hand' else 'ghost_hand' end
  end;
$$;

-- Embaralha a pilha de descarte de volta no baralho (só quando ele está vazio).
create function app_private.recycle_discard(p_game_id uuid, p_deck_type text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deck text := app_private.pile_zone(p_deck_type, 'deck');
  v_discard text := app_private.pile_zone(p_deck_type, 'discard');
  v_moved integer;
begin
  if exists (select 1 from app_private.game_cards where game_id = p_game_id and zone = v_deck) then
    return 0;
  end if;

  -- gen_random_uuid() usa o gerador forte do Postgres: ordem imprevisível.
  update app_private.game_cards c
  set zone = v_deck, pile_position = s.position
  from (
    select id, row_number() over (order by gen_random_uuid()) as position
    from app_private.game_cards
    where game_id = p_game_id and zone = v_discard
  ) s
  where c.id = s.id;

  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

-- Compra do topo; com o baralho vazio, recicla o descarte. Sem cartas
-- suficientes, compra só o que existir. Devolve quantas comprou.
create function app_private.draw_cards(
  p_game_id uuid,
  p_player_id uuid,
  p_deck_type text,
  p_count integer
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deck text := app_private.pile_zone(p_deck_type, 'deck');
  v_hand text := app_private.pile_zone(p_deck_type, 'hand');
  v_card uuid;
  v_next integer;
  v_drawn integer := 0;
begin
  for i in 1..greatest(coalesce(p_count, 0), 0) loop
    select id into v_card
    from app_private.game_cards
    where game_id = p_game_id and zone = v_deck
    order by pile_position desc
    limit 1;

    if v_card is null then
      perform app_private.recycle_discard(p_game_id, p_deck_type);
      select id into v_card
      from app_private.game_cards
      where game_id = p_game_id and zone = v_deck
      order by pile_position desc
      limit 1;
      exit when v_card is null;
    end if;

    select coalesce(max(pile_position), 0) + 1 into v_next
    from app_private.game_cards
    where owner_player_id = p_player_id and zone = v_hand;

    update app_private.game_cards
    set zone = v_hand, owner_player_id = p_player_id, pile_position = v_next
    where id = v_card;

    v_drawn := v_drawn + 1;
  end loop;

  return v_drawn;
end;
$$;

-- Move cartas da mão do jogador para o descarte correspondente, na ordem dada
-- (a última fica no topo). Todas precisam estar na mão dele.
create function app_private.discard_cards(p_game_id uuid, p_player_id uuid, p_card_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := coalesce(cardinality(p_card_ids), 0);
  v_card app_private.game_cards;
  v_next integer;
begin
  if v_count = 0 then
    return 0;
  end if;

  if (select count(distinct x) from unnest(p_card_ids) as x) <> v_count
    or (
      select count(*) from app_private.game_cards
      where id = any (p_card_ids)
        and game_id = p_game_id
        and owner_player_id = p_player_id
        and zone in ('player_hand', 'ghost_hand')
    ) <> v_count then
    perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
  end if;

  for v_card in
    select c.*
    from unnest(p_card_ids) with ordinality as x (id, ord)
    join app_private.game_cards c on c.id = x.id
    order by x.ord
  loop
    select coalesce(max(pile_position), 0) + 1 into v_next
    from app_private.game_cards
    where game_id = p_game_id
      and zone = app_private.pile_zone(v_card.deck_type, 'discard');

    update app_private.game_cards
    set zone = app_private.pile_zone(v_card.deck_type, 'discard'),
        owner_player_id = null,
        pile_position = v_next
    where id = v_card.id;
  end loop;

  return v_count;
end;
$$;

-- Limite de mão ao encerrar o turno: exige descartar exatamente o excedente.
create function app_private.discard_to_hand_limit(
  p_game_id uuid,
  p_player_id uuid,
  p_card_ids uuid[],
  p_limit integer default 7
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_excess integer;
begin
  select greatest(count(*) - p_limit, 0) into v_excess
  from app_private.game_cards
  where owner_player_id = p_player_id and zone = 'player_hand';

  if coalesce(cardinality(p_card_ids), 0) <> v_excess then
    perform app_private.fail(
      'WRONG_DISCARD_COUNT',
      case v_excess
        when 0 then 'Você não precisa descartar.'
        when 1 then 'Você precisa descartar mais 1 carta.'
        else format('Você precisa descartar %s cartas.', v_excess)
      end
    );
  end if;

  if exists (
    select 1 from app_private.game_cards
    where id = any (p_card_ids) and zone <> 'player_hand'
  ) then
    perform app_private.fail('CARD_NOT_IN_HAND', 'Essa carta não está na sua mão.');
  end if;

  return app_private.discard_cards(p_game_id, p_player_id, p_card_ids);
end;
$$;

-- PV inicial pelo número de jogadores (Resenha Simples 7.1).
create function app_private.starting_hp(p_player_count integer)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select (case when p_player_count between 4 and 5 then 18 else 16 end)::smallint;
$$;

-- Cria as 180 instâncias, embaralha os dois baralhos e distribui 5 cartas
-- por jogador em ordem de assento.
create function app_private.setup_game_cards(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set text;
  v_hp smallint;
  v_player record;
begin
  select card_set_version into v_set from app_private.games where id = p_game_id;

  if exists (select 1 from app_private.game_cards where game_id = p_game_id) then
    perform app_private.fail('CARDS_ALREADY_DEALT', 'As cartas desta partida já foram distribuídas.');
  end if;

  insert into app_private.game_cards (game_id, set_version, card_code, deck_type, zone, pile_position)
  select
    p_game_id,
    d.set_version,
    d.code,
    d.deck_type,
    d.deck_type || '_deck',
    row_number() over (partition by d.deck_type order by gen_random_uuid())
  from app_private.card_definitions d
  cross join lateral generate_series(1, d.copies)
  where d.set_version = v_set and d.enabled;

  v_hp := app_private.starting_hp(
    (select count(*)::integer from app_private.game_players where game_id = p_game_id)
  );

  update app_private.game_players
  set life_status = 'alive', max_hp = v_hp, hp = v_hp,
      ghost_tokens = 0, revival_used = false, knockouts = 0
  where game_id = p_game_id;

  for v_player in
    select id from app_private.game_players where game_id = p_game_id order by seat
  loop
    perform app_private.draw_cards(p_game_id, v_player.id, 'main', 5);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- start_game agora prepara as cartas
-- -----------------------------------------------------------------------------

create or replace function app_private.start_game(p_game_id uuid, p_expected_version bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
  v_game app_private.games := app_private.lock_member_game(p_game_id, v_uid);
  v_count integer;
begin
  perform app_private.assert_host(v_game, v_uid);
  perform app_private.assert_lobby(v_game);

  if v_game.version <> p_expected_version then
    perform app_private.fail('VERSION_CONFLICT', 'A sala mudou. Confira os jogadores e tente de novo.');
  end if;

  select count(*) into v_count from app_private.game_players where game_id = p_game_id;

  if v_count < 3 then
    perform app_private.fail('NOT_ENOUGH_PLAYERS', 'São precisos pelo menos 3 jogadores.');
  end if;

  update app_private.games
  set status = 'playing', started_at = now(), round_number = 1
  where id = p_game_id;

  update app_private.game_invites set active = false where game_id = p_game_id;

  perform app_private.setup_game_cards(p_game_id);

  -- O motor de turnos (Fase 5) define o primeiro turno aqui.

  perform app_private.touch_game(p_game_id);
end;
$$;

-- -----------------------------------------------------------------------------
-- Leitura segura da mesa
-- -----------------------------------------------------------------------------
-- Cada um vê a própria mão. Dos outros: só quantas cartas têm. A ordem dos
-- baralhos nunca sai do banco; descartes são públicos (só a carta do topo).

create function app_private.game_view(p_game_id uuid, p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select id from app_private.game_players where game_id = p_game_id and user_id = p_user_id
  ),
  pile as (
    select zone, count(*) as total, max(pile_position) as top_position
    from app_private.game_cards
    where game_id = p_game_id and owner_player_id is null
    group by zone
  )
  select jsonb_build_object(
    'gameId', g.id,
    'version', g.version,
    'status', g.status,
    'phase', g.phase,
    'round', g.round_number,
    'maxRounds', 10,
    'cardSetVersion', g.card_set_version,
    'hostUserId', g.host_user_id,
    'activePlayerId', null,
    'leaderPlayerId', null,
    'myPlayerId', (select id from me),
    'participants', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', gp.id,
          'userId', gp.user_id,
          'displayName', p.display_name,
          'avatarPath', p.avatar_path,
          'seat', gp.seat,
          'isHost', gp.user_id = g.host_user_id,
          'hp', gp.hp,
          'maxHp', gp.max_hp,
          'alive', gp.life_status = 'alive',
          'cardsInHand', (
            select count(*) from app_private.game_cards c
            where c.owner_player_id = gp.id and c.zone = 'player_hand'
          ),
          'ghostCardsInHand', (
            select count(*) from app_private.game_cards c
            where c.owner_player_id = gp.id and c.zone = 'ghost_hand'
          ),
          'ghostTokens', gp.ghost_tokens,
          'revivalUsed', gp.revival_used,
          'knockouts', gp.knockouts
        )
        order by gp.seat
      )
      from app_private.game_players gp
      join public.profiles p on p.id = gp.user_id
      where gp.game_id = g.id
    ), '[]'::jsonb),
    'myHand', coalesce((
      select jsonb_agg(jsonb_build_object('instanceId', c.id, 'code', c.card_code)
                       order by c.pile_position)
      from app_private.game_cards c
      where c.owner_player_id = (select id from me) and c.zone = 'player_hand'
    ), '[]'::jsonb),
    'myGhostHand', coalesce((
      select jsonb_agg(jsonb_build_object('instanceId', c.id, 'code', c.card_code)
                       order by c.pile_position)
      from app_private.game_cards c
      where c.owner_player_id = (select id from me) and c.zone = 'ghost_hand'
    ), '[]'::jsonb),
    'mainDeckCount', coalesce((select total from pile where zone = 'main_deck'), 0),
    'ghostDeckCount', coalesce((select total from pile where zone = 'ghost_deck'), 0),
    'mainDiscardCount', coalesce((select total from pile where zone = 'main_discard'), 0),
    'ghostDiscardCount', coalesce((select total from pile where zone = 'ghost_discard'), 0),
    'mainDiscardTop', (
      select c.card_code from app_private.game_cards c
      where c.game_id = g.id and c.zone = 'main_discard'
        and c.pile_position = (select top_position from pile where zone = 'main_discard')
    ),
    'ghostDiscardTop', (
      select c.card_code from app_private.game_cards c
      where c.game_id = g.id and c.zone = 'ghost_discard'
        and c.pile_position = (select top_position from pile where zone = 'ghost_discard')
    )
  )
  from app_private.games g
  where g.id = p_game_id;
$$;

create function app_private.get_game_view(p_game_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := app_private.require_user();
begin
  if not app_private.is_game_member(p_game_id, v_uid) then
    perform app_private.fail('ROOM_NOT_FOUND', 'Sala não encontrada ou você não faz parte dela.');
  end if;

  return app_private.game_view(p_game_id, v_uid);
end;
$$;

-- Catálogo público (faces das cartas). Não revela nada de partidas.
create function app_private.get_card_catalog(p_set_version text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app_private.require_user();

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'code', d.code,
        'name', d.name,
        'characterName', d.character_name,
        'category', d.category,
        'deckType', d.deck_type,
        'copies', d.copies,
        'targetRule', d.target_rule,
        'isReaction', d.is_reaction,
        'rulesText', d.rules_text,
        'imagePath', d.image_path,
        'isProvisional', d.is_provisional
      )
      order by d.deck_type desc, d.code
    )
    from app_private.card_definitions d
    where d.set_version = coalesce(p_set_version, '7.1') and d.enabled
  ), '[]'::jsonb);
end;
$$;

create function public.get_game_view(p_game_id uuid)
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app_private.get_game_view(p_game_id); $$;

create function public.get_card_catalog(p_set_version text default '7.1')
returns jsonb language sql stable security invoker set search_path = ''
as $$ select app_private.get_card_catalog(p_set_version); $$;

grant execute on function
  public.get_game_view(uuid),
  public.get_card_catalog(text),
  app_private.get_game_view(uuid),
  app_private.get_card_catalog(text)
to authenticated;
