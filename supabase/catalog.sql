-- =====================================================================
--  РЕЗЕРВ — каталог и прайс поставщика
--  Выполнить ПОСЛЕ schema.sql, company.sql и team.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Каталог принадлежит кабинету (owner_id = профиль владельца).
--  Владелец и менеджеры команды редактируют, наблюдатели только смотрят.
--  Видимые позиции (visible = true) могут читать все вошедшие пользователи —
--  так покупатели и их агенты видят цены и остатки.
-- =====================================================================

create table if not exists public.catalog_items (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 200),
  standard   text not null default '' check (char_length(standard) <= 100),   -- ГОСТ / ТУ / марка
  unit       text not null default 'т' check (char_length(btrim(unit)) between 1 and 10),
  price      numeric(14, 2) not null check (price >= 0),                        -- ₽ за единицу
  stock      numeric(14, 3) not null default 0 check (stock >= 0),
  visible    boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists catalog_items_owner_idx on public.catalog_items (owner_id, created_at);

-- Одна и та же позиция (наименование + стандарт) не дублируется в каталоге
create unique index if not exists catalog_items_unique_name
  on public.catalog_items (owner_id, lower(btrim(name)), lower(btrim(standard)));

-- Автообновление updated_at (функция создана в schema.sql)
drop trigger if exists catalog_items_touch_updated_at on public.catalog_items;
create trigger catalog_items_touch_updated_at
  before update on public.catalog_items
  for each row execute function public.touch_updated_at();

-- RLS
alter table public.catalog_items enable row level security;

drop policy if exists "catalog: read own or team"    on public.catalog_items;
drop policy if exists "catalog: read visible"        on public.catalog_items;
drop policy if exists "catalog: insert owner/editor" on public.catalog_items;
drop policy if exists "catalog: update owner/editor" on public.catalog_items;
drop policy if exists "catalog: delete owner/editor" on public.catalog_items;

create policy "catalog: read own or team" on public.catalog_items for select to authenticated
  using (owner_id = (select auth.uid()) or public.is_team_member(owner_id));

create policy "catalog: read visible" on public.catalog_items for select to authenticated
  using (visible);

create policy "catalog: insert owner/editor" on public.catalog_items for insert to authenticated
  with check (owner_id = (select auth.uid()) or public.is_team_editor(owner_id));

create policy "catalog: update owner/editor" on public.catalog_items for update to authenticated
  using (owner_id = (select auth.uid()) or public.is_team_editor(owner_id))
  with check (owner_id = (select auth.uid()) or public.is_team_editor(owner_id));

create policy "catalog: delete owner/editor" on public.catalog_items for delete to authenticated
  using (owner_id = (select auth.uid()) or public.is_team_editor(owner_id));

revoke all on public.catalog_items from anon, authenticated;
grant select, delete on public.catalog_items to authenticated;
grant insert (id, owner_id, name, standard, unit, price, stock, visible) on public.catalog_items to authenticated;
grant update (name, standard, unit, price, stock, visible) on public.catalog_items to authenticated;

-- Импорт прайса одним запросом.
-- Совпадение ищется по «наименование + стандарт» (без учёта регистра и пробелов по краям):
-- совпавшие позиции обновляются, новые добавляются, остальные не трогаются.
-- Если в файле нет колонки (единица / остаток / видимость) — у существующих позиций она не меняется.
create or replace function public.import_catalog(p_owner uuid, p_rows jsonb)
returns table (inserted int, updated int)
language plpgsql security definer set search_path = '' as $$
declare v_ins int; v_upd int;
begin
  if auth.uid() is null or not (auth.uid() = p_owner or public.is_team_editor(p_owner)) then
    raise exception 'Нет прав на изменение каталога';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then
    raise exception 'Можно загрузить не больше 2000 строк за раз';
  end if;

  with raw as (
    select btrim(r ->> 'name')                          as name,
           coalesce(btrim(r ->> 'standard'), '')        as standard,
           nullif(btrim(r ->> 'unit'), '')              as unit,
           (r ->> 'price')::numeric                     as price,
           (r ->> 'stock')::numeric                     as stock,
           (r ->> 'visible')::boolean                   as visible,
           n
    from jsonb_array_elements(p_rows) with ordinality as t(r, n)
  ),
  src as (   -- если строка повторяется в файле, берём последнюю
    select distinct on (lower(name), lower(standard)) * from raw
    where name <> '' and price is not null
    order by lower(name), lower(standard), n desc
  ),
  upd as (
    update public.catalog_items c set
      unit    = coalesce(s.unit, c.unit),
      price   = s.price,
      stock   = coalesce(s.stock, c.stock),
      visible = coalesce(s.visible, c.visible)
    from src s
    where c.owner_id = p_owner
      and lower(btrim(c.name)) = lower(s.name)
      and lower(btrim(c.standard)) = lower(s.standard)
    returning c.id
  ),
  ins as (
    insert into public.catalog_items (owner_id, name, standard, unit, price, stock, visible)
    select p_owner, s.name, s.standard, coalesce(s.unit, 'т'), s.price, coalesce(s.stock, 0), coalesce(s.visible, true)
    from src s
    where not exists (
      select 1 from public.catalog_items c
      where c.owner_id = p_owner
        and lower(btrim(c.name)) = lower(s.name)
        and lower(btrim(c.standard)) = lower(s.standard))
    returning id
  )
  select (select count(*) from ins), (select count(*) from upd) into v_ins, v_upd;

  return query select v_ins, v_upd;
end;
$$;

revoke all on function public.import_catalog(uuid, jsonb) from public;
grant execute on function public.import_catalog(uuid, jsonb) to authenticated;
