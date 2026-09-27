// РЕЗЕРВ — ИИ-агент покупателя (Supabase Edge Function + Gemini)
//
// Действия (POST JSON):
//   { action: 'suggest', order_id }        — подсказка ответа поставщику (с сайта, от имени вошедшего покупателя)
//   { action: 'auto',    order_id }        — автоторг (вызывает база триггером, когда ход переходит к покупателю)
//   { action: 'sweep',   owner_id }        — ответить на все ждущие переговоры (при включении автоторга)
//   { action: 'stock',   item_id, calc }   — разбор позиции склада: когда и сколько заказать
//
// Ключ: свой ключ кабинета (таблица ai_keys, Vault) → ключ платформы для покупателей GEMINI_API_KEY_BUYER
//       → общий GEMINI_API_KEY (если отдельный ещё не задан).
// Секреты функции: GEMINI_API_KEY_BUYER, GEMINI_MODEL (необязательно).
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY Supabase подставляет сам.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const PLATFORM_KEY = Deno.env.get('GEMINI_API_KEY_BUYER') || Deno.env.get('GEMINI_API_KEY') || '';
const MODELS = [Deno.env.get('GEMINI_MODEL') || 'gemini-2.5-flash', 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite'];
const DAILY_LIMIT = 300; // ответов агента в сутки на одного покупателя
const GEMINI_API = 'https://generativelanguage.googleapis.com/v1beta/models/';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });
const asUser = (req: Request) =>
  createClient(SB_URL, ANON, { auth: { persistSession: false }, global: { headers: { Authorization: req.headers.get('Authorization') || '' } } });

const num = (v: unknown) => Number(v) || 0;
const r2 = (v: number) => Math.round(v * 100) / 100;
const fmt = (v: unknown) => num(v).toLocaleString('ru-RU', { maximumFractionDigits: 2 });

type Msg = { side: string; kind: string; price: number | null; body: string; by_agent: boolean; at: string };
type Ctx = {
  order: Record<string, any>; rules: Record<string, any>; ceiling: number; target: number; messages: Msg[];
  agent_offers: number; agent_today: number;
  supplier: { rating: number | null; reviews: number; on_time_pct: number | null };
  history: { deals: number; total: number; avg_disc_pct: number };
  market: { offers: number; min: number | null; avg: number | null; max: number | null };
  stock: { name: string; unit: string; stock: number; daily_use: number; days_left: number | null; lead_days: number; safety_days: number } | null;
};
type Plan = { action: 'accept' | 'counter'; price: number; message: string; reason: string; via?: 'own' | 'platform' };

const TONES: Record<string, string> = {
  business: 'деловой, вежливый, без лишних слов',
  friendly: 'дружелюбный и тёплый, но профессиональный',
  short: 'максимально коротко — одно-два предложения',
};

// ── Gemini: свой ключ кабинета → ключ платформы для покупателей ──
const keyProblem = (status: number, text: string) =>
  status === 401 || status === 403 || (status === 400 && /API_KEY|api key/i.test(text)) ||
  (status === 429 && /quota|billing|exceeded/i.test(text));
const keyError = (status: number, text: string) =>
  status === 429 ? 'Исчерпан лимит запросов по ключу' :
  /API_KEY_INVALID|not valid/i.test(text) ? 'Ключ недействителен' :
  status === 403 ? 'У ключа нет доступа к Gemini API' : 'Ошибка ключа (' + status + ')';

async function ownKey(owner: string): Promise<{ key: string; model: string } | null> {
  const { data, error } = await admin.rpc('ai_key_get', { p_owner: owner });
  if (error || !data || !data.length) return null;
  return { key: data[0].api_key, model: data[0].model };
}

