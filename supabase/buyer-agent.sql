-- =====================================================================
--  РЕЗЕРВ — ИИ-агент покупателя (Gemini, отдельная функция buyer-agent)
--  Выполнить ПОСЛЕ agent.sql и stock.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Агент покупателя:
--    • подсказывает ответ поставщику в переговорах (кнопка «Подсказка ИИ»);
--    • при включённом автоторге сам отвечает на встречные цены поставщиков —
--      принимает или торгуется, но никогда не соглашается дороже потолка
--      из правил (проверяется здесь, в базе);
--    • разбирает позицию склада и советует, когда и сколько заказать.
--  Автоторг запускается триггером: база вызывает Edge Function buyer-agent
--  через pg_net, когда ход в переговорах переходит к покупателю.
-- =====================================================================

create extension if not exists pg_net;

-- 1. Правила агента покупателя
create table if not exists public.buyer_agent (
  owner_id     uuid primary key references public.profiles (id) on delete cascade,
  auto_reply   boolean not null default false,
  target_disc  numeric(5, 2) not null default 5 check (target_disc between 0 and 50),  -- к какой скидке от прайса стремиться, %
  min_disc     numeric(5, 2) not null default 0 check (min_disc between 0 and 50),     -- ниже этой скидки не соглашаться (0 = можно по прайсу)
  max_rounds   int not null default 3 check (max_rounds between 1 and 10),
  tone         text not null default 'business' check (tone in ('business', 'friendly', 'short')),
  instructions text not null default '' check (char_length(instructions) <= 1500),
  updated_at   timestamptz not null default now()
);
drop trigger if exists buyer_agent_touch_updated_at on public.buyer_agent;
create trigger buyer_agent_touch_updated_at before update on public.buyer_agent
  for each row execute function public.touch_updated_at();

alter table public.buyer_agent enable row level security;
drop policy if exists "buyer_agent: read"   on public.buyer_agent;
drop policy if exists "buyer_agent: insert" on public.buyer_agent;
drop policy if exists "buyer_agent: update" on public.buyer_agent;
create policy "buyer_agent: read"   on public.buyer_agent for select to authenticated using (public.can_view_party(owner_id));
create policy "buyer_agent: insert" on public.buyer_agent for insert to authenticated with check (public.can_act_party(owner_id));
create policy "buyer_agent: update" on public.buyer_agent for update to authenticated using (public.can_act_party(owner_id)) with check (public.can_act_party(owner_id));
revoke all on public.buyer_agent from anon, authenticated;
grant select on public.buyer_agent to authenticated;
grant insert (owner_id, auto_reply, target_disc, min_disc, max_rounds, tone, instructions) on public.buyer_agent to authenticated;
grant update (owner_id, auto_reply, target_disc, min_disc, max_rounds, tone, instructions) on public.buyer_agent to authenticated;

-- Потолок цены: дороже агент покупателя не согласится
create or replace function public.buyer_ceiling(o public.orders, a public.buyer_agent)
returns numeric language sql immutable set search_path = '' as $$
  select round(o.list_price * (1 - coalesce(a.min_disc, 0) / 100), 2);
$$;

