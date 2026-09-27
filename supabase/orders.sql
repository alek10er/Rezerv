-- =====================================================================
--  РЕЗЕРВ — заказы и переговоры по ним
--  Выполнить ПОСЛЕ schema.sql, company.sql, team.sql, catalog.sql,
--  rating.sql и suppliers.sql:  SQL Editor → New query → Run
--  (повторный запуск безопасен)
--
--  Жизненный цикл заказа:
--    negotiation → confirmed → shipped → arrived → delivered
--      торг        согласован  отгружен   доставлен   получен покупателем (заказ закрыт)
--    shipped и arrived отмечает поставщик, delivered — только покупатель
--         ↘ rejected (поставщик отказался)   ↘ cancelled (покупатель отменил до отгрузки)
--  В переговорах стороны ходят по очереди (turn): принять цену или предложить свою.
--  Все переходы — только через функции order_* (права проверяются в базе).
-- =====================================================================

create sequence if not exists public.orders_number_seq;

-- 1. Заказы
create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  number           text not null unique
                   default ('ЗК-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('public.orders_number_seq')::text, 5, '0')),
  buyer_id         uuid not null references public.profiles (id) on delete cascade,
  supplier_id      uuid not null references public.profiles (id) on delete cascade,
  buyer_company    text not null default '',   -- название сторон на момент заказа
  supplier_company text not null default '',
  catalog_item_id  uuid references public.catalog_items (id) on delete set null,
  item_name        text not null,
  item_standard    text not null default '',
  unit             text not null default 'т',
  qty              numeric(14, 3) not null check (qty > 0),
  list_price       numeric(14, 2) not null check (list_price >= 0),  -- цена в прайсе на момент заказа
  price            numeric(14, 2) not null check (price >= 0),       -- текущая предложенная / согласованная цена за единицу
  pay_terms        text not null default 'Предоплата' check (char_length(pay_terms) <= 40),
  due_date         date,                                              -- желаемая дата поставки
  status           text not null default 'negotiation'
                   check (status in ('negotiation', 'confirmed', 'shipped', 'arrived', 'delivered', 'rejected', 'cancelled')),
  turn             text not null default 'supplier' check (turn in ('buyer', 'supplier')),  -- чей ход в переговорах
  created_by       uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  confirmed_at     timestamptz,
  shipped_at       timestamptz,
  arrived_at       timestamptz,
  delivered_at     timestamptz,
  check (buyer_id <> supplier_id)
);
-- Для базы, где таблица уже создана прошлой версией скрипта: новый статус «arrived»
alter table public.orders add column if not exists arrived_at timestamptz;
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('negotiation', 'confirmed', 'shipped', 'arrived', 'delivered', 'rejected', 'cancelled'));

create index if not exists orders_buyer_idx    on public.orders (buyer_id, updated_at desc);
create index if not exists orders_supplier_idx on public.orders (supplier_id, updated_at desc);

-- 2. Сообщения переговоров
create table if not exists public.order_messages (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders (id) on delete cascade,
  side        text not null check (side in ('buyer', 'supplier', 'system')),
  author_id   uuid references public.profiles (id) on delete set null,
  kind        text not null default 'text' check (kind in ('offer', 'text', 'system')),
  price       numeric(14, 2),
  body        text not null default '' check (char_length(body) <= 2000),
  created_at  timestamptz not null default now()
);
create index if not exists order_messages_order_idx on public.order_messages (order_id, created_at);

-- 3. Права: участник стороны = владелец кабинета или член его команды
create or replace function public.can_view_party(p_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() = p_owner or public.is_team_member(p_owner);
$$;
create or replace function public.can_act_party(p_owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() = p_owner or public.is_team_editor(p_owner);
$$;

alter table public.orders enable row level security;
alter table public.order_messages enable row level security;

drop policy if exists "orders: parties read" on public.orders;
create policy "orders: parties read" on public.orders for select to authenticated
  using (public.can_view_party(buyer_id) or public.can_view_party(supplier_id));

drop policy if exists "order_messages: parties read" on public.order_messages;
create policy "order_messages: parties read" on public.order_messages for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                 and (public.can_view_party(o.buyer_id) or public.can_view_party(o.supplier_id))));

