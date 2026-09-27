# РЕЗЕРВ — прототип ИИ-платформы закупок

Сайт для покупателей и поставщиков: каталог и прайс, заказы и переговоры, склад с прогнозом,
рейтинг, команды, уведомления и ИИ-агенты на Gemini, которые торгуются за обе стороны.

- **Фронтенд** — статические страницы в `site/` без сборки: React подключён как готовый файл, логика прямо в HTML.
- **Бэкенд** — Supabase: база, вход, RLS и Edge Functions для ИИ-агентов.

```
site/                  ← всё, что публикуется (корень сайта на Vercel)
  index.html           лендинг
  cabinet.html         личный кабинет (/cabinet)
  privacy.html         политика конфиденциальности (/privacy)
  config.js            адрес проекта Supabase и публичный anon-ключ
  assets/              скрипты, шрифты, React
  vendor/              supabase-js и SheetJS (копии из node_modules)
supabase/              SQL для базы, шаблоны писем, Edge Functions
  functions/seller-agent/   ИИ-агент поставщика
  functions/buyer-agent/    ИИ-агент покупателя
design/                исходные макеты (на сайт не попадают)
server.js              локальный сервер для разработки
vercel.json            настройки хостинга
```

## Запуск локально

```bash
npm start
```

Откройте http://localhost:3000 (кабинет — http://localhost:3000/cabinet). Node.js 18+; `npm install` для запуска не нужен.

## Публикация на Vercel

1. Загрузите репозиторий на GitHub.
2. На [vercel.com/new](https://vercel.com/new) нажмите **Import** у этого репозитория.
3. Настройки менять не нужно: всё уже указано в `vercel.json`. Сайт отдаётся из папки `site`, сборки нет. Нажмите **Deploy**.
4. **Обязательно** после первого деплоя укажите адрес сайта в Supabase. Иначе ссылки из писем (подтверждение почты, сброс пароля) будут вести на localhost.
   - Supabase Dashboard → **Authentication → URL Configuration**
   - **Site URL:** `https://ваш-проект.vercel.app`
   - **Redirect URLs:** добавьте `https://ваш-проект.vercel.app/**`. Если подключите свой домен, добавьте и его.

Дальше каждый `git push` в `main` публикуется автоматически.

## Настройка Supabase (для нового проекта)

1. В `site/config.js` укажите `SUPABASE_URL` и `SUPABASE_ANON_KEY` (Project Settings → API).
   Anon-ключ публичный, его можно хранить в репозитории.
2. **SQL Editor** — выполните файлы из `supabase/` по порядку:

   | # | Файл | Что создаёт |
   |---|------|-------------|
   | 1 | `schema.sql` | профили, вход |
   | 2 | `company.sql` | реквизиты компании |
   | 3 | `team.sql` | команды и приглашения |
   | 4 | `catalog.sql` | каталог и прайс |
   | 5 | `rating.sql` | рейтинг поставщиков |
   | 6 | `suppliers.sql` | белый список / блокировка |
   | 7 | `orders.sql` | заказы и переговоры |
   | 8 | `market.sql` | сравнение цен |
   | 9 | `notifications.sql` | уведомления |
   | 10 | `reviews.sql` | отзывы |
   | 11 | `stock.sql` | склад и прогноз |
   | 12 | `agent.sql` | ИИ-агент поставщика |
   | 13 | `ai-keys.sql` | свой ключ Gemini кабинета |
   | 14 | `buyer-agent.sql` | ИИ-агент покупателя |
   | — | `number-format.sql` | разовая правка старых уведомлений (для новой базы не нужна) |
   | — | `rating-demo.sql` | демо-отзывы (необязательно) |

   В `agent.sql` и `buyer-agent.sql` прописан адрес проекта и anon-ключ для вызова функций из базы.
   Для другого проекта Supabase замените их.
3. **Edge Functions** — создайте две функции с именами `seller-agent` и `buyer-agent`.
   В каждую вставьте код из `supabase/functions/<имя>/index.ts`. Проверку JWT оставьте включённой.
4. **Edge Functions → Secrets:**
   - `GEMINI_API_KEY` — ключ платформы для поставщиков;
   - `GEMINI_API_KEY_BUYER` — ключ платформы для покупателей. Если его нет, берётся `GEMINI_API_KEY`;
   - `GEMINI_MODEL` — необязательно, по умолчанию `gemini-2.5-flash`.

   Секреты храните только в Supabase, **не в репозитории**.
5. **Письма:** шаблоны лежат в `supabase/templates/`. Их нужно вставить в Authentication → Email Templates.
   SMTP настраивается в Authentication → SMTP Settings.

## Обновление библиотек

supabase-js и SheetJS лежат в `site/vendor/`, чтобы сайт работал без сборки. Чтобы обновить их:

```bash
npm install
npm run vendor
```

После этого закоммитьте изменения в `site/vendor/`.
