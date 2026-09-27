-- =====================================================================
--  РЕЗЕРВ — схема для входа в личный кабинет (Supabase)
--  Выполнить один раз: Supabase Dashboard → SQL Editor → New query → Run
-- =====================================================================

-- 1. Профили пользователей (1:1 с auth.users)
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text not null,
  full_name   text not null default '',
  company     text not null default '',
  role        text not null default 'buy' check (role in ('buy', 'sell')),  -- buy = покупатель, sell = поставщик
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is 'Профили пользователей личного кабинета РЕЗЕРВ';

-- 2. Row Level Security: каждый видит и меняет только свой профиль
alter table public.profiles enable row level security;

drop policy if exists "profiles: read own"   on public.profiles;
drop policy if exists "profiles: update own" on public.profiles;

create policy "profiles: read own"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "profiles: update own"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Пользователь может менять только имя и компанию (не email/роль/id)
revoke insert, update, delete on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, company) on public.profiles to authenticated;

-- 3. Автоматическое создание профиля при регистрации
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, company, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'company', ''),
    case when new.raw_user_meta_data ->> 'role' = 'sell' then 'sell' else 'buy' end
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4. Синхронизация email, если пользователь сменил его в Auth
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.profiles set email = new.email, updated_at = now() where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed
  after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- 5. Автообновление updated_at
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- 6. Профили для пользователей, созданных ДО запуска этого скрипта
insert into public.profiles (id, email, full_name, company, role)
select u.id,
       u.email,
       coalesce(u.raw_user_meta_data ->> 'full_name', ''),
       coalesce(u.raw_user_meta_data ->> 'company', ''),
       case when u.raw_user_meta_data ->> 'role' = 'sell' then 'sell' else 'buy' end
from auth.users u
on conflict (id) do nothing;