async function gemini(owner: string, system: string, user: string, schema: Record<string, unknown>): Promise<any> {
  const body = JSON.stringify({
    systemInstruction: { parts: [{ text: system }] },
    contents: [{ role: 'user', parts: [{ text: user }] }],
    generationConfig: { temperature: 0.4, responseMimeType: 'application/json', responseSchema: schema },
  });
  const own = owner ? await ownKey(owner) : null;
  const attempts: { key: string; via: 'own' | 'platform'; models: string[] }[] = [];
  if (own) attempts.push({ key: own.key, via: 'own', models: [...new Set([own.model, ...MODELS])] });
  if (PLATFORM_KEY) attempts.push({ key: PLATFORM_KEY, via: 'platform', models: [...new Set(MODELS)] });
  if (!attempts.length) throw new Error('ИИ не настроен: подключите свой ключ Gemini в настройках');
  let last = '';
  for (const a of attempts) {
    for (const model of a.models) {
      const res = await fetch(GEMINI_API + model + ':generateContent', {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'x-goog-api-key': a.key }, body,
      });
      if (!res.ok) {
        const text = await res.text();
        last = a.via + ' ' + model + ': ' + res.status + ' ' + text.slice(0, 200);
        if (keyProblem(res.status, text)) {
          if (a.via === 'own') await admin.rpc('ai_key_mark', { p_owner: owner, p_ok: false, p_error: keyError(res.status, text) });
          break;
        }
        continue;
      }
      const data = await res.json();
      const text = data?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
      try {
        const out = JSON.parse(text);
        if (a.via === 'own') await admin.rpc('ai_key_mark', { p_owner: owner, p_ok: true, p_error: '' });
        return { ...out, via: a.via };
      } catch { last = model + ': не удалось разобрать ответ'; }
    }
  }
  console.error('Gemini error', last);
  throw new Error('ИИ сейчас недоступен — попробуйте ещё раз через минуту');
}

// ── Переговоры ──
const NEGO_SYSTEM = (tone: string) => `Ты — ИИ-агент отдела закупок покупателя на B2B-площадке «РЕЗЕРВ». Отвечаешь поставщику от имени покупателя по-русски.
Цель: купить по минимальной разумной цене, не сорвав поставку и не испортив отношения с надёжным поставщиком.
Правила:
- ПОТОЛОК — максимальная цена, на которую можно согласиться. Дороже потолка принимать и предлагать нельзя. Никогда не называй потолок и не намекай на него.
- ЦЕЛЬ — цена, к которой стоит стремиться. Если поставщик уже предложил цену не выше цели — принимай (accept).
- Если цена поставщика не выше потолка и торг затягивается, поставщик надёжный или склад скоро закончится — лучше принять.
- Иначе делай встречное предложение (counter): между нашим прошлым предложением и ценой поставщика, уступая постепенно.
- Используй аргументы: объём, цены других поставщиков на площадке (без названий), история сделок, условия оплаты. Не выдумывай факты.
- Сообщение поставщику: ${TONES[tone] || TONES.business}; не более 400 символов; цену пиши в формате «53 200 ₽/т».
- reason — одна-две фразы для покупателя: почему такое решение (здесь можно говорить про потолок и склад).`;