revoke all on public.orders, public.order_messages from anon, authenticated;
grant select on public.orders, public.order_messages to authenticated;
-- Изменения — только через функции ниже

-- 4. Создать заказ по позиции каталога (сторона покупателя)
create or replace function public.order_create(
  p_buyer uuid, p_item uuid, p_qty numeric, p_price numeric,
  p_pay text default 'Предоплата', p_due date default null, p_comment text default ''
) returns uuid language plpgsql security definer set search_path = '' as $$
declare it public.catalog_items; b public.profiles; s public.profiles; v_id uuid;
begin
  if auth.uid() is null or not public.can_act_party(p_buyer) then
    raise exception 'Нет прав оформлять заказы от этого кабинета';
  end if;
  select * into b from public.profiles where id = p_buyer;
  if b.role <> 'buy' then raise exception 'Заказывать может только кабинет покупателя'; end if;
  select * into it from public.catalog_items where id = p_item and visible;
  if not found then raise exception 'Позиция не найдена или скрыта поставщиком'; end if;
  select * into s from public.profiles where id = it.owner_id;
  if s.role <> 'sell' or s.id = p_buyer then raise exception 'Нельзя заказать у этого поставщика'; end if;
  if exists (select 1 from public.buyer_suppliers where buyer_id = p_buyer and supplier_id = s.id and blocked) then
    raise exception 'Поставщик заблокирован в вашем кабинете';
  end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Количество должно быть больше нуля'; end if;
  if p_price is null or p_price < 0 then raise exception 'Цена не может быть отрицательной'; end if;

  insert into public.orders (buyer_id, supplier_id, buyer_company, supplier_company, catalog_item_id,
                             item_name, item_standard, unit, qty, list_price, price, pay_terms, due_date,
                             status, turn, created_by)
  values (p_buyer, s.id, coalesce(nullif(b.company, ''), b.full_name), coalesce(nullif(s.company, ''), s.full_name), it.id,
          it.name, it.standard, it.unit, p_qty, it.price, p_price, coalesce(nullif(btrim(p_pay), ''), 'Предоплата'), p_due,
          'negotiation', 'supplier', auth.uid())
  returning id into v_id;

  insert into public.order_messages (order_id, side, author_id, kind, price, body)
  values (v_id, 'buyer', auth.uid(), 'offer', p_price, coalesce(btrim(p_comment), ''));
  return v_id;
end;
$$;

