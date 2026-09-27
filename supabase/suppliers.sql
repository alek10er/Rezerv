-- =====================================================================
--  РЕЗЕРВ — поставщики для покупателя
--  Выполнить ПОСЛЕ schema.sql, company.sql, team.sql, catalog.sql и rating.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Покупатель видит поставщиков (role = 'sell'), у которых есть хотя бы одна
--  видимая позиция в наличии. Белый список и блокировка хранятся для кабинета
--  покупателя (общие для его команды).
-- =====================================================================

-- 1. Отметки покупателя: белый список / блокировка
create table if not exists public.buyer_suppliers (
  buyer_id    uuid not null references public.profiles (id) on delete cascade,
  supplier_id uuid not null references public.profiles (id) on delete cascade,
  whitelisted boolean not null default false,
  blocked     boolean not null default false,
  updated_at  timestamptz not null default now(),
  primary key (buyer_id, supplier_id),
  check (not (whitelisted and blocked)),
  check (buyer_id <> supplier_id)
);

alter table public.buyer_suppliers enable row level security;
drop policy if exists "buyer_suppliers: read" on public.buyer_suppliers;
create policy "buyer_suppliers: read" on public.buyer_suppliers for select to authenticated
  using (buyer_id = (select auth.uid()) or public.is_team_member(buyer_id));
revoke all on public.buyer_suppliers from anon, authenticated;
grant select on public.buyer_suppliers to authenticated;
-- Изменения — только через set_supplier_mark (владелец кабинета или менеджер команды)

-- 2. Список поставщиков для кабинета покупателя p_buyer
create or replace function public.list_suppliers(p_buyer uuid)
returns table (
  id uuid, company text, full_name text, categories text, warehouse_address text, inn text,
  items_visible int, items_in_stock int,
  rating numeric, reviews int, on_time_pct int,
  whitelisted boolean, blocked boolean
)
language sql stable security definer set search_path = '' as $$
  select p.id, p.company, p.full_name, p.categories, p.warehouse_address, p.inn,
         c.visible_n::int, c.stock_n::int,
         r.avg_rating, coalesce(r.n, 0)::int, r.on_time_pct,
         coalesce(m.whitelisted, false), coalesce(m.blocked, false)
  from public.profiles p
  cross join lateral (
    select count(*) filter (where ci.visible)                  as visible_n,
           count(*) filter (where ci.visible and ci.stock > 0) as stock_n
    from public.catalog_items ci where ci.owner_id = p.id
  ) c
  cross join lateral (
    select round(avg(sr.rating), 1) as avg_rating,
           count(*)                 as n,
           round(100.0 * count(*) filter (where sr.on_time)
                 / nullif(count(*) filter (where sr.on_time is not null), 0))::int as on_time_pct
    from public.supplier_reviews sr where sr.supplier_id = p.id
  ) r
  left join public.buyer_suppliers m on m.buyer_id = p_buyer and m.supplier_id = p.id
  where p.role = 'sell'
    and c.stock_n > 0
    and p.id <> p_buyer
    and ((select auth.uid()) = p_buyer or public.is_team_member(p_buyer))
  order by coalesce(m.blocked, false), coalesce(m.whitelisted, false) desc,
           r.avg_rating desc nulls last, p.company;
$$;

-- 3. Поставить / снять отметку
create or replace function public.set_supplier_mark(p_buyer uuid, p_supplier uuid, p_whitelisted boolean, p_blocked boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not (auth.uid() = p_buyer or public.is_team_editor(p_buyer)) then
    raise exception 'Нет прав на изменение списка поставщиков';
  end if;
  if not exists (select 1 from public.profiles where id = p_supplier and role = 'sell') then
    raise exception 'Поставщик не найден';
  end if;
  if p_whitelisted and p_blocked then
    raise exception 'Поставщик не может быть одновременно в белом списке и заблокирован';
  end if;
  insert into public.buyer_suppliers (buyer_id, supplier_id, whitelisted, blocked, updated_at)
  values (p_buyer, p_supplier, p_whitelisted, p_blocked, now())
  on conflict (buyer_id, supplier_id)
  do update set whitelisted = excluded.whitelisted, blocked = excluded.blocked, updated_at = now();
end;
$$;

revoke all on function public.list_suppliers(uuid)                             from public;
revoke all on function public.set_supplier_mark(uuid, uuid, boolean, boolean) from public;
grant execute on function public.list_suppliers(uuid)                             to authenticated;
grant execute on function public.set_supplier_mark(uuid, uuid, boolean, boolean) to authenticated;
