-- =====================================================================
--  РЕЗЕРВ — формат цен и количеств в уведомлениях: «54 500 ₽/т» вместо «54500 ₽/т»
--  Выполнить один раз: SQL Editor → New query → Run (повторный запуск безопасен)
--  (в notifications.sql функция уже новая — для новых баз этот файл не нужен)
-- =====================================================================

-- 1. Новые уведомления: разряды через неразрывный пробел, дробь через запятую
create or replace function public.fmt_qty(v numeric) returns text language sql immutable set search_path = '' as $$
  select case when v is null then '' else
    (case when v < 0 then '-' else '' end)
    || regexp_replace(split_part(trim_scale(abs(v))::text, '.', 1), '(\d)(?=(\d{3})+$)', '\1' || chr(160), 'g')
    || coalesce(',' || nullif(split_part(trim_scale(abs(v))::text, '.', 2), ''), '')
  end;
$$;

-- 2. Уже созданные уведомления: разбиваем на разряды цены перед « ₽»
--    (номера заказов вроде ЗК-2026-00006 не трогаем — после них нет « ₽»)
update public.notifications
set title = regexp_replace(title, '(\d)(?=(\d{3})+([.]\d+)? ₽)', '\1' || chr(160), 'g'),
    body  = regexp_replace(body,  '(\d)(?=(\d{3})+([.]\d+)? ₽)', '\1' || chr(160), 'g')
where title ~ '\d{4,}([.]\d+)? ₽' or body ~ '\d{4,}([.]\d+)? ₽';

-- Проверка: должно показать цены с пробелами
select title, body from public.notifications order by created_at desc limit 5;