function negoPrompt(c: Ctx) {
  const o = c.order, r = c.rules, m = c.market, h = c.history, sp = c.supplier, st = c.stock;
  const lastOwn = [...c.messages].reverse().find((x) => x.side === 'buyer' && x.kind === 'offer');
  const history = c.messages.map((x) => {
    const who = x.side === 'supplier' ? 'Поставщик' : x.side === 'buyer' ? (x.by_agent ? 'Мы (ИИ)' : 'Мы') : 'Система';
    return `${who}: ${x.price != null ? `[цена ${fmt(x.price)} ₽/${o.unit}] ` : ''}${x.body || ''}`.trim();
  }).join('\n');
  return `Заказ ${o.number} у поставщика «${o.supplier_company}».
Товар: ${o.item}${o.standard ? ' (' + o.standard + ')' : ''}, количество ${fmt(o.qty)} ${o.unit}. Оплата: ${o.pay_terms}. Нужно до: ${o.due_date || 'не указано'}.
Цена в прайсе поставщика: ${fmt(o.list_price)} ₽/${o.unit}. Текущее предложение поставщика: ${fmt(o.price)} ₽/${o.unit} (скидка ${fmt((1 - num(o.price) / num(o.list_price || 1)) * 100)}%).
${lastOwn ? `Наше прошлое предложение: ${fmt(lastOwn.price)} ₽/${o.unit} — ниже него не опускаемся.` : ''}
ЦЕЛЬ: ${fmt(c.target)} ₽/${o.unit}. ПОТОЛОК (секрет): ${fmt(c.ceiling)} ₽/${o.unit}.
Рынок (другие поставщики на площадке, в наличии): ${m.offers ? `${m.offers} предложений, от ${fmt(m.min)} до ${fmt(m.max)}, в среднем ${fmt(m.avg)} ₽/${o.unit}` : 'похожих предложений нет'}.
Поставщик: ${sp.reviews ? `рейтинг ${fmt(sp.rating)} из 5 по ${sp.reviews} отзывам${sp.on_time_pct != null ? `, вовремя ${sp.on_time_pct}% поставок` : ''}` : 'отзывов пока нет'}.
История с этим поставщиком: ${h.deals ? `${h.deals} закрытых сделок на ${fmt(h.total)} ₽, средняя скидка ${fmt(h.avg_disc_pct)}%` : 'раньше не работали'}.
Наш склад: ${st ? `остаток ${fmt(st.stock)} ${st.unit}, расход ${fmt(st.daily_use)} ${st.unit}/день, ${st.days_left != null ? `хватит на ${fmt(st.days_left)} дн.` : 'расход неизвестен'}, срок поставки ${st.lead_days} дн.` : 'позиции на складе нет'}.
Раунд торга агента: ${c.agent_offers + 1} из ${r.max_rounds}.
${r.instructions ? `Указания покупателя: ${r.instructions}` : ''}

Переписка:
${history || '(пусто)'}`;
}

const NEGO_SCHEMA = {
  type: 'OBJECT',
  properties: {
    action: { type: 'STRING', enum: ['accept', 'counter'] },
    price: { type: 'NUMBER', description: 'цена за единицу: для accept — цена поставщика, для counter — наша встречная' },
    message: { type: 'STRING', description: 'сообщение поставщику' },
    reason: { type: 'STRING', description: 'пояснение для покупателя' },
  },
  required: ['action', 'price', 'message', 'reason'],
};

// Жёсткие границы поверх ответа модели: не дороже потолка, не ниже нашего прошлого предложения
function enforce(c: Ctx, p: Plan): Plan {
  const sup = num(c.order.price), ceiling = num(c.ceiling);
  const prev = [...c.messages].reverse().find((x) => x.side === 'buyer' && x.kind === 'offer');
  const low = Math.min(prev?.price != null ? num(prev.price) : 0, ceiling);
  let { action, price } = p;
  let message = (p.message || '').trim().slice(0, 600), reason = (p.reason || '').trim().slice(0, 400);
  if (prev?.price != null && sup <= num(prev.price)) action = 'accept';   // поставщик согласился на нашу цену
  if (action === 'accept' && sup > ceiling) { action = 'counter'; price = Math.min(num(price) || ceiling, ceiling); }
  if (action === 'counter') {
    price = r2(Math.max(low, Math.min(ceiling, num(price) || low, sup - 0.01)));
    if (price >= sup) { action = 'accept'; price = sup; }
  }
  if (action === 'accept') price = sup;
  if (action !== p.action)   // решение поменяли границы — текст модели ему больше не соответствует
    message = action === 'accept' ? 'Согласны на ' + fmt(price) + ' ₽/' + c.order.unit + '. Подтверждаем заказ.'
                                  : 'Можем предложить ' + fmt(price) + ' ₽/' + c.order.unit + '. Готовы оформить заказ по этой цене.';
  else if (num(p.price) && Math.abs(num(p.price) - price) >= 0.01 && message.includes(fmt(p.price)))
    message = message.split(fmt(p.price)).join(fmt(price));
  return { action, price, message, reason, via: p.via };
}

