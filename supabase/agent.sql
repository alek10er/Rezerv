-- =====================================================================
--  РЕЗЕРВ — ИИ-агент поставщика (Gemini)
--  Выполнить ПОСЛЕ orders.sql, market.sql, notifications.sql и stock.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Правила агента хранятся в seller_agent. Агент:
--    • подсказывает ответ в переговорах (кнопка «Подсказка ИИ»);
--    • при включённом автоответе сам отвечает покупателю — принимает цену
--      или делает встречное предложение, но никогда не опускается ниже
--      минимальной цены из правил (проверяется здесь, в базе).
--  Автоответ запускается триггером: база вызывает Edge Function
--  seller-agent через pg_net, когда ход переходит к поставщику.
-- =====================================================================

create extension if not exists pg_net;

-- 1. Правила агента поставщика
create table if not exists public.seller_agent (
  owner_id     uuid primary key references public.profiles (id) on delete cascade,
  auto_reply   boolean not null default false,
  max_disc     numeric(5, 2) not null default 5  check (max_disc between 0 and 50),   -- макс. скидка от прайса, %
  bulk_qty     numeric(14, 3) not null default 0 check (bulk_qty >= 0),              -- от какого объёма доп. скидка (0 = нет)
  bulk_disc    numeric(5, 2) not null default 0  check (bulk_disc between 0 and 30),  -- доп. скидка за объём, %
  max_rounds   int not null default 3 check (max_rounds between 1 and 10),            -- сколько раз агент торгуется, потом передаёт вам
  tone         text not null default 'business' check (tone in ('business', 'friendly', 'short')),
  instructions text not null default '' check (char_length(instructions) <= 1500),   -- свои указания агенту
  updated_at   timestamptz not null default now()
);
drop trigger if exists seller_agent_touch_updated_at on public.seller_agent;
create trigger seller_agent_touch_updated_at before update on public.seller_agent
  for each row execute function public.touch_updated_at();

alter table public.seller_agent enable row level security;
drop policy if exists "seller_agent: read"   on public.seller_agent;
drop policy if exists "seller_agent: insert" on public.seller_agent;
drop policy if exists "seller_agent: update" on public.seller_agent;
create policy "seller_agent: read"   on public.seller_agent for select to authenticated using (public.can_view_party(owner_id));
create policy "seller_agent: insert" on public.seller_agent for insert to authenticated with check (public.can_act_party(owner_id));
create policy "seller_agent: update" on public.seller_agent for update to authenticated using (public.can_act_party(owner_id)) with check (public.can_act_party(owner_id));
revoke all on public.seller_agent from anon, authenticated;
grant select on public.seller_agent to authenticated;
grant insert (owner_id, auto_reply, max_disc, bulk_qty, bulk_disc, max_rounds, tone, instructions) on public.seller_agent to authenticated;
grant update (owner_id, auto_reply, max_disc, bulk_qty, bulk_disc, max_rounds, tone, instructions) on public.seller_agent to authenticated;

-- 2. Сообщения, написанные агентом, помечаются
alter table public.order_messages add column if not exists by_agent boolean not null default false;

-- Минимальная цена, ниже которой агент не опускается
create or replace function public.agent_floor(o public.orders, a public.seller_agent)
returns numeric language sql immutable set search_path = '' as $$
  select round(o.list_price * (1 - (coalesce(a.max_disc, 5)
           + case when coalesce(a.bulk_qty, 0) > 0 and o.qty >= a.bulk_qty then coalesce(a.bulk_disc, 0) else 0 end) / 100), 2);
$$;

