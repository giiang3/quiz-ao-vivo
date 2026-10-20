-- Login do apresentador (e-mail + senha). Os quizzes passam a ficar acessíveis de qualquer computador.
-- As tabelas de login ficam no schema "private", que não é exposto pela API.
-- A conta é criada à parte (fora deste arquivo), com a senha guardada como hash bcrypt.

create table if not exists private.admins(
  email text primary key,
  pw_hash text not null,
  failed int not null default 0,
  locked_until timestamptz
);
create table if not exists private.admin_sessions(
  token_hash text primary key,
  email text not null references private.admins(email),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
revoke all on private.admins, private.admin_sessions from public, anon, authenticated;

-- "Apagar quiz" no editor esconde o quiz (fica guardado no banco)
alter table public.quizzes add column if not exists archived_at timestamptz;

create or replace function private.admin_email(p_token text) returns text
language sql stable security definer set search_path = '' as $$
  select s.email from private.admin_sessions s
  where s.token_hash = private.h(p_token) and s.expires_at > now()
$$;

create or replace function private.admin_ok(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.admin_email(p_token) is not null
$$;

-- Senha errada devolve {ok:false} em vez de erro, pra que o contador de tentativas seja gravado.
create or replace function public.admin_login(p_email text, p_pw text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a private.admins; tok text;
begin
  select * into a from private.admins where email = lower(btrim(coalesce(p_email,'')));
  if not found then
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'error', 'E-mail ou senha incorretos');
  end if;
  if a.locked_until is not null and a.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Muitas tentativas erradas. Tente de novo em 15 minutos.');
  end if;
  if extensions.crypt(coalesce(p_pw,''), a.pw_hash) <> a.pw_hash then
    update private.admins
      set failed = a.failed + 1,
          locked_until = case when a.failed + 1 >= 8 then now() + interval '15 minutes' end
      where email = a.email;
    return jsonb_build_object('ok', false, 'error', 'E-mail ou senha incorretos');
  end if;
  update private.admins set failed = 0, locked_until = null where email = a.email;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into private.admin_sessions(token_hash, email, expires_at) values (private.h(tok), a.email, now() + interval '90 days');
  return jsonb_build_object('ok', true, 'token', tok, 'email', a.email);
end $$;

create or replace function public.admin_logout(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  update private.admin_sessions set expires_at = now() where token_hash = private.h(p_token);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_change_password(p_token text, p_old text, p_new text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare em text := private.admin_email(p_token); a private.admins;
begin
  if em is null then raise exception 'Sessão expirada. Entre de novo.'; end if;
  select * into a from private.admins where email = em;
  if extensions.crypt(coalesce(p_old,''), a.pw_hash) <> a.pw_hash then
    return jsonb_build_object('ok', false, 'error', 'A senha atual não confere');
  end if;
  if length(coalesce(p_new,'')) < 8 then
    return jsonb_build_object('ok', false, 'error', 'A senha nova precisa ter pelo menos 8 caracteres');
  end if;
  update private.admins set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)) where email = em;
  -- encerra os logins nos outros computadores
  update private.admin_sessions set expires_at = now() where email = em and token_hash <> private.h(p_token) and expires_at > now();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_quizzes(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_ok(p_token) then raise exception 'Sessão expirada. Entre de novo.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'n', jsonb_array_length(q.questions),
                                        'updated_at', private.ms(q.updated_at)) order by q.updated_at desc)
    from public.quizzes q where q.archived_at is null), '[]'::jsonb);
end $$;

create or replace function public.admin_archive_quiz(p_token text, p_quiz uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_ok(p_token) then raise exception 'Sessão expirada. Entre de novo.'; end if;
  update public.quizzes set archived_at = now() where id = p_quiz;
  return jsonb_build_object('ok', true);
end $$;

-- Criar quiz agora exige login. A versão antiga (sem login) passa a recusar.
create or replace function public.create_quiz(p_title text, p_questions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'Sessão expirada. Entre de novo.';
end $$;
create or replace function public.create_quiz(p_token text, p_title text, p_questions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text := gen_random_uuid()::text; qid uuid;
begin
  if not private.admin_ok(p_token) then raise exception 'Sessão expirada. Entre de novo.'; end if;
  perform private.check_questions(p_questions, false);
  insert into public.quizzes(edit_key_hash, title, questions)
  values (private.h(k), private.clean_title(p_title), p_questions) returning id into qid;
  return jsonb_build_object('id', qid, 'key', k);
end $$;

-- Abrir, salvar e iniciar aceitam a chave do quiz (links antigos) ou o login do apresentador
create or replace function public.get_quiz(p_quiz uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare qz public.quizzes;
begin
  select * into qz from public.quizzes where id = p_quiz and archived_at is null and (edit_key_hash = private.h(p_key) or private.admin_ok(p_key));
  if not found then raise exception 'Quiz não encontrado'; end if;
  return jsonb_build_object('id', qz.id, 'title', qz.title, 'questions', qz.questions, 'updated_at', private.ms(qz.updated_at));
end $$;

create or replace function public.save_quiz(p_quiz uuid, p_key text, p_title text, p_questions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_questions(p_questions, false);
  update public.quizzes set title = private.clean_title(p_title), questions = p_questions, updated_at = now()
  where id = p_quiz and archived_at is null and (edit_key_hash = private.h(p_key) or private.admin_ok(p_key));
  if not found then raise exception 'Quiz não encontrado'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.create_session(p_quiz uuid, p_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare qz public.quizzes; v_pin text; hk text := gen_random_uuid()::text; sid uuid; tries int := 0;
begin
  select * into qz from public.quizzes where id = p_quiz and archived_at is null and (edit_key_hash = private.h(p_key) or private.admin_ok(p_key));
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

revoke all on function public.admin_login, public.admin_logout, public.admin_change_password,
  public.admin_list_quizzes, public.admin_archive_quiz, public.create_quiz(text, text, jsonb) from public;
grant execute on function public.admin_login, public.admin_logout, public.admin_change_password,
  public.admin_list_quizzes, public.admin_archive_quiz, public.create_quiz(text, text, jsonb) to anon, authenticated;
revoke all on function private.admin_email, private.admin_ok from public, anon, authenticated;