-- Склад покупателя по позиции заказа: остаток, расход в день, на сколько дней хватит
create or replace function public.buyer_stock_for(p_buyer uuid, p_name text, p_unit text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('name', s.name, 'unit', s.unit, 'stock', s.stock, 'lead_days', s.lead_days, 'safety_days', s.safety_days,
           'daily_use', u.use, 'days_left', case when u.use > 0 then round(s.stock / u.use, 1) end)
  from public.stock_items s
  cross join lateral (
    select case when s.use_mode = 'manual' then s.daily_use
                else coalesce(nullif((select sum(m.qty) from public.stock_moves m
                                      where m.item_id = s.id and m.kind = 'use' and m.created_at > now() - interval '30 days'), 0) / 30,
                              s.daily_use) end as use
  ) u
  where s.owner_id = p_buyer
    and (lower(btrim(s.name)) = lower(btrim(p_name)) or public.market_match(s.name, '', s.unit, p_name, '', p_unit))
  order by (lower(btrim(s.name)) = lower(btrim(p_name))) desc, extensions.similarity(lower(s.name), lower(p_name)) desc
  limit 1;
$$;

-- 2. Всё, что агенту покупателя нужно знать о заказе
create or replace function public.buyer_agent_context(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.orders; a public.buyer_agent; res jsonb;
begin
  select * into o from public.orders where id = p_order;
  if not found then raise exception 'Заказ не найден'; end if;
  if auth.uid() is not null and not public.can_view_party(o.buyer_id) then raise exception 'Нет доступа к этому заказу'; end if;
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Нет доступа'; end if;
  select * into a from public.buyer_agent where owner_id = o.buyer_id;

  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'turn', o.turn,
       'item', o.item_name, 'standard', o.item_standard, 'unit', o.unit, 'qty', o.qty,
       'list_price', o.list_price, 'price', o.price, 'pay_terms', o.pay_terms, 'due_date', o.due_date,
       'buyer_company', o.buyer_company, 'supplier_company', o.supplier_company,
       'buyer_id', o.buyer_id, 'supplier_id', o.supplier_id, 'created_at', o.created_at),
    'rules', jsonb_build_object('auto_reply', coalesce(a.auto_reply, false), 'target_disc', coalesce(a.target_disc, 5),
       'min_disc', coalesce(a.min_disc, 0), 'max_rounds', coalesce(a.max_rounds, 3),
       'tone', coalesce(a.tone, 'business'), 'instructions', coalesce(a.instructions, '')),
    'ceiling', public.buyer_ceiling(o, a),
    'target', round(o.list_price * (1 - coalesce(a.target_disc, 5) / 100), 2),
    'messages', coalesce((select jsonb_agg(jsonb_build_object('side', m.side, 'kind', m.kind, 'price', m.price,
                                  'body', m.body, 'by_agent', m.by_agent, 'at', m.created_at) order by m.created_at)
                          from (select * from public.order_messages where order_id = o.id order by created_at desc limit 30) m), '[]'::jsonb),
    'agent_offers', (select count(*) from public.order_messages where order_id = o.id and by_agent and side = 'buyer' and kind = 'offer'),
    'agent_today', (select count(*) from public.order_messages m join public.orders x on x.id = m.order_id
                    where x.buyer_id = o.buyer_id and m.by_agent and m.side in ('buyer', 'system') and m.created_at > now() - interval '1 day'),
    'supplier', (select jsonb_build_object('rating', round(avg(r.rating), 1), 'reviews', count(*),
                        'on_time_pct', round(100.0 * count(*) filter (where r.on_time) / nullif(count(*) filter (where r.on_time is not null), 0)))
                 from public.supplier_reviews r where r.supplier_id = o.supplier_id),
    'history', (select jsonb_build_object('deals', count(*), 'total', coalesce(sum(qty * price), 0),
                       'avg_disc_pct', coalesce(round(avg(case when list_price > 0 then (1 - price / list_price) * 100 end), 1), 0))
                from public.orders where buyer_id = o.buyer_id and supplier_id = o.supplier_id and status = 'delivered'),
    'market', (select jsonb_build_object('offers', count(*), 'min', min(x.price), 'avg', round(avg(x.price), 2), 'max', max(x.price))
               from public.catalog_items x
               join public.profiles p on p.id = x.owner_id and p.role = 'sell'
               where x.owner_id <> o.supplier_id and x.visible and x.stock > 0
                 and public.market_match(o.item_name, o.item_standard, o.unit, x.name, x.standard, x.unit)),
    'stock', public.buyer_stock_for(o.buyer_id, o.item_name, o.unit)
  ) into res;
  return res;
end;
$$;

-- 3. Действие агента покупателя (только для Edge Function с ключом сервиса)
--    accept  — принять цену поставщика (если она не выше потолка)
--    counter — своя цена (не выше потолка и ниже текущей цены поставщика)
create or replace function public.order_buyer_agent_action(p_order uuid, p_action text, p_price numeric default null, p_text text default '')
returns public.orders language plpgsql security definer set search_path = '' as $$
declare o public.orders; a public.buyer_agent; v_ceiling numeric; txt text := left(coalesce(btrim(p_text), ''), 2000);
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Заказ не найден'; end if;
  select * into a from public.buyer_agent where owner_id = o.buyer_id;
  if not coalesce(a.auto_reply, false) then raise exception 'Автоторг выключен'; end if;
  if o.status <> 'negotiation' or o.turn <> 'buyer' then raise exception 'Сейчас не ход покупателя'; end if;
  v_ceiling := public.buyer_ceiling(o, a);

  if p_action = 'accept' then
    if o.price > v_ceiling then raise exception 'Цена выше потолка по правилам'; end if;
    if txt <> '' then
      insert into public.order_messages (order_id, side, kind, body, by_agent) values (o.id, 'buyer', 'text', txt, true);
    end if;
    update public.orders set status = 'confirmed', confirmed_at = now(), updated_at = now() where id = o.id;
    update public.catalog_items set stock = greatest(0, stock - o.qty) where id = o.catalog_item_id;
    insert into public.order_messages (order_id, side, kind, price, body, by_agent)
    values (o.id, 'system', 'system', o.price, 'Цена согласована (ИИ-агент покупателя)', true);

  elsif p_action = 'counter' then
    if p_price is null or p_price < 0 then raise exception 'Укажите цену'; end if;
    if p_price > v_ceiling then raise exception 'Цена выше потолка по правилам'; end if;
    if p_price >= o.price then raise exception 'Встречная цена должна быть ниже цены поставщика'; end if;
    update public.orders set price = round(p_price, 2), turn = 'supplier', updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, kind, price, body, by_agent)
    values (o.id, 'buyer', 'offer', round(p_price, 2), txt, true);
  else
    raise exception 'Неизвестное действие агента';
  end if;

  select * into o from public.orders where id = p_order;
  return o;
