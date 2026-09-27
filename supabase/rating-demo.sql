-- =====================================================================
--  РЕЗЕРВ — тестовые отзывы, чтобы увидеть рейтинг в работе
--  Замените email на адрес аккаунта ПОСТАВЩИКА и выполните в SQL Editor.
--  Удалить тестовые отзывы: см. последнюю строку.
-- =====================================================================

insert into public.supplier_reviews (supplier_id, buyer_company, order_ref, rating, on_time, quality_ok, comment, created_at)
select p.id, v.buyer, v.ord, v.rating, v.on_time, v.quality_ok, v.comment, now() - v.ago
from public.profiles p
cross join (values
  ('ООО «Завод»',       'DEMO-1', 5.0, true,  true,  'Отгрузили на день раньше, сертификаты пришли вместе с УПД.', interval '6 days'),
  ('ООО «ТехноПласт»',  'DEMO-2', 4.5, true,  true,  'Цена чуть выше рынка, но стабильно в срок.',                  interval '13 days'),
  ('АО «Ковров-Маш»',   'DEMO-3', 4.0, true,  false, 'Одна позиция пришла с отклонением по толщине, заменили за 2 дня.', interval '25 days'),
  ('ООО «Волга-Агрегат»','DEMO-4', 4.5, false, true,  'Задержка на сутки, но предупредили заранее.',                  interval '40 days')
) as v(buyer, ord, rating, on_time, quality_ok, comment, ago)
where p.email = 'ПОСТАВЩИК@example.com';

-- Удалить тестовые отзывы:
-- delete from public.supplier_reviews where order_ref like 'DEMO-%';
