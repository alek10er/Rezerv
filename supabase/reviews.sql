-- =====================================================================
--  РЕЗЕРВ — отзывы покупателей после поставки
--  Выполнить ПОСЛЕ rating.sql, orders.sql и notifications.sql:
--  SQL Editor → New query → Run (повторный запуск безопасен)
--
--  Отзыв можно оставить только по своему заказу в статусе «получен» (delivered),
--  один раз на заказ. Отзыв сразу учитывается в рейтинге поставщика,
--  поставщик получает уведомление (триггер из notifications.sql).
-- =====================================================================

-- Связь отзыва с заказом и отметка в заказе
alter table public.supplier_reviews add column if not exists order_id uuid references public.orders (id) on delete set null;
create unique index if not exists supplier_reviews_one_per_order_id on public.supplier_reviews (order_id) where order_id is not null;
alter table public.orders add column if not exists reviewed_at timestamptz;

create or replace function public.review_create(
  p_order uuid, p_rating numeric, p_on_time boolean, p_quality_ok boolean, p_comment text default ''
) returns public.supplier_reviews language plpgsql security definer set search_path = '' as $$
declare o public.orders; r public.supplier_reviews;
begin
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Заказ не найден'; end if;
  if auth.uid() is null or not public.can_act_party(o.buyer_id) then raise exception 'Оставить отзыв может только покупатель по своему заказу'; end if;
  if o.status <> 'delivered' then raise exception 'Отзыв можно оставить после подтверждения получения'; end if;
  if o.reviewed_at is not null or exists (select 1 from public.supplier_reviews where order_id = o.id) then
    raise exception 'Отзыв по этому заказу уже оставлен';
  end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 or p_rating * 2 <> round(p_rating * 2) then
    raise exception 'Оценка — от 1 до 5';
  end if;

  insert into public.supplier_reviews (supplier_id, buyer_id, buyer_company, order_ref, order_id, rating, on_time, quality_ok, comment)
  values (o.supplier_id, o.buyer_id, o.buyer_company, o.number, o.id, p_rating, p_on_time, p_quality_ok, left(coalesce(btrim(p_comment), ''), 2000))
  returning * into r;

  update public.orders set reviewed_at = now() where id = o.id;
  insert into public.order_messages (order_id, side, author_id, kind, body)
  values (o.id, 'system', auth.uid(), 'system', 'Покупатель оставил отзыв: ★ ' || trim_scale(p_rating)::text);
  return r;
end;
$$;

revoke all on function public.review_create(uuid, numeric, boolean, boolean, text) from public;
grant execute on function public.review_create(uuid, numeric, boolean, boolean, text) to authenticated;