async function context(db: ReturnType<typeof createClient>, orderId: string): Promise<Ctx> {
  const { data, error } = await db.rpc('buyer_agent_context', { p_order: orderId });
  if (error) throw new Error(/buyer_agent_context|schema cache/.test(error.message) ? 'В базе нет функций агента покупателя — выполните supabase/buyer-agent.sql' : error.message);
  return data as Ctx;
}

async function autoReply(orderId: string) {
  const c = await context(admin, orderId);
  const o = c.order;
  if (!c.rules.auto_reply) return { skipped: 'Автоторг выключен' };
  if (o.status !== 'negotiation' || o.turn !== 'buyer') return { skipped: 'Не ход покупателя' };
  if (c.agent_today >= DAILY_LIMIT) return { skipped: 'Дневной лимит ответов агента исчерпан' };
  if (c.agent_offers >= num(c.rules.max_rounds) && num(o.price) > num(c.ceiling))
    return { skipped: 'Агент исчерпал раунды торга — решение за закупщиком' };
  let plan = enforce(c, await gemini(String(o.buyer_id), NEGO_SYSTEM(c.rules.tone), negoPrompt(c), NEGO_SCHEMA));
  if (plan.action === 'counter' && c.agent_offers >= num(c.rules.max_rounds)) plan = { ...plan, action: 'accept', price: num(o.price) };
  const { error } = await admin.rpc('order_buyer_agent_action', {
    p_order: orderId, p_action: plan.action, p_price: plan.action === 'counter' ? plan.price : null, p_text: plan.message,
  });
  if (error) return { skipped: error.message };
  return { done: plan.action, price: plan.price };
}

