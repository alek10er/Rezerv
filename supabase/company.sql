-- =====================================================================
--  РЕЗЕРВ — реквизиты компании в профиле
--  Выполнить один раз ПОСЛЕ schema.sql: SQL Editor → New query → Run
--  (скрипт можно запускать повторно — он ничего не сломает)
-- =====================================================================

alter table public.profiles
  add column if not exists inn               text not null default '',
  add column if not exists kpp               text not null default '',
  add column if not exists ogrn              text not null default '',
  add column if not exists legal_address     text not null default '',
  add column if not exists warehouse_address text not null default '',
  add column if not exists phone             text not null default '',
  add column if not exists categories        text not null default '';

comment on column public.profiles.inn               is 'ИНН: 10 цифр (юрлицо) или 12 (ИП)';
comment on column public.profiles.kpp               is 'КПП: 9 символов, только для юрлиц';
comment on column public.profiles.ogrn              is 'ОГРН (13 цифр) или ОГРНИП (15 цифр)';
comment on column public.profiles.warehouse_address is 'Адрес склада (покупатель) или отгрузки (поставщик)';
comment on column public.profiles.categories        is 'Категории товаров поставщика';

-- Проверка формата на стороне БД (пустое значение допустимо)
alter table public.profiles drop constraint if exists profiles_inn_format;
alter table public.profiles drop constraint if exists profiles_kpp_format;
alter table public.profiles drop constraint if exists profiles_ogrn_format;
alter table public.profiles drop constraint if exists profiles_text_length;

alter table public.profiles
  add constraint profiles_inn_format  check (inn  ~ '^([0-9]{10}|[0-9]{12})?$'),
  add constraint profiles_kpp_format  check (kpp  ~ '^([0-9]{4}[0-9A-Z]{2}[0-9]{3})?$'),
  add constraint profiles_ogrn_format check (ogrn ~ '^([0-9]{13}|[0-9]{15})?$'),
  add constraint profiles_text_length check (
    char_length(full_name) <= 200 and char_length(company) <= 200 and
    char_length(legal_address) <= 300 and char_length(warehouse_address) <= 300 and
    char_length(phone) <= 30 and char_length(categories) <= 300
  );

-- Пользователь может менять имя и реквизиты компании (но не роль и не email)
revoke update on public.profiles from authenticated;
grant update (full_name, company, inn, kpp, ogrn, legal_address, warehouse_address, phone, categories)
  on public.profiles to authenticated;
