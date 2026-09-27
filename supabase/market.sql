-- =====================================================================
--  РЕЗЕРВ — сравнение цен поставщика с рынком
--  Выполнить ПОСЛЕ catalog.sql, rating.sql и orders.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Похожие позиции ищутся по сходству названий (pg_trgm) с той же единицей
--  измерения. Если совпадает стандарт (ГОСТ/ТУ), порог сходства ниже.
--  В сравнении участвуют только видимые позиции других поставщиков.
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

-- Похожи ли две позиции
create or replace function public.market_match(a_name text, a_std text, a_unit text, b_name text, b_std text, b_unit text)
returns boolean language sql immutable set search_path = '' as $$
  select lower(btrim(a_unit)) = lower(btrim(b_unit))
     and (extensions.similarity(lower(a_name), lower(b_name)) >= 0.5
          or (btrim(a_std) <> '' and lower(btrim(a_std)) = lower(btrim(b_std))
              and extensions.similarity(lower(a_name), lower(b_name)) >= 0.3));
$$;

-- 1. Сводка по каждой позиции каталога поставщика p_supplier
create or replace function public.market_compare(p_supplier uuid)
returns table (
  item_id uuid, name text, standard text, unit text, price numeric, stock numeric, visible boolean,
  offers int, min_price numeric, avg_price numeric, max_price numeric,
  cheaper int, market_stock numeric
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.name, c.standard, c.unit, c.price, c.stock, c.visible,
         count(o.id)::int,
         min(o.price), round(avg(o.price), 2), max(o.price),
         (count(o.id) filter (where o.price < c.price))::int,
         coalesce(sum(o.stock), 0)
  from public.catalog_items c
  left join public.catalog_items o
    on o.owner_id <> c.owner_id and o.visible
   and public.market_match(c.name, c.standard, c.unit, o.name, o.standard, o.unit)
   and exists (select 1 from public.profiles p where p.id = o.owner_id and p.role = 'sell')
  where c.owner_id = p_supplier
    and ((select auth.uid()) = p_supplier or public.is_team_member(p_supplier))
  group by c.id
  order by c.name;
$$;

-- 2. Все предложения рынка по одной позиции каталога (включая саму позицию)
create or replace function public.market_offers(p_item uuid)
returns table (
  item_id uuid, is_mine boolean, supplier_company text, name text, standard text, unit text,
  price numeric, stock numeric, rating numeric, reviews int
)
language sql stable security definer set search_path = '' as $$
  with me as (
    select * from public.catalog_items
    where id = p_item and ((select auth.uid()) = owner_id or public.is_team_member(owner_id))
  )
  select o.id, o.owner_id = me.owner_id,
         coalesce(nullif(p.company, ''), p.full_name), o.name, o.standard, o.unit, o.price, o.stock,
         r.avg_rating, coalesce(r.n, 0)::int
  from me
  join public.catalog_items o
    on o.id = me.id
    or (o.owner_id <> me.owner_id and o.visible
        and public.market_match(me.name, me.standard, me.unit, o.name, o.standard, o.unit))
  join public.profiles p on p.id = o.owner_id and p.role = 'sell'
  cross join lateral (
    select round(avg(sr.rating), 1) as avg_rating, count(*) as n
    from public.supplier_reviews sr where sr.supplier_id = o.owner_id
  ) r
  order by o.price, o.name
  limit 100;
$$;

-- 3. Поиск по рынку: видимые позиции всех поставщиков
create or replace function public.market_search(p_query text)
returns table (
  item_id uuid, supplier_id uuid, supplier_company text, name text, standard text, unit text,
  price numeric, stock numeric, rating numeric, reviews int
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.owner_id, coalesce(nullif(p.company, ''), p.full_name), o.name, o.standard, o.unit,
         o.price, o.stock, r.avg_rating, coalesce(r.n, 0)::int
  from public.catalog_items o
  join public.profiles p on p.id = o.owner_id and p.role = 'sell'
  cross join lateral (
    select round(avg(sr.rating), 1) as avg_rating, count(*) as n
    from public.supplier_reviews sr where sr.supplier_id = o.owner_id
  ) r
  where (select auth.uid()) is not null
    and o.visible
    and char_length(btrim(p_query)) >= 2
    and (lower(o.name || ' ' || o.standard) like '%' || lower(btrim(p_query)) || '%'
         or extensions.similarity(lower(o.name), lower(btrim(p_query))) >= 0.3)
  order by extensions.similarity(lower(o.name), lower(btrim(p_query))) desc, o.price
  limit 50;
$$;

revoke all on function public.market_match(text, text, text, text, text, text) from public;
revoke all on function public.market_compare(uuid) from public;
revoke all on function public.market_offers(uuid)  from public;
revoke all on function public.market_search(text)  from public;
grant execute on function public.market_match(text, text, text, text, text, text) to authenticated;
grant execute on function public.market_compare(uuid) to authenticated;
grant execute on function public.market_offers(uuid)  to authenticated;
grant execute on function public.market_search(text)  to authenticated;
