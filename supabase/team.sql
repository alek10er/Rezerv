-- =====================================================================
--  РЕЗЕРВ — команды: участники, доступы, ссылки-приглашения
--  Выполнить один раз ПОСЛЕ schema.sql и company.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Модель: команда = кабинет владельца (его profiles.id).
--  Доступ участника:  viewer — «Наблюдатель» (только просмотр)
--                     editor — «Менеджер»   (может работать в кабинете)
--  Управлять командой (приглашать, менять доступ, удалять) может только владелец.
-- =====================================================================

-- 1. Участники команды
create table if not exists public.team_members (
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  access     text not null default 'viewer' check (access in ('viewer', 'editor')),
  position   text not null default '' check (char_length(position) <= 60),  -- должность: «Снабженец», «Финансы»…
  created_at timestamptz not null default now(),
  primary key (owner_id, user_id),
  check (owner_id <> user_id)
);
create index if not exists team_members_user_idx on public.team_members (user_id);

-- 2. Ссылки-приглашения (одноразовые, 7 дней)
create table if not exists public.team_invites (
  id         uuid primary key default gen_random_uuid(),
  token      text not null unique default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
  owner_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  access     text not null default 'viewer' check (access in ('viewer', 'editor')),
  position   text not null default '' check (char_length(position) <= 60),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  used_by    uuid references public.profiles (id) on delete set null,
  used_at    timestamptz
);
create index if not exists team_invites_owner_idx on public.team_invites (owner_id);

-- 3. Вспомогательные функции (security definer — без рекурсии в RLS)
create or replace function public.is_team_member(p_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.team_members m where m.owner_id = p_owner and m.user_id = auth.uid());
$$;

create or replace function public.is_team_editor(p_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.team_members m
                 where m.owner_id = p_owner and m.user_id = auth.uid() and m.access = 'editor');
$$;

-- Видит ли текущий пользователь профиль p_target через общую команду
create or replace function public.shares_team(p_target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.team_members m
    where (m.owner_id = auth.uid() and m.user_id = p_target)          -- я владелец, он участник
       or (m.user_id = auth.uid() and m.owner_id = p_target)          -- он владелец моей команды
       or (m.user_id = auth.uid() and exists (                         -- мы в одной команде
             select 1 from public.team_members m2
             where m2.owner_id = m.owner_id and m2.user_id = p_target))
  );
$$;

-- 4. RLS: team_members
alter table public.team_members enable row level security;
drop policy if exists "team_members: read"         on public.team_members;
drop policy if exists "team_members: owner update" on public.team_members;
drop policy if exists "team_members: delete"       on public.team_members;

create policy "team_members: read" on public.team_members for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_team_member(owner_id));

create policy "team_members: owner update" on public.team_members for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

-- Владелец удаляет любого, участник может выйти сам
create policy "team_members: delete" on public.team_members for delete to authenticated
  using (owner_id = (select auth.uid()) or user_id = (select auth.uid()));

revoke all on public.team_members from anon, authenticated;
grant select, delete on public.team_members to authenticated;
grant update (access, position) on public.team_members to authenticated;

-- 5. RLS: team_invites — только владелец
alter table public.team_invites enable row level security;
drop policy if exists "team_invites: owner read"   on public.team_invites;
drop policy if exists "team_invites: owner insert" on public.team_invites;
drop policy if exists "team_invites: owner delete" on public.team_invites;

create policy "team_invites: owner read" on public.team_invites for select to authenticated
  using (owner_id = (select auth.uid()));
create policy "team_invites: owner insert" on public.team_invites for insert to authenticated
  with check (owner_id = (select auth.uid()));
create policy "team_invites: owner delete" on public.team_invites for delete to authenticated
  using (owner_id = (select auth.uid()));

revoke all on public.team_invites from anon, authenticated;
grant select, delete on public.team_invites to authenticated;
grant insert (access, position) on public.team_invites to authenticated;

-- 6. Профили: участники команды видят профили друг друга и профиль владельца
drop policy if exists "profiles: read team" on public.profiles;
create policy "profiles: read team" on public.profiles for select to authenticated
  using (public.shares_team(id));

-- 7. Информация о приглашении по токену (для экрана «Вас пригласили…»)
create or replace function public.get_invite(p_token text)
returns table (owner_name text, company text, access text, "position" text, status text)
language plpgsql stable security definer set search_path = '' as $$
declare i public.team_invites; p public.profiles;
begin
  select * into i from public.team_invites where token = p_token;
  if not found then
    return query select ''::text, ''::text, ''::text, ''::text, 'not_found'::text; return;
  end if;
  select * into p from public.profiles where id = i.owner_id;
  return query select p.full_name, p.company, i.access, i.position,
    case when i.used_at is not null then 'used'
         when i.expires_at < now() then 'expired'
         when i.owner_id = auth.uid() then 'own'
         when exists (select 1 from public.team_members m where m.owner_id = i.owner_id and m.user_id = auth.uid()) then 'member'
         else 'ok' end;
end;
$$;

-- 8. Принять приглашение
create or replace function public.accept_invite(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare i public.team_invites;
begin
  if auth.uid() is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into i from public.team_invites where token = p_token for update;
  if not found then raise exception 'Приглашение не найдено'; end if;
  if i.used_at is not null then raise exception 'Приглашение уже использовано'; end if;
  if i.expires_at < now() then raise exception 'Срок приглашения истёк'; end if;
  if i.owner_id = auth.uid() then raise exception 'Это приглашение в вашу собственную команду'; end if;

  insert into public.team_members (owner_id, user_id, access, position)
  values (i.owner_id, auth.uid(), i.access, i.position)
  on conflict (owner_id, user_id) do update set access = excluded.access, position = excluded.position;

  update public.team_invites set used_by = auth.uid(), used_at = now() where id = i.id;
  return i.owner_id;
end;
$$;

-- 9. Изменить реквизиты компании команды (владелец или менеджер)
create or replace function public.update_team_company(p_owner uuid, p_patch jsonb)
returns public.profiles language plpgsql security definer set search_path = '' as $$
declare r public.profiles;
begin
  if auth.uid() is null or not (auth.uid() = p_owner or public.is_team_editor(p_owner)) then
    raise exception 'Нет прав на изменение данных компании';
  end if;
  update public.profiles set
    company           = coalesce(p_patch ->> 'company', company),
    inn               = coalesce(p_patch ->> 'inn', inn),
    kpp               = coalesce(p_patch ->> 'kpp', kpp),
    ogrn              = coalesce(p_patch ->> 'ogrn', ogrn),
    legal_address     = coalesce(p_patch ->> 'legal_address', legal_address),
    warehouse_address = coalesce(p_patch ->> 'warehouse_address', warehouse_address),
    phone             = coalesce(p_patch ->> 'phone', phone),
    categories        = coalesce(p_patch ->> 'categories', categories)
  where id = p_owner
  returning * into r;
  return r;
end;
$$;

revoke all on function public.get_invite(text)                 from public;
revoke all on function public.accept_invite(text)              from public;
revoke all on function public.update_team_company(uuid, jsonb) from public;
revoke all on function public.is_team_member(uuid)             from public;
revoke all on function public.is_team_editor(uuid)             from public;
revoke all on function public.shares_team(uuid)                from public;
grant execute on function public.get_invite(text)                 to anon, authenticated;
grant execute on function public.accept_invite(text)              to authenticated;
grant execute on function public.update_team_company(uuid, jsonb) to authenticated;
grant execute on function public.is_team_member(uuid)             to authenticated;
grant execute on function public.is_team_editor(uuid)             to authenticated;
grant execute on function public.shares_team(uuid)                to authenticated;
