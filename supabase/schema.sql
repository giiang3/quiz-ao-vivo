-- Esquema do Quiz ao Vivo (Supabase / Postgres)
create schema if not exists private;

create table public.quizzes(
  id uuid primary key default gen_random_uuid(),
  edit_key_hash text not null,
  title text not null default 'Meu quiz',
  questions jsonb not null default '[]',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sessions(
  id uuid primary key default gen_random_uuid(),
  pin text not null,
  quiz_id uuid references public.quizzes(id) on delete set null,
  host_key_hash text not null,
  title text not null,
  questions jsonb not null,
  phase text not null default 'lobby' check (phase in ('lobby','question','reveal','leaderboard','final')),
  q_index int not null default -1,
  starts_at timestamptz,
  ends_at timestamptz,
  open boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index sessions_open_pin on public.sessions(pin) where open;
create index sessions_quiz on public.sessions(quiz_id);

create table public.players(
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  name text not null,
  secret_hash text not null,
  score int not null default 0,
  rank int,
  prev_rank int,
  kicked boolean not null default false,
  joined_at timestamptz not null default now()
);
create unique index players_name on public.players(session_id, lower(name)) where not kicked;
create index players_session on public.players(session_id);

create table public.answers(
  player_id uuid not null references public.players(id) on delete cascade,
  session_id uuid not null references public.sessions(id) on delete cascade,
  q_index int not null,
  choice int not null,
  correct boolean not null,
  elapsed_ms int not null,
  points int not null,
  created_at timestamptz not null default now(),
  primary key (player_id, q_index)
);
create index answers_session_q on public.answers(session_id, q_index);

alter table public.quizzes enable row level security;
alter table public.sessions enable row level security;
alter table public.players enable row level security;
alter table public.answers enable row level security;
revoke all on public.quizzes, public.sessions, public.players, public.answers from anon, authenticated;

-- helpers (not exposed through the API)
create or replace function private.h(t text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(convert_to(coalesce(t,''), 'utf8'), 'sha256'), 'hex')
$$;

create or replace function private.ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$
  select case when t is null then null else (extract(epoch from t) * 1000)::bigint end
$$;

create or replace function private.check_questions(q jsonb, strict boolean) returns void
language plpgsql immutable set search_path = '' as $$
declare e jsonb; n int; t text; i int := 0;
begin
  if q is null or jsonb_typeof(q) <> 'array' then raise exception 'Formato de perguntas inválido'; end if;
  if jsonb_array_length(q) > 30 then raise exception 'Máximo de 30 perguntas'; end if;
  if length(q::text) > 100000 then raise exception 'Quiz grande demais'; end if;
  if not strict then return; end if;
  if jsonb_array_length(q) < 1 then raise exception 'Adicione pelo menos uma pergunta'; end if;
  for e in select value from jsonb_array_elements(q) loop
    i := i + 1;
    t := e->>'type';
    if t is null or t not in ('mc','tf') then raise exception 'Pergunta %: tipo inválido', i; end if;
    if coalesce(length(btrim(e->>'text')),0) = 0 then raise exception 'Pergunta % está sem texto', i; end if;
    if jsonb_typeof(e->'options') <> 'array' then raise exception 'Pergunta %: alternativas inválidas', i; end if;
    n := jsonb_array_length(e->'options');
    if (t = 'mc' and (n < 2 or n > 4)) or (t = 'tf' and n <> 2) then raise exception 'Pergunta %: número de alternativas inválido', i; end if;
    if exists (select 1 from jsonb_array_elements_text(e->'options') o where length(btrim(o)) = 0) then
      raise exception 'Pergunta % tem alternativa vazia', i; end if;
    if jsonb_typeof(e->'correct') <> 'number' or (e->>'correct')::int < 0 or (e->>'correct')::int >= n then
      raise exception 'Pergunta %: marque a alternativa correta', i; end if;
    if jsonb_typeof(e->'time') <> 'number' or (e->>'time')::int < 5 or (e->>'time')::int > 240 then
      raise exception 'Pergunta %: tempo deve ficar entre 5 e 240 s', i; end if;
    if jsonb_typeof(e->'mult') <> 'number' or (e->>'mult')::int not in (1,2,3) then
      raise exception 'Pergunta %: multiplicador inválido', i; end if;
  end loop;
end $$;

create or replace function private.clean_title(t text) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(left(btrim(regexp_replace(coalesce(t,''), '\s+', ' ', 'g')), 80), ''), 'Meu quiz')
$$;

-- ===== quiz editor =====
create or replace function public.create_quiz(p_title text, p_questions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text := gen_random_uuid()::text; qid uuid;
begin
  perform private.check_questions(p_questions, false);
  insert into public.quizzes(edit_key_hash, title, questions)
  values (private.h(k), private.clean_title(p_title), p_questions) returning id into qid;
  return jsonb_build_object('id', qid, 'key', k);
end $$;

create or replace function public.get_quiz(p_quiz uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare qz public.quizzes;
begin
  select * into qz from public.quizzes where id = p_quiz and edit_key_hash = private.h(p_key);
  if not found then raise exception 'Quiz não encontrado'; end if;
  return jsonb_build_object('id', qz.id, 'title', qz.title, 'questions', qz.questions, 'updated_at', private.ms(qz.updated_at));
end $$;

create or replace function public.save_quiz(p_quiz uuid, p_key text, p_title text, p_questions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_questions(p_questions, false);
  update public.quizzes set title = private.clean_title(p_title), questions = p_questions, updated_at = now()
  where id = p_quiz and edit_key_hash = private.h(p_key);
  if not found then raise exception 'Quiz não encontrado'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ===== host =====
create or replace function public.create_session(p_quiz uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare qz public.quizzes; v_pin text; hk text := gen_random_uuid()::text; sid uuid; tries int := 0;
begin
  select * into qz from public.quizzes where id = p_quiz and edit_key_hash = private.h(p_key);
  if not found then raise exception 'Quiz não encontrado'; end if;
  perform private.check_questions(qz.questions, true);
  update public.sessions set open = false where open and created_at < now() - interval '12 hours';
  loop
    v_pin := (floor(random() * 900000) + 100000)::int::text;
    begin
      insert into public.sessions(pin, quiz_id, host_key_hash, title, questions)
      values (v_pin, qz.id, private.h(hk), qz.title, qz.questions) returning id into sid;
      exit;
    exception when unique_violation then
      tries := tries + 1;
      if tries > 30 then raise; end if;
    end;
  end loop;
  return jsonb_build_object('session_id', sid, 'pin', v_pin, 'host_key', hk);
end $$;

create or replace function public.host_poll(p_session uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sessions; n int := 0;
begin
  select * into s from public.sessions where id = p_session and host_key_hash = private.h(p_key);
  if not found then raise exception 'Sessão não encontrada'; end if;
  if s.q_index >= 0 then n := jsonb_array_length(s.questions->s.q_index->'options'); end if;
  return jsonb_build_object(
    'now', private.ms(now()),
    'pin', s.pin, 'title', s.title, 'phase', s.phase, 'q_index', s.q_index, 'open', s.open,
    'questions', s.questions,
    'starts_at', private.ms(s.starts_at), 'ends_at', private.ms(s.ends_at),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'score', p.score, 'rank', p.rank, 'prev_rank', p.prev_rank)
                       order by p.score desc, p.joined_at)
      from public.players p where p.session_id = s.id and not p.kicked), '[]'::jsonb),
    'answered', (select count(*) from public.answers a join public.players p on p.id = a.player_id
                 where a.session_id = s.id and a.q_index = s.q_index and not p.kicked),
    'counts', case when s.q_index >= 0 and s.phase <> 'question' then (
      select jsonb_agg((select count(*) from public.answers a join public.players p on p.id = a.player_id
                        where a.session_id = s.id and a.q_index = s.q_index and a.choice = g and not p.kicked) order by g)
      from generate_series(0, n - 1) g) end,
    'round_points', case when s.q_index >= 0 and s.phase <> 'question' then coalesce((
      select jsonb_object_agg(a.player_id::text, a.points) from public.answers a
      where a.session_id = s.id and a.q_index = s.q_index), '{}'::jsonb) end
  );
end $$;

create or replace function public.host_action(p_session uuid, p_key text, p_action text, p_arg text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sessions; total int; nxt int; lim int; cd interval;
begin
  select * into s from public.sessions where id = p_session and host_key_hash = private.h(p_key) for update;
  if not found then raise exception 'Sessão não encontrada'; end if;
  total := jsonb_array_length(s.questions);

  if p_action = 'next' then
    if s.phase not in ('lobby','reveal','leaderboard') then return jsonb_build_object('ok', false); end if;
    nxt := s.q_index + 1;
    if nxt >= total then
      update public.sessions set phase = 'final' where id = s.id;
    else
      lim := (s.questions->nxt->>'time')::int;
      cd := case when s.phase = 'lobby' then interval '5 seconds' else interval '4 seconds' end;
      update public.sessions set phase = 'question', q_index = nxt,
        starts_at = now() + cd, ends_at = now() + cd + make_interval(secs => lim)
      where id = s.id;
    end if;

  elsif p_action = 'reveal' then
    if s.phase <> 'question' then return jsonb_build_object('ok', false); end if;
    update public.players p set prev_rank = p.rank where p.session_id = s.id;
    update public.players p set score = coalesce((select sum(a.points) from public.answers a where a.player_id = p.id), 0)
      where p.session_id = s.id;
    update public.players p set rank = r.rk
      from (select x.id, rank() over (order by x.score desc) rk from public.players x where x.session_id = s.id and not x.kicked) r
      where p.id = r.id;
    update public.sessions set phase = 'reveal', ends_at = least(ends_at, now()) where id = s.id;

  elsif p_action = 'leaderboard' then
    if s.phase <> 'reveal' then return jsonb_build_object('ok', false); end if;
    update public.sessions set phase = 'leaderboard' where id = s.id;

  elsif p_action = 'final' then
    if s.phase not in ('reveal','leaderboard') then return jsonb_build_object('ok', false); end if;
    update public.sessions set phase = 'final' where id = s.id;

  elsif p_action = 'close' then
    update public.sessions set open = false where id = s.id;

  elsif p_action = 'kick' then
    update public.players set kicked = true where id = p_arg::uuid and session_id = s.id;

  else
    raise exception 'Ação inválida';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ===== players =====
create or replace function public.join_session(p_pin text, p_name text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.sessions; nm text; sec text := gen_random_uuid()::text; pid uuid;
begin
  nm := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
  if length(nm) < 1 or length(nm) > 20 then raise exception 'O nome precisa ter de 1 a 20 caracteres'; end if;
  select * into s from public.sessions where pin = btrim(coalesce(p_pin,'')) and open;
  if not found then raise exception 'PIN não encontrado. Confira o número no telão.'; end if;
  if s.phase = 'final' then raise exception 'Este quiz já terminou'; end if;
  if (select count(*) from public.players where session_id = s.id and not kicked) >= 250 then
    raise exception 'A sala está cheia'; end if;
  begin
    insert into public.players(session_id, name, secret_hash) values (s.id, nm, private.h(sec)) returning id into pid;
  exception when unique_violation then
    raise exception 'Já tem alguém com esse nome na sala. Escolha outro.';
  end;
  return jsonb_build_object('player_id', pid, 'secret', sec, 'session_id', s.id, 'name', nm);
end $$;

create or replace function public.player_poll(p_player uuid, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.players; s public.sessions; q jsonb; a public.answers; res jsonb;
begin
  select * into p from public.players where id = p_player and secret_hash = private.h(p_secret);
  if not found then raise exception 'Jogador não encontrado'; end if;
  select * into s from public.sessions where id = p.session_id;
  res := jsonb_build_object(
    'now', private.ms(now()), 'name', p.name, 'kicked', p.kicked, 'title', s.title,
    'phase', s.phase, 'open', s.open, 'q_index', s.q_index, 'total_q', jsonb_array_length(s.questions),
    'starts_at', private.ms(s.starts_at), 'ends_at', private.ms(s.ends_at),
    'score', p.score, 'rank', p.rank,
    'players', (select count(*) from public.players x where x.session_id = s.id and not x.kicked));
  if s.q_index >= 0 then
    q := s.questions->s.q_index;
    res := res || jsonb_build_object('question', jsonb_build_object(
      'text', q->'text', 'type', q->'type', 'options', q->'options', 'time', q->'time', 'mult', q->'mult'));
    select * into a from public.answers where player_id = p.id and q_index = s.q_index;
    if found then
      res := res || jsonb_build_object('my_choice', a.choice);
      if s.phase <> 'question' then
        res := res || jsonb_build_object('my_correct', a.correct, 'my_points', a.points);
      end if;
    end if;
    if s.phase <> 'question' then res := res || jsonb_build_object('correct', q->'correct'); end if;
  end if;
  return res;
end $$;

create or replace function public.submit_answer(p_player uuid, p_secret text, p_q int, p_choice int)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.players; s public.sessions; q jsonb; el int; lim int; corr boolean; pts int; mult int; n int;
begin
  select * into p from public.players where id = p_player and secret_hash = private.h(p_secret);
  if not found or p.kicked then raise exception 'Jogador não encontrado'; end if;
  select * into s from public.sessions where id = p.session_id;
  if s.phase <> 'question' or s.q_index <> p_q then raise exception 'Essa pergunta já foi encerrada'; end if;
  if now() < s.starts_at - interval '300 milliseconds' then raise exception 'A pergunta ainda não começou'; end if;
  if now() > s.ends_at + interval '1500 milliseconds' then raise exception 'Tempo esgotado'; end if;
  q := s.questions->s.q_index;
  n := jsonb_array_length(q->'options');
  if p_choice is null or p_choice < 0 or p_choice >= n then raise exception 'Alternativa inválida'; end if;
  lim := (q->>'time')::int * 1000;
  el := greatest(0, least(lim, (extract(epoch from (now() - s.starts_at)) * 1000)::int));
  corr := p_choice = (q->>'correct')::int;
  mult := (q->>'mult')::int;
  pts := case when not corr then 0
              when el < 500 then 1000 * mult
              else round(1000 * mult * (1 - (el::numeric / lim) / 2))::int end;
  insert into public.answers(player_id, session_id, q_index, choice, correct, elapsed_ms, points)
  values (p.id, s.id, p_q, p_choice, corr, el, pts) on conflict do nothing;
  if not found then raise exception 'Você já respondeu essa pergunta'; end if;
  return jsonb_build_object('ok', true, 'elapsed_ms', el);
end $$;

revoke all on function public.create_quiz, public.get_quiz, public.save_quiz, public.create_session,
  public.host_poll, public.host_action, public.join_session, public.player_poll, public.submit_answer from public;
grant execute on function public.create_quiz, public.get_quiz, public.save_quiz, public.create_session,
  public.host_poll, public.host_action, public.join_session, public.player_poll, public.submit_answer to anon, authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