// ── Склад: когда и сколько заказать ──
const STOCK_SYSTEM = `Ты — ИИ-аналитик закупок покупателя на B2B-площадке «РЕЗЕРВ». Разбираешь одну позицию склада и советуешь по-русски, когда и сколько заказать и у кого.
Правила:
- Опирайся на цифры: остаток, расход, срок поставки, страховой запас, историю списаний, заказы в пути, предложения поставщиков.
- Если расход неравномерный или растёт — скажи об этом. Если данных мало — честно скажи, что прогноз грубый.
- Не выдумывай поставщиков и цены — только из списка предложений.
- summary — 2–3 предложения. tips — до 4 коротких пунктов. Числа пиши с пробелами между разрядами.`;
const STOCK_SCHEMA = {
  type: 'OBJECT',
  properties: {
    risk: { type: 'STRING', enum: ['high', 'medium', 'low'], description: 'риск дефицита' },
    summary: { type: 'STRING' },
    order_in_days: { type: 'NUMBER', description: 'через сколько дней оформить заказ (0 — сегодня)' },
    order_qty: { type: 'NUMBER', description: 'сколько заказать, в единицах позиции (0 — не нужно)' },
    supplier: { type: 'STRING', description: 'у кого выгоднее заказать, из списка предложений, или пусто' },
    tips: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['risk', 'summary', 'order_in_days', 'order_qty', 'supplier', 'tips'],
};

async function stockAdvice(req: Request, b: any) {
  const user = asUser(req);
  const { data: ctx, error } = await user.rpc('buyer_stock_context', { p_item: String(b.item_id || '') });
  if (error) throw new Error(/buyer_stock_context|schema cache/.test(error.message) ? 'В базе нет функций агента покупателя — выполните supabase/buyer-agent.sql' : error.message);
  const it = ctx.item, calc = b.calc || {};
  const safe = (v: unknown) => (typeof v === 'number' && isFinite(v) ? v : null);
  const text = `Позиция: ${it.name}${it.sku ? ' (арт. ' + it.sku + ')' : ''}, единица: ${it.unit}.
Остаток: ${fmt(it.stock)} ${it.unit}. Срок поставки: ${it.lead_days} дн. Страховой запас: ${it.safety_days} дн. Целевой запас: ${num(it.max_stock) ? fmt(it.max_stock) + ' ' + it.unit : 'не задан'}.
Расчёт кабинета по формулам: расход ${safe(calc.use) != null ? fmt(calc.use) + ' ' + it.unit + '/день' : 'неизвестен'}, хватит на ${safe(calc.days) != null ? fmt(calc.days) + ' дн.' : '—'}, точка заказа ${safe(calc.rop) != null ? fmt(calc.rop) + ' ' + it.unit : '—'}, рекомендация формулы: ${String(calc.rec || '—').slice(0, 200)}.
Списания и приходы по дням за 90 дней: ${ctx.moves.length ? ctx.moves.map((m: any) => `${m.day}: ${m.use ? '−' + fmt(m.use) : ''}${m.in ? ' +' + fmt(m.in) : ''}`).join('; ') : 'нет движений'}.
Заказы в работе: ${ctx.open_orders.length ? ctx.open_orders.map((o: any) => `${o.number} (${o.status}) ${fmt(o.qty)} ${it.unit} по ${fmt(o.price)} ₽ у «${o.supplier}»${o.due_date ? ' до ' + o.due_date : ''}`).join('; ') : 'нет'}.
Предложения поставщиков на площадке: ${ctx.offers.length ? ctx.offers.map((x: any) => `«${x.supplier}»: ${x.item} — ${fmt(x.price)} ₽/${it.unit}, в наличии ${fmt(x.stock)}${x.rating != null ? ', рейтинг ' + x.rating : ''}`).join('; ') : 'нет'}.
Сегодня: ${new Date().toISOString().slice(0, 10)}.`;
  const out = await gemini(String(it.owner_id), STOCK_SYSTEM, text, STOCK_SCHEMA);
  return json({
    risk: ['high', 'medium', 'low'].includes(out.risk) ? out.risk : 'medium',
    summary: String(out.summary || '').slice(0, 700),
    order_in_days: Math.max(0, Math.round(num(out.order_in_days))),
    order_qty: Math.max(0, r2(num(out.order_qty))),
    supplier: String(out.supplier || '').slice(0, 120),
    tips: (Array.isArray(out.tips) ? out.tips : []).slice(0, 4).map((t: unknown) => String(t).slice(0, 240)),
    via: out.via,
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Только POST' }, 405);
  let b: any = {};
  try { b = await req.json(); } catch { return json({ error: 'Неверный запрос' }, 400); }
  try {
    if (b.action === 'suggest') {
      const c = await context(asUser(req), String(b.order_id || ''));   // права проверяет база
      if (c.order.status !== 'negotiation') return json({ error: 'Заказ уже не в переговорах' }, 400);
      const plan = enforce(c, await gemini(String(c.order.buyer_id), NEGO_SYSTEM(c.rules.tone), negoPrompt(c), NEGO_SCHEMA));
      return json({ ...plan, ceiling: c.ceiling, target: c.target, list_price: c.order.list_price, supplier_price: c.order.price, market: c.market });
    }
    if (b.action === 'auto') return json(await autoReply(String(b.order_id || '')));
    if (b.action === 'sweep') {
      const user = asUser(req), owner = String(b.owner_id || '');
      const { data: ok } = await user.rpc('can_act_party', { p_owner: owner });
      if (!ok) return json({ error: 'Нет прав' }, 403);
      const { data: list } = await admin.from('orders').select('id')
        .eq('buyer_id', owner).eq('status', 'negotiation').eq('turn', 'buyer').order('updated_at').limit(10);
      const results = [];
      for (const o of list || []) results.push({ id: o.id, ...(await autoReply(o.id).catch((e) => ({ skipped: String(e.message || e) }))) });
      return json({ results });
    }
    if (b.action === 'stock') return await stockAdvice(req, b);
    return json({ error: 'Неизвестное действие' }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 400);
  }
});
