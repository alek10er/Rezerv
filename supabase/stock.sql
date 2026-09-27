-- =====================================================================
--  РЕЗЕРВ — склад покупателя: позиции, движения, автоприход по заказам
--  Выполнить ПОСЛЕ orders.sql и market.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Остаток меняется только через движения (stock_move): приход, расход,
--  инвентаризация — так у каждой цифры есть история.
--  Когда покупатель подтверждает получение заказа, остаток подходящей
--  позиции склада пополняется автоматически.
-- =====================================================================

create table if not exists public.stock_items (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 200),
  sku         text not null default '' check (char_length(sku) <= 60),          -- артикул / код
  unit        text not null default 'т' check (char_length(btrim(unit)) between 1 and 10),
  stock       numeric(14, 3) not null default 0 check (stock >= 0),            -- текущий остаток
  daily_use   numeric(14, 3) not null default 0 check (daily_use >= 0),        -- расход в день, если задан вручную
  use_mode    text not null default 'auto' check (use_mode in ('auto', 'manual')), -- auto = по списаниям за 30 дней
  lead_days   int not null default 7 check (lead_days between 0 and 365),      -- срок поставки
  safety_days int not null default 3 check (safety_days between 0 and 365),    -- страховой запас в днях
  max_stock   numeric(14, 3) not null default 0 check (max_stock >= 0),        -- целевой запас (0 = на 30 дней расхода)
  controlled  boolean not null default true,                                   -- на контроле (будущий агент)
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists stock_items_owner_idx on public.stock_items (owner_id, name);
create unique index if not exists stock_items_unique_name on public.stock_items (owner_id, lower(btrim(name)));