-- 3. Всё, что агенту нужно знать о заказе (одним JSON).
--    С сайта — участникам кабинета поставщика; Edge Function вызывает с ключом сервиса.
create or replace function public.agent_context(p_order uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.orders; a public.seller_agent; c public.catalog_items; res jsonb;
begin
  select * into o from public.orders where id = p_order;
  if not found then raise exception 'Заказ не найден'; end if;
  if auth.uid() is not null and not public.can_view_party(o.supplier_id) then raise exception 'Нет доступа к этому заказу'; end if;
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then raise exception 'Нет доступа'; end if;
  select * into a from public.seller_agent where owner_id = o.supplier_id;
  select * into c from public.catalog_items where id = o.catalog_item_id;

  select jsonb_build_object(
    'order', jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status, 'turn', o.turn,
       'item', o.item_name, 'standard', o.item_standard, 'unit', o.unit, 'qty', o.qty,
       'list_price', o.list_price, 'price', o.price, 'pay_terms', o.pay_terms, 'due_date', o.due_date,
       'buyer_company', o.buyer_company, 'supplier_company', o.supplier_company, 'supplier_id', o.supplier_id,
       'created_at', o.created_at),
    'rules', jsonb_build_object('auto_reply', coalesce(a.auto_reply, false), 'max_disc', coalesce(a.max_disc, 5),
       'bulk_qty', coalesce(a.bulk_qty, 0), 'bulk_disc', coalesce(a.bulk_disc, 0), 'max_rounds', coalesce(a.max_rounds, 3),
       'tone', coalesce(a.tone, 'business'), 'instructions', coalesce(a.instructions, '')),
    'floor', public.agent_floor(o, a),
    'stock', c.stock, 'visible', c.visible,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('side', m.side, 'kind', m.kind, 'price', m.price,
                                  'body', m.body, 'by_agent', m.by_agent, 'at', m.created_at) order by m.created_at)
                          from (select * from public.order_messages where order_id = o.id order by created_at desc limit 30) m), '[]'::jsonb),
    'agent_offers', (select count(*) from public.order_messages where order_id = o.id and by_agent and kind = 'offer'),
    'agent_today', (select count(*) from public.order_messages m join public.orders x on x.id = m.order_id
                    where x.supplier_id = o.supplier_id and m.by_agent and m.created_at > now() - interval '1 day'),
    'buyer_history', (select jsonb_build_object('deals', count(*), 'total', coalesce(sum(qty * price), 0),
                             'avg_disc_pct', coalesce(round(avg(case when list_price > 0 then (1 - price / list_price) * 100 end), 1), 0))
                      from public.orders where buyer_id = o.buyer_id and supplier_id = o.supplier_id and status = 'delivered'),
    'market', (select jsonb_build_object('offers', count(*), 'min', min(x.price), 'avg', round(avg(x.price), 2), 'max', max(x.price))
               from public.catalog_items x
               join public.profiles p on p.id = x.owner_id and p.role = 'sell'
               where x.owner_id <> o.supplier_id and x.visible and x.stock > 0
                 and public.market_match(o.item_name, o.item_standard, o.unit, x.name, x.standard, x.unit))
  ) into res;
  return res;
end;
$$;

-- 4. Действие агента по заказу (только для Edge Function с ключом сервиса).
--    accept  — принять текущую цену покупателя (если она не ниже минимальной)
--    counter — встречная цена (не ниже минимальной и не выше прайса)
create or replace function public.order_agent_action(p_order uuid, p_action text, p_price numeric default null, p_text text default '')
returns public.orders language plpgsql security definer set search_path = '' as $$
declare o public.orders; a public.seller_agent; v_floor numeric; txt text := left(coalesce(btrim(p_text), ''), 2000);
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Заказ не найден'; end if;
  select * into a from public.seller_agent where owner_id = o.supplier_id;
  if not coalesce(a.auto_reply, false) then raise exception 'Автоответ выключен'; end if;
  if o.status <> 'negotiation' or o.turn <> 'supplier' then raise exception 'Сейчас не ход поставщика'; end if;
  v_floor := public.agent_floor(o, a);

  if p_action = 'accept' then
    if o.price < v_floor then raise exception 'Цена ниже минимальной по правилам'; end if;
    if txt <> '' then
      insert into public.order_messages (order_id, side, kind, body, by_agent) values (o.id, 'supplier', 'text', txt, true);
    end if;
    update public.orders set status = 'confirmed', confirmed_at = now(), updated_at = now() where id = o.id;
    update public.catalog_items set stock = greatest(0, stock - o.qty) where id = o.catalog_item_id;
    insert into public.order_messages (order_id, side, kind, price, body, by_agent)
    values (o.id, 'system', 'system', o.price, 'Цена согласована (ИИ-агент поставщика)', true);

  elsif p_action = 'counter' then
    if p_price is null or p_price < v_floor then raise exception 'Цена ниже минимальной по правилам'; end if;
    if p_price > o.list_price then raise exception 'Цена выше прайса'; end if;
    update public.orders set price = round(p_price, 2), turn = 'buyer', updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, kind, price, body, by_agent)
    values (o.id, 'supplier', 'offer', round(p_price, 2), txt, true);
  else
    raise exception 'Неизвестное действие агента';
  end if;

  select * into o from public.orders where id = p_order;
  return o;
end;
$$;

-- 5. Автоответ: ход перешёл к поставщику → база вызывает Edge Function
create or replace function public.tg_orders_agent_hook()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'negotiation' and new.turn = 'supplier'
     and (tg_op = 'INSERT' or old.turn is distinct from new.turn or old.status is distinct from new.status)
     and exists (select 1 from public.seller_agent where owner_id = new.supplier_id and auto_reply) then
    perform net.http_post(
      url     := 'https://kkoyzpebwwvyafbfsupo.supabase.co/functions/v1/seller-agent',
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
drop trigger if exists orders_agent_hook on public.orders;
create trigger orders_agent_hook after insert or update of turn, status on public.orders
  for each row execute function public.tg_orders_agent_hook();

revoke all on function public.agent_floor(public.orders, public.seller_agent) from public;
revoke all on function public.agent_context(uuid) from public;
revoke all on function public.order_agent_action(uuid, text, numeric, text) from public;
grant execute on function public.agent_context(uuid) to authenticated, service_role;
grant execute on function public.order_agent_action(uuid, text, numeric, text) to service_role;
