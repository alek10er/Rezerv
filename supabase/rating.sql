-- =====================================================================
--  РЕЗЕРВ — рейтинг надёжности поставщика
--  Выполнить ПОСЛЕ schema.sql, company.sql и team.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Сейчас рейтинг считается по отзывам покупателей (supplier_reviews).
--  Писать отзывы с сайта пока нельзя — таблица и расчёт подготовлены заранее,
--  отзывы можно добавить вручную (см. rating-demo.sql).
--  Скорость ответа и отказы после согласования появятся, когда в базе будут
--  запросы и заказы — функция уже возвращает для них поля (пока NULL).
-- =====================================================================

-- 1. Отзывы покупателей о поставщике
create table if not exists public.supplier_reviews (
  id            uuid primary key default gen_random_uuid(),
  supplier_id   uuid not null references public.profiles (id) on delete cascade,
  buyer_id      uuid references public.profiles (id) on delete set null,
  buyer_company text not null default '' check (char_length(buyer_company) <= 200),  -- как покупатель назывался на момент отзыва
  order_ref     text not null default '' check (char_length(order_ref) <= 60),       -- номер заказа, к которому отзыв (на будущее)
  rating        numeric(2, 1) not null check (rating between 1 and 5 and rating * 2 = round(rating * 2)),  -- 1…5 с шагом 0,5
  on_time       boolean,          -- поставка в срок? (NULL — не оценивалось)
  quality_ok    boolean,          -- качество без замечаний? false = рекламация
  comment       text not null default '' check (char_length(comment) <= 2000),
  created_at    timestamptz not null default now()
);
create index if not exists supplier_reviews_supplier_idx on public.supplier_reviews (supplier_id, created_at desc);
-- Один отзыв от покупателя на один заказ
create unique index if not exists supplier_reviews_one_per_order
  on public.supplier_reviews (supplier_id, buyer_id, order_ref) where buyer_id is not null and order_ref <> '';

-- RLS: отзывы видят все вошедшие пользователи (покупатели сравнивают поставщиков).
-- Создавать и менять отзывы с сайта пока нельзя — только через SQL / будущую функцию.
alter table public.supplier_reviews enable row level security;
drop policy if exists "reviews: read" on public.supplier_reviews;
create policy "reviews: read" on public.supplier_reviews for select to authenticated using (true);
revoke all on public.supplier_reviews from anon, authenticated;
grant select on public.supplier_reviews to authenticated;

-- 2. Рейтинг поставщика одним запросом
create or replace function public.get_supplier_rating(p_supplier uuid)
returns table (
  reviews           int,       -- всего отзывов
  rating            numeric,   -- индекс надёжности = средняя оценка (NULL, если отзывов нет)
  on_time_yes       int,       -- поставок в срок (из последних 20 оценённых)
  on_time_total     int,
  quality_yes       int,       -- без замечаний по качеству (из последних 20 оценённых)
  quality_total     int,
  complaints_6m     int,       -- рекламаций за 6 месяцев
  top_pct           int,       -- в какой верхний % поставщиков входит (NULL, если поставщиков с отзывами < 5)
  suppliers_rated   int,       -- сколько поставщиков вообще имеют отзывы
  response_median_min int,     -- медиана скорости ответа на запросы, мин (появится с запросами)
  refusals_6m       int        -- отказов после согласования за 6 мес. (появится с заказами)
)
language sql stable security definer set search_path = '' as $$
  with mine as (
    select * from public.supplier_reviews where supplier_id = p_supplier
  ),
  t as (select on_time from mine where on_time is not null order by created_at desc limit 20),
  q as (select quality_ok from mine where quality_ok is not null order by created_at desc limit 20),
  avgs as (
    select supplier_id, avg(rating) as a from public.supplier_reviews group by supplier_id
  ),
  me as (select a from avgs where supplier_id = p_supplier)
  select
    (select count(*) from mine)::int,
    (select round(avg(rating), 1) from mine),
    (select count(*) filter (where on_time) from t)::int,
    (select count(*) from t)::int,
    (select count(*) filter (where quality_ok) from q)::int,
    (select count(*) from q)::int,
    (select count(*) from mine where quality_ok = false and created_at > now() - interval '6 months')::int,
    case when (select count(*) from avgs) >= 5 and exists (select 1 from me) then
      greatest(1, ceil(100.0 * (1 + (select count(*) from avgs where a > (select a from me))) / (select count(*) from avgs)))::int
    end,
    (select count(*) from avgs)::int,
    null::int,
    null::int;
$$;

revoke all on function public.get_supplier_rating(uuid) from public;
grant execute on function public.get_supplier_rating(uuid) to authenticated;