-- 5. Действие по заказу. p_side — от чьего имени ('buyer' / 'supplier').
--    message  — сообщение в переговорах (пока заказ не закрыт)
--    counter  — встречная цена (в переговорах, в свой ход)
--    accept   — принять цену другой стороны (в переговорах, в свой ход) → confirmed
--    reject   — поставщик отказывается (в переговорах)
--    cancel   — покупатель отменяет (до отгрузки)
--    ship     — поставщик подтверждает отгрузку (confirmed → shipped)
--    arrive   — поставщик подтверждает доставку до пункта (shipped → arrived)
--    deliver  — покупатель подтверждает получение (arrived → delivered)
create or replace function public.order_action(
  p_order uuid, p_side text, p_action text, p_price numeric default null, p_text text default ''
) returns public.orders language plpgsql security definer set search_path = '' as $$
declare o public.orders; other text; txt text := coalesce(btrim(p_text), '');
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Заказ не найден'; end if;
  if p_side not in ('buyer', 'supplier') then raise exception 'Неизвестная сторона'; end if;
  if auth.uid() is null or not public.can_act_party(case when p_side = 'buyer' then o.buyer_id else o.supplier_id end) then
    raise exception 'Нет прав действовать по этому заказу';
  end if;
  other := case when p_side = 'buyer' then 'supplier' else 'buyer' end;

  if p_action = 'message' then
    if txt = '' then raise exception 'Пустое сообщение'; end if;
    if o.status in ('delivered', 'rejected', 'cancelled') then raise exception 'Заказ закрыт — переписка завершена'; end if;
    insert into public.order_messages (order_id, side, author_id, kind, body) values (o.id, p_side, auth.uid(), 'text', txt);

  elsif p_action = 'counter' then
    if o.status <> 'negotiation' then raise exception 'Торг возможен только в переговорах'; end if;
    if o.turn <> p_side then raise exception 'Сейчас ход другой стороны'; end if;
    if p_price is null or p_price < 0 then raise exception 'Укажите цену'; end if;
    update public.orders set price = p_price, turn = other, updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, author_id, kind, price, body) values (o.id, p_side, auth.uid(), 'offer', p_price, txt);

  elsif p_action = 'accept' then
    if o.status <> 'negotiation' then raise exception 'Заказ уже не в переговорах'; end if;
    if o.turn <> p_side then raise exception 'Сейчас ход другой стороны'; end if;
    update public.orders set status = 'confirmed', confirmed_at = now(), updated_at = now() where id = o.id;
    -- резервируем количество в каталоге поставщика
    update public.catalog_items set stock = greatest(0, stock - o.qty) where id = o.catalog_item_id;
    insert into public.order_messages (order_id, side, author_id, kind, price, body)
    values (o.id, 'system', auth.uid(), 'system', o.price, 'Цена согласована');

  elsif p_action = 'reject' then
    if p_side <> 'supplier' then raise exception 'Отказаться может только поставщик'; end if;
    if o.status <> 'negotiation' then raise exception 'Отказаться можно только в переговорах'; end if;
    update public.orders set status = 'rejected', updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, author_id, kind, body)
    values (o.id, 'system', auth.uid(), 'system', 'Поставщик отказался от заказа' || case when txt <> '' then ': ' || txt else '' end);

  elsif p_action = 'cancel' then
    if p_side <> 'buyer' then raise exception 'Отменить может только покупатель'; end if;
    if o.status not in ('negotiation', 'confirmed') then raise exception 'Отменить можно только до отгрузки'; end if;
    update public.orders set status = 'cancelled', updated_at = now() where id = o.id;
    if o.status = 'confirmed' then  -- возвращаем зарезервированное количество
      update public.catalog_items set stock = stock + o.qty where id = o.catalog_item_id;
    end if;
    insert into public.order_messages (order_id, side, author_id, kind, body)
    values (o.id, 'system', auth.uid(), 'system', 'Покупатель отменил заказ' || case when txt <> '' then ': ' || txt else '' end);

  elsif p_action = 'ship' then
    if p_side <> 'supplier' then raise exception 'Отгрузку отмечает поставщик'; end if;
    if o.status <> 'confirmed' then raise exception 'Отгрузить можно только подтверждённый заказ'; end if;
    update public.orders set status = 'shipped', shipped_at = now(), updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, author_id, kind, body)
    values (o.id, 'system', auth.uid(), 'system', 'Заказ отгружен' || case when txt <> '' then ': ' || txt else '' end);

  elsif p_action = 'arrive' then
    if p_side <> 'supplier' then raise exception 'Доставку отмечает поставщик'; end if;
    if o.status <> 'shipped' then raise exception 'Отметить доставку можно после отгрузки'; end if;
    update public.orders set status = 'arrived', arrived_at = now(), updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, author_id, kind, body)
    values (o.id, 'system', auth.uid(), 'system', 'Поставщик подтвердил доставку' || case when txt <> '' then ': ' || txt else '' end);

  elsif p_action = 'deliver' then
    if p_side <> 'buyer' then raise exception 'Получение подтверждает покупатель'; end if;
    if o.status <> 'arrived' then raise exception 'Подтвердить получение можно после того, как поставщик отметит доставку'; end if;
    update public.orders set status = 'delivered', delivered_at = now(), updated_at = now() where id = o.id;
    insert into public.order_messages (order_id, side, author_id, kind, body)
    values (o.id, 'system', auth.uid(), 'system', 'Покупатель подтвердил получение — заказ закрыт');

  else
    raise exception 'Неизвестное действие';
  end if;

  select * into o from public.orders where id = p_order;
  return o;
end;
$$;

revoke all on function public.can_view_party(uuid) from public;
revoke all on function public.can_act_party(uuid) from public;
revoke all on function public.order_create(uuid, uuid, numeric, numeric, text, date, text) from public;
revoke all on function public.order_action(uuid, text, text, numeric, text) from public;
grant execute on function public.can_view_party(uuid) to authenticated;
grant execute on function public.can_act_party(uuid) to authenticated;
grant execute on function public.order_create(uuid, uuid, numeric, numeric, text, date, text) to authenticated;
grant execute on function public.order_action(uuid, text, text, numeric, text) to authenticated;
