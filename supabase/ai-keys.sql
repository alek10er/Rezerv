-- =====================================================================
--  РЕЗЕРВ — свой API-ключ Gemini для кабинета
--  Выполнить ПОСЛЕ agent.sql:  SQL Editor → New query → Run
--  (повторный запуск безопасен)
--
--  Ключ хранится зашифрованным в Supabase Vault. С сайта его прочитать
--  нельзя — видны только последние 4 символа, модель и статус.
--  Сохраняет ключ Edge Function seller-agent (сначала проверяет его в Google),
--  расшифровывает — тоже только она, с ключом сервиса.
--  Если своего ключа нет или он перестал работать — агент берёт ключ платформы.
-- =====================================================================

create extension if not exists supabase_vault with schema vault;

create table if not exists public.ai_keys (
  owner_id     uuid primary key references public.profiles (id) on delete cascade,
  provider     text not null default 'gemini' check (provider in ('gemini')),
  model        text not null default 'gemini-2.5-flash' check (model ~ '^[a-z0-9][a-z0-9.-]{2,79}$'),
  secret_id    uuid not null,                  -- запись в vault.secrets
  last4        text not null default '',
  status       text not null default 'ok' check (status in ('ok', 'error')),
  last_error   text not null default '' check (char_length(last_error) <= 300),
  last_used_at timestamptz,
  uses         int not null default 0,
  created_by   uuid references public.profiles (id) on delete set null,
  updated_at   timestamptz not null default now()
);

alter table public.ai_keys enable row level security;
drop policy if exists "ai_keys: read" on public.ai_keys;
create policy "ai_keys: read" on public.ai_keys for select to authenticated using (public.can_view_party(owner_id));
revoke all on public.ai_keys from anon, authenticated;
grant select (owner_id, provider, model, last4, status, last_error, last_used_at, uses, updated_at) on public.ai_keys to authenticated;

-- Сохранить / заменить ключ (p_key = null — поменять только модель). Только для Edge Function.
create or replace function public.ai_key_store(p_owner uuid, p_key text, p_model text, p_user uuid)
returns public.ai_keys language plpgsql security definer set search_path = '' as $$
declare k public.ai_keys; v_secret uuid;
begin
  select * into k from public.ai_keys where owner_id = p_owner for update;
  if k.owner_id is null then
    if p_key is null then raise exception 'Сначала укажите ключ'; end if;
    v_secret := vault.create_secret(p_key, 'ai_key_' || p_owner::text, 'Gemini API key кабинета РЕЗЕРВ');
    insert into public.ai_keys (owner_id, model, secret_id, last4, created_by)
    values (p_owner, p_model, v_secret, right(p_key, 4), p_user)
    returning * into k;
  else
    if p_key is not null then
      perform vault.update_secret(k.secret_id, p_key);
    end if;
    update public.ai_keys set model = p_model,
      last4 = case when p_key is not null then right(p_key, 4) else last4 end,
      status = 'ok', last_error = '', updated_at = now()
    where owner_id = p_owner returning * into k;
  end if;
  return k;
end;
$$;

-- Расшифрованный ключ кабинета. Только для Edge Function.
create or replace function public.ai_key_get(p_owner uuid)
returns table (api_key text, model text) language sql stable security definer set search_path = '' as $$
  select s.decrypted_secret, k.model
  from public.ai_keys k join vault.decrypted_secrets s on s.id = k.secret_id
  where k.owner_id = p_owner;
$$;

-- Отметить результат запроса с ключом кабинета. Только для Edge Function.
create or replace function public.ai_key_mark(p_owner uuid, p_ok boolean, p_error text default '')
returns void language sql security definer set search_path = '' as $$
  update public.ai_keys set
    status = case when p_ok then 'ok' else 'error' end,
    last_error = case when p_ok then '' else left(coalesce(p_error, ''), 300) end,
    last_used_at = case when p_ok then now() else last_used_at end,
    uses = uses + case when p_ok then 1 else 0 end
  where owner_id = p_owner;
$$;

-- Отключить свой ключ (только владелец кабинета). Секрет удаляется из Vault.
create or replace function public.ai_key_delete(p_owner uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret uuid;
begin
  if auth.uid() is null or auth.uid() <> p_owner then raise exception 'Ключом управляет только владелец кабинета'; end if;
  delete from public.ai_keys where owner_id = p_owner returning secret_id into v_secret;
  if v_secret is not null then delete from vault.secrets where id = v_secret; end if;
end;
$$;

revoke all on function public.ai_key_store(uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.ai_key_get(uuid) from public, anon, authenticated;
revoke all on function public.ai_key_mark(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.ai_key_delete(uuid) from public, anon;
grant execute on function public.ai_key_store(uuid, text, text, uuid) to service_role;
grant execute on function public.ai_key_get(uuid) to service_role;
grant execute on function public.ai_key_mark(uuid, boolean, text) to service_role;
grant execute on function public.ai_key_delete(uuid) to authenticated;