end;
$$;

-- 4. Разбор позиции склада для кнопки «Прогноз ИИ-агента»
create or replace function public.buyer_stock_context(p_item uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare it public.stock_items; res jsonb;
begin
  select * into it from public.stock_items where id = p_item;
  if not found then raise exception 'Позиция не найдена'; end if;
  if auth.uid() is null or not public.can_view_party(it.owner_id) then raise exception 'Нет доступа к этой позиции'; end if;
  select jsonb_build_object(
    'item', jsonb_build_object('id', it.id, 'owner_id', it.owner_id, 'name', it.name, 'sku', it.sku, 'unit', it.unit, 'stock', it.stock,
             'lead_days', it.lead_days, 'safety_days', it.safety_days, 'max_stock', it.max_stock, 'use_mode', it.use_mode, 'daily_use', it.daily_use),
    'moves', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'use', u, 'in', i) order by d)
                       from (select created_at::date d, sum(qty) filter (where kind = 'use') u, sum(qty) filter (where kind = 'in') i
                             from public.stock_moves where item_id = it.id and created_at > now() - interval '90 days'
                             group by 1) t), '[]'::jsonb),
    'open_orders', coalesce((select jsonb_agg(jsonb_build_object('number', o.number, 'status', o.status, 'qty', o.qty, 'price', o.price,
                                   'supplier', o.supplier_company, 'due_date', o.due_date))
                             from public.orders o
                             where o.buyer_id = it.owner_id and o.status in ('negotiation', 'confirmed', 'shipped', 'arrived')
                               and (lower(btrim(o.item_name)) = lower(btrim(it.name)) or public.market_match(it.name, '', it.unit, o.item_name, '', o.unit))), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(x) from (
                 select jsonb_build_object('supplier', coalesce(nullif(p.company, ''), p.full_name), 'item', c.name, 'standard', c.standard,
                          'price', c.price, 'stock', c.stock,
                          'rating', (select round(avg(r.rating), 1) from public.supplier_reviews r where r.supplier_id = c.owner_id)) x
                 from public.catalog_items c
                 join public.profiles p on p.id = c.owner_id and p.role = 'sell'
                 where c.visible and c.stock > 0 and c.owner_id <> it.owner_id
                   and not exists (select 1 from public.buyer_suppliers b where b.buyer_id = it.owner_id and b.supplier_id = c.owner_id and b.blocked)
                   and public.market_match(it.name, '', it.unit, c.name, c.standard, c.unit)
                 order by c.price limit 8) q), '[]'::jsonb)
  ) into res;
  return res;
end;
$$;

-- 5. Автоторг: ход перешёл к покупателю → база вызывает Edge Function buyer-agent
create or replace function public.tg_orders_buyer_agent_hook()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'negotiation' and new.turn = 'buyer'
     and (old.turn is distinct from new.turn or old.status is distinct from new.status)
     and exists (select 1 from public.buyer_agent where owner_id = new.buyer_id and auto_reply) then
    perform net.http_post(
      url     := 'https://kkoyzpebwwvyafbfsupo.supabase.co/functions/v1/buyer-agent',
      body    := jsonb_build_object('action', 'auto', 'order_id', new.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        -- публичный anon-ключ (тот же, что в site/config.js): функция сама проверяет, можно ли отвечать
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imtrb3l6cGVid3d2eWFmYmZzdXBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA0OTA5OTEsImV4cCI6MjEwNjA2Njk5MX0.U4QY-IT_Si1Buu1OYCIsdT_51AdXrODFL5V8Q8tkIZI'),
      timeout_milliseconds := 30000);
  end if;
  return new;
end;
$$;
drop trigger if exists orders_buyer_agent_hook on public.orders;
create trigger orders_buyer_agent_hook after update of turn, status on public.orders
  for each row execute function public.tg_orders_buyer_agent_hook();

revoke all on function public.buyer_ceiling(public.orders, public.buyer_agent) from public;
revoke all on function public.buyer_stock_for(uuid, text, text) from public, anon, authenticated;
revoke all on function public.buyer_agent_context(uuid) from public, anon;
revoke all on function public.order_buyer_agent_action(uuid, text, numeric, text) from public, anon, authenticated;
revoke all on function public.buyer_stock_context(uuid) from public, anon;
grant execute on function public.buyer_agent_context(uuid) to authenticated, service_role;
grant execute on function public.order_buyer_agent_action(uuid, text, numeric, text) to service_role;
grant execute on function public.buyer_stock_context(uuid) to authenticated;
