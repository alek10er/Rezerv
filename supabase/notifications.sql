-- =====================================================================
--  РЕЗЕРВ — уведомления
--  Выполнить ПОСЛЕ orders.sql и rating.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Уведомления создаются триггерами — при событиях по заказам и новых отзывах.
--  Адресат — кабинет (owner_id): их видит владелец и его команда.
--  «Прочитано» хранится для каждого пользователя отдельно (notification_seen).
--  Какие виды показывать — личная настройка пользователя (profiles.notify_prefs).
-- =====================================================================

create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles (id) on delete cascade,  -- кабинет-адресат
  kind       text not null check (kind in ('order_new', 'order_offer', 'order_message', 'order_accepted',
                                            'order_rejected', 'order_cancelled', 'order_shipped', 'order_arrived',
                                            'order_received', 'review_new')),
  title      text not null,
  body       text not null default '',
  order_id   uuid references public.orders (id) on delete cascade,
  actor_id   uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists notifications_owner_idx on public.notifications (owner_id, created_at desc);

create table if not exists public.notification_seen (
  user_id  uuid not null references public.profiles (id) on delete cascade,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  seen_at  timestamptz not null default now(),
  primary key (user_id, owner_id)
);

-- Личные настройки: какие виды уведомлений показывать ({"order_new": false, ...}; нет ключа = показывать)
alter table public.profiles add column if not exists notify_prefs jsonb not null default '{}'::jsonb;
grant update (notify_prefs) on public.profiles to authenticated;

-- RLS
alter table public.notifications enable row level security;
alter table public.notification_seen enable row level security;
drop policy if exists "notifications: read" on public.notifications;
create policy "notifications: read" on public.notifications for select to authenticated
  using (public.can_view_party(owner_id));
drop policy if exists "notification_seen: read own" on public.notification_seen;
create policy "notification_seen: read own" on public.notification_seen for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.notifications, public.notification_seen from anon, authenticated;
grant select on public.notifications, public.notification_seen to authenticated;

-- Отметить уведомления кабинета прочитанными
create or replace function public.notifications_mark_seen(p_owner uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not public.can_view_party(p_owner) then raise exception 'Нет доступа'; end if;
  insert into public.notification_seen (user_id, owner_id, seen_at) values (auth.uid(), p_owner, now())
  on conflict (user_id, owner_id) do update set seen_at = now();
end;
$$;

-- Внутренняя функция создания уведомления (не доступна с сайта)
create or replace function public.notify(p_owner uuid, p_kind text, p_title text, p_body text, p_order uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (owner_id, kind, title, body, order_id, actor_id)
  values (p_owner, p_kind, left(p_title, 200), left(coalesce(p_body, ''), 300), p_order, auth.uid());
$$;

-- Число по-русски: разряды через неразрывный пробел, дробная часть через запятую (54500.5 → «54 500,5»)
create or replace function public.fmt_qty(v numeric) returns text language sql immutable set search_path = '' as $$
  select case when v is null then '' else
    (case when v < 0 then '-' else '' end)
    || regexp_replace(split_part(trim_scale(abs(v))::text, '.', 1), '(\d)(?=(\d{3})+$)', '\1' || chr(160), 'g')
    || coalesce(',' || nullif(split_part(trim_scale(abs(v))::text, '.', 2), ''), '')
  end;
$$;

-- Триггер: новый заказ и смена статуса
create or replace function public.tg_orders_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
declare what text := new.item_name || ' · ' || public.fmt_qty(new.qty) || ' ' || new.unit;
begin
  if tg_op = 'INSERT' then
    perform public.notify(new.supplier_id, 'order_new', 'Новый заказ ' || new.number,
                          new.buyer_company || ' · ' || what || ' · ' || public.fmt_qty(new.price) || ' ₽/' || new.unit, new.id);
    return new;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'confirmed' then
      -- принял тот, чей был ход: уведомляем другую сторону
      perform public.notify(case when new.turn = 'supplier' then new.buyer_id else new.supplier_id end, 'order_accepted',
                            'Цена согласована · ' || new.number, what || ' · ' || public.fmt_qty(new.price) || ' ₽/' || new.unit, new.id);
    elsif new.status = 'rejected' then
      perform public.notify(new.buyer_id, 'order_rejected', 'Поставщик отказался от заказа ' || new.number, new.supplier_company || ' · ' || what, new.id);
    elsif new.status = 'cancelled' then
      perform public.notify(new.supplier_id, 'order_cancelled', 'Покупатель отменил заказ ' || new.number, new.buyer_company || ' · ' || what, new.id);
    elsif new.status = 'shipped' then
      perform public.notify(new.buyer_id, 'order_shipped', 'Заказ ' || new.number || ' отгружен', new.supplier_company || ' · ' || what, new.id);
    elsif new.status = 'arrived' then
      perform public.notify(new.buyer_id, 'order_arrived', 'Заказ ' || new.number || ' доставлен — подтвердите получение', new.supplier_company || ' · ' || what, new.id);
    elsif new.status = 'delivered' then
      perform public.notify(new.supplier_id, 'order_received', 'Покупатель подтвердил получение ' || new.number, new.buyer_company || ' · ' || what, new.id);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_notify on public.orders;
create trigger orders_notify after insert or update of status on public.orders
  for each row execute function public.tg_orders_notify();

-- Триггер: предложения и сообщения в переговорах
create or replace function public.tg_order_messages_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
declare o public.orders; target uuid; who text;
begin
  if new.side = 'system' then return new; end if;
  select * into o from public.orders where id = new.order_id;
  -- первое предложение покупателя уже покрыто уведомлением «Новый заказ»
  if new.kind = 'offer' and (select count(*) from public.order_messages where order_id = new.order_id) = 1 then return new; end if;
  target := case when new.side = 'buyer' then o.supplier_id else o.buyer_id end;
  who    := case when new.side = 'buyer' then o.buyer_company else o.supplier_company end;
  if new.kind = 'offer' then
    perform public.notify(target, 'order_offer', 'Встречное предложение · ' || o.number,
                          who || ' предлагает ' || public.fmt_qty(new.price) || ' ₽/' || o.unit || ' · ' || o.item_name, o.id);
  else
    perform public.notify(target, 'order_message', 'Сообщение по заказу ' || o.number, who || ': ' || left(new.body, 160), o.id);
  end if;
  return new;
end;
$$;
drop trigger if exists order_messages_notify on public.order_messages;
create trigger order_messages_notify after insert on public.order_messages
  for each row execute function public.tg_order_messages_notify();

-- Триггер: новый отзыв о поставщике
create or replace function public.tg_reviews_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.notify(new.supplier_id, 'review_new', 'Новый отзыв ★ ' || public.fmt_qty(new.rating),
                        coalesce(nullif(new.buyer_company, ''), 'Покупатель') || case when new.comment <> '' then ': ' || left(new.comment, 160) else '' end, null);
  return new;
end;
$$;
drop trigger if exists supplier_reviews_notify on public.supplier_reviews;
create trigger supplier_reviews_notify after insert on public.supplier_reviews
  for each row execute function public.tg_reviews_notify();

revoke all on function public.notify(uuid, text, text, text, uuid) from public;
revoke all on function public.notifications_mark_seen(uuid) from public;
grant execute on function public.notifications_mark_seen(uuid) to authenticated;