create table if not exists public.stock_moves (
  id         uuid primary key default gen_random_uuid(),
  item_id    uuid not null references public.stock_items (id) on delete cascade,
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  kind       text not null check (kind in ('in', 'use', 'set')),   -- приход / расход / инвентаризация
  qty        numeric(14, 3) not null check (qty >= 0),              -- для set — новый остаток
  before     numeric(14, 3) not null,
  after      numeric(14, 3) not null,
  note       text not null default '' check (char_length(note) <= 300),
  order_id   uuid references public.orders (id) on delete set null,
  author_id  uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists stock_moves_owner_idx on public.stock_moves (owner_id, created_at desc);
create index if not exists stock_moves_item_idx on public.stock_moves (item_id, created_at desc);

drop trigger if exists stock_items_touch_updated_at on public.stock_items;
create trigger stock_items_touch_updated_at before update on public.stock_items
  for each row execute function public.touch_updated_at();

-- RLS: видит кабинет и его команда, меняют владелец и менеджеры
alter table public.stock_items enable row level security;
alter table public.stock_moves enable row level security;
drop policy if exists "stock_items: read"   on public.stock_items;
drop policy if exists "stock_items: insert" on public.stock_items;
drop policy if exists "stock_items: update" on public.stock_items;
drop policy if exists "stock_items: delete" on public.stock_items;
create policy "stock_items: read"   on public.stock_items for select to authenticated using (public.can_view_party(owner_id));
create policy "stock_items: insert" on public.stock_items for insert to authenticated with check (public.can_act_party(owner_id));
create policy "stock_items: update" on public.stock_items for update to authenticated using (public.can_act_party(owner_id)) with check (public.can_act_party(owner_id));
create policy "stock_items: delete" on public.stock_items for delete to authenticated using (public.can_act_party(owner_id));
drop policy if exists "stock_moves: read" on public.stock_moves;
create policy "stock_moves: read" on public.stock_moves for select to authenticated using (public.can_view_party(owner_id));

revoke all on public.stock_items, public.stock_moves from anon, authenticated;
grant select, delete on public.stock_items to authenticated;
grant insert (owner_id, name, sku, unit, stock, daily_use, use_mode, lead_days, safety_days, max_stock, controlled) on public.stock_items to authenticated;
grant update (name, sku, unit, daily_use, use_mode, lead_days, safety_days, max_stock, controlled) on public.stock_items to authenticated;  -- остаток — только через stock_move
grant select on public.stock_moves to authenticated;

-- Начальный остаток при создании позиции попадает в журнал
create or replace function public.tg_stock_items_initial()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.stock > 0 then
    insert into public.stock_moves (item_id, owner_id, kind, qty, before, after, note, author_id)
    values (new.id, new.owner_id, 'set', new.stock, 0, new.stock, 'Начальный остаток', auth.uid());
  end if;
  return new;
end;
$$;
drop trigger if exists stock_items_initial on public.stock_items;
create trigger stock_items_initial after insert on public.stock_items
  for each row execute function public.tg_stock_items_initial();

-- Движение остатка: 'in' приход, 'use' расход, 'set' инвентаризация (qty = новый остаток)
create or replace function public.stock_move(p_item uuid, p_kind text, p_qty numeric, p_note text default '')
returns public.stock_items language plpgsql security definer set search_path = '' as $$
declare it public.stock_items; v_before numeric; v_after numeric;
begin
  select * into it from public.stock_items where id = p_item for update;
  if not found then raise exception 'Позиция не найдена'; end if;
  if auth.uid() is null or not public.can_act_party(it.owner_id) then raise exception 'Нет прав менять остатки'; end if;
  if p_qty is null or p_qty < 0 or (p_kind in ('in', 'use') and p_qty = 0) then raise exception 'Укажите количество больше нуля'; end if;
  v_before := it.stock;
  v_after := case p_kind when 'in' then v_before + p_qty when 'use' then v_before - p_qty when 'set' then p_qty end;
  if v_after is null then raise exception 'Неизвестный тип движения'; end if;
  if v_after < 0 then raise exception 'Нельзя списать больше остатка (%)', trim_scale(v_before); end if;
  update public.stock_items set stock = v_after where id = it.id returning * into it;
  insert into public.stock_moves (item_id, owner_id, kind, qty, before, after, note, author_id)
  values (it.id, it.owner_id, p_kind, p_qty, v_before, v_after, left(coalesce(btrim(p_note), ''), 300), auth.uid());
  return it;
end;
$$;

-- Автоприход: заказ получен → пополняем самую похожую позицию склада покупателя
create or replace function public.tg_orders_stock_in()
returns trigger language plpgsql security definer set search_path = '' as $$
declare it public.stock_items;
begin
  if new.status = 'delivered' and old.status is distinct from 'delivered' then
    select * into it from public.stock_items s
    where s.owner_id = new.buyer_id
      and (lower(btrim(s.name)) = lower(btrim(new.item_name))
           or public.market_match(s.name, '', s.unit, new.item_name, '', new.unit))
    order by (lower(btrim(s.name)) = lower(btrim(new.item_name))) desc,
             extensions.similarity(lower(s.name), lower(new.item_name)) desc
    limit 1
    for update;
    if found then
      update public.stock_items set stock = stock + new.qty where id = it.id;
      insert into public.stock_moves (item_id, owner_id, kind, qty, before, after, note, order_id, author_id)
      values (it.id, it.owner_id, 'in', new.qty, it.stock, it.stock + new.qty,
              'Получен заказ ' || new.number || ' · ' || new.supplier_company, new.id, auth.uid());
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_stock_in on public.orders;
create trigger orders_stock_in after update of status on public.orders
  for each row execute function public.tg_orders_stock_in();

revoke all on function public.stock_move(uuid, text, numeric, text) from public;
grant execute on function public.stock_move(uuid, text, numeric, text) to authenticated;

-- Загрузка остатков из Excel одним запросом.
-- Позиция ищется по артикулу (если указан), иначе по названию (без учёта регистра).
-- Существующие: остаток записывается как инвентаризация (если изменился), а ед./артикул/
-- расход/срок обновляются, только если колонка есть в файле. Новые — добавляются.
create or replace function public.import_stock(p_owner uuid, p_rows jsonb, p_file text default '')
returns table (inserted int, updated int, unchanged int)
language plpgsql security definer set search_path = '' as $$
declare r jsonb; it public.stock_items; v_stock numeric; v_use numeric; v_lead int; v_unit text; v_sku text;
        n_ins int := 0; n_upd int := 0; n_same int := 0; v_note text;
begin
  if auth.uid() is null or not public.can_act_party(p_owner) then raise exception 'Нет прав менять склад'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then raise exception 'Можно загрузить не больше 2000 строк за раз'; end if;
  v_note := 'Загрузка из Excel' || case when coalesce(p_file, '') <> '' then ': ' || left(p_file, 120) else '' end;

  for r in select * from jsonb_array_elements(p_rows) loop
    continue when coalesce(btrim(r ->> 'name'), '') = '' or (r ->> 'stock') is null;
    v_stock := (r ->> 'stock')::numeric;
    v_use   := (r ->> 'use')::numeric;
    v_lead  := (r ->> 'lead')::int;
    v_unit  := nullif(btrim(r ->> 'unit'), '');
    v_sku   := coalesce(btrim(r ->> 'sku'), '');
    it := null;
    if v_sku <> '' then
      select * into it from public.stock_items where owner_id = p_owner and lower(sku) = lower(v_sku) limit 1 for update;
    end if;
    if it.id is null then
      select * into it from public.stock_items where owner_id = p_owner and lower(btrim(name)) = lower(btrim(r ->> 'name')) limit 1 for update;
    end if;

    if it.id is null then
      insert into public.stock_items (owner_id, name, sku, unit, stock, daily_use, use_mode, lead_days)
      values (p_owner, left(btrim(r ->> 'name'), 200), left(v_sku, 60), coalesce(v_unit, 'т'), v_stock,
              coalesce(v_use, 0), case when v_use is not null then 'manual' else 'auto' end, coalesce(v_lead, 7));
      n_ins := n_ins + 1;
    else
      update public.stock_items set
        unit      = coalesce(v_unit, unit),
        sku       = case when v_sku <> '' then left(v_sku, 60) else sku end,
        daily_use = coalesce(v_use, daily_use),
        use_mode  = case when v_use is not null then 'manual' else use_mode end,
        lead_days = coalesce(v_lead, lead_days),
        stock     = v_stock
      where id = it.id;
      if it.stock is distinct from v_stock then
        insert into public.stock_moves (item_id, owner_id, kind, qty, before, after, note, author_id)
        values (it.id, it.owner_id, 'set', v_stock, it.stock, v_stock, v_note, auth.uid());
        n_upd := n_upd + 1;
      else
        n_same := n_same + 1;
      end if;
    end if;
  end loop;
  return query select n_ins, n_upd, n_same;
end;
$$;

revoke all on function public.import_stock(uuid, jsonb, text) from public;
grant execute on function public.import_stock(uuid, jsonb, text) to authenticated;
