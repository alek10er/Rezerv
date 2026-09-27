// РЕЗЕРВ — ИИ-агент поставщика (Supabase Edge Function + Gemini)
//
// Действия (POST JSON):
//   { action: 'suggest', order_id }  — подсказка ответа (с сайта, от имени вошедшего поставщика)
//   { action: 'auto',    order_id }  — автоответ (вызывает база триггером, когда ход переходит к поставщику)
//   { action: 'sweep',   owner_id }  — ответить на все ждущие заказы (при включении автоответа)
//   { action: 'save_key', owner_id, key?, model } — свой ключ Gemini кабинета (проверка + сохранение в Vault)
//
// Ключ: сначала свой ключ кабинета (таблица ai_keys, Vault), если его нет или он не работает — ключ платформы.
// Секреты функции: GEMINI_API_KEY (ключ платформы), GEMINI_MODEL (необязательно).
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY Supabase подставляет сам.

import { createClient } from 'npm:@supabase/supabase-js@2';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY') || '';
const MODELS = [Deno.env.get('GEMINI_MODEL') || 'gemini-2.5-flash', 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite'];
const DAILY_LIMIT = 300; // ответов агента в сутки на одного поставщика

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

type Ctx = {
  order: Record<string, any>; rules: Record<string, any>; floor: number; stock: number | null; visible: boolean | null;
  messages: { side: string; kind: string; price: number | null; body: string; by_agent: boolean; at: string }[];
  agent_offers: number; agent_today: number;
  buyer_history: { deals: number; total: number; avg_disc_pct: number };
  market: { offers: number; min: number | null; avg: number | null; max: number | null };
};
type Plan = { action: 'accept' | 'counter' | 'reject'; price: number; message: string; reason: string; via?: 'own' | 'platform' };

const TONES: Record<string, string> = {
  business: 'деловой, вежливый, без лишних слов',
  friendly: 'дружелюбный и тёплый, но профессиональный',
  short: 'максимально коротко — одно-два предложения',
};

function prompt(c: Ctx) {
  const o = c.order, r = c.rules, m = c.market, h = c.buyer_history;
  const lastSupplierOffer = [...c.messages].reverse().find((x) => x.side === 'supplier' && x.kind === 'offer');
  const history = c.messages.map((x) => {
    const who = x.side === 'buyer' ? 'Покупатель' : x.side === 'supplier' ? (x.by_agent ? 'Мы (ИИ)' : 'Мы') : 'Система';
    return `${who}: ${x.price != null ? `[цена ${fmt(x.price)} ₽/${o.unit}] ` : ''}${x.body || ''}`.trim();
  }).join('\n');
  return `Заказ ${o.number} от «${o.buyer_company}».
Товар: ${o.item}${o.standard ? ' (' + o.standard + ')' : ''}, количество ${fmt(o.qty)} ${o.unit}.
Цена в нашем прайсе: ${fmt(o.list_price)} ₽/${o.unit}. Текущее предложение покупателя: ${fmt(o.price)} ₽/${o.unit} (скидка ${fmt((1 - num(o.price) / num(o.list_price || 1)) * 100)}%).
Сумма по цене покупателя: ${fmt(num(o.qty) * num(o.price))} ₽. Оплата: ${o.pay_terms}. Поставить до: ${o.due_date || 'не указано'}.
Наш остаток на складе: ${c.stock == null ? 'неизвестен' : fmt(c.stock) + ' ' + o.unit}.
${lastSupplierOffer ? `Наше прошлое предложение: ${fmt(lastSupplierOffer.price)} ₽/${o.unit} — выше него не поднимаемся.` : ''}
МИНИМАЛЬНАЯ цена (секрет, покупателю не называть и не намекать на её существование): ${fmt(c.floor)} ₽/${o.unit}.
Рынок (другие поставщики на площадке): ${m.offers ? `${m.offers} предложений, от ${fmt(m.min)} до ${fmt(m.max)}, в среднем ${fmt(m.avg)} ₽/${o.unit}` : 'похожих предложений нет'}.
История с этим покупателем: ${h.deals ? `${h.deals} закрытых сделок на ${fmt(h.total)} ₽, средняя скидка ${fmt(h.avg_disc_pct)}%` : 'раньше не работали'}.
Раунд торга агента: ${c.agent_offers + 1} из ${r.max_rounds}.
${r.instructions ? `Указания поставщика: ${r.instructions}` : ''}

Переписка:
${history || '(пусто)'}`;
}

const SYSTEM = (tone: string) => `Ты — ИИ-агент отдела продаж поставщика на B2B-площадке закупок «РЕЗЕРВ». Отвечаешь покупателю от имени поставщика по-русски.
Цель: закрыть сделку по максимально выгодной для поставщика цене, сохранив покупателя.
Правила:
- Цена ниже МИНИМАЛЬНОЙ недопустима. Никогда не упоминай минимальную цену, «порог», «маржу», «внутреннюю политику».
- Если цена покупателя не ниже минимальной и торг затягивается или цена близка к прайсу — принимай (accept).
- Иначе делай встречное предложение (counter): уступай постепенно, между ценой покупателя и прошлым нашим предложением/прайсом. Учитывай объём, рынок и историю с покупателем.
- Если на складе меньше, чем заказано, или просьба покупателя не про цену и требует решения человека — выбери reject только если сделка точно невозможна; иначе counter и честно напиши, что уточнишь детали.
- Не выдумывай факты: сроки доставки, скидки на будущее, акции, «лучшее предложение на рынке».
- Сообщение покупателю: ${TONES[tone] || TONES.business}; без приветствий-шаблонов длиннее одной фразы; не более 400 символов; цену пиши в формате «53 200 ₽/т».
- reason — одна-две фразы для поставщика: почему такое решение (здесь можно говорить про минимальную цену).`;

const GEMINI_API = 'https://generativelanguage.googleapis.com/v1beta/models/';

// Ошибка ключа (а не временная перегрузка модели): такой ключ пробовать дальше бессмысленно
const keyProblem = (status: number, text: string) =>
  status === 401 || status === 403 || (status === 400 && /API_KEY|api key/i.test(text)) ||
  (status === 429 && /quota|billing|exceeded/i.test(text));
const keyError = (status: number, text: string) =>
  status === 429 ? 'Исчерпан лимит запросов по ключу' :
  /API_KEY_INVALID|not valid/i.test(text) ? 'Ключ недействителен' :
  status === 403 ? 'У ключа нет доступа к Gemini API' : 'Ошибка ключа (' + status + ')';

async function ownKey(owner: string): Promise<{ key: string; model: string } | null> {
  const { data, error } = await admin.rpc('ai_key_get', { p_owner: owner });
  if (error || !data || !data.length) return null;   // таблицы нет или ключ не подключён
  return { key: data[0].api_key, model: data[0].model };
}

async function gemini(c: Ctx): Promise<Plan & { via: 'own' | 'platform' }> {
  const body = JSON.stringify({
    systemInstruction: { parts: [{ text: SYSTEM(c.rules.tone) }] },
    contents: [{ role: 'user', parts: [{ text: prompt(c) }] }],
    generationConfig: {
      temperature: 0.4,
      responseMimeType: 'application/json',
      responseSchema: {
        type: 'OBJECT',
        properties: {
          action: { type: 'STRING', enum: ['accept', 'counter', 'reject'] },
          price: { type: 'NUMBER', description: 'цена за единицу: для accept — цена покупателя, для counter — наша встречная' },
          message: { type: 'STRING', description: 'сообщение покупателю' },
          reason: { type: 'STRING', description: 'пояснение для поставщика' },
        },
        required: ['action', 'price', 'message', 'reason'],
      },
    },
  });
  const owner = String(c.order.supplier_id || '');
  const own = owner ? await ownKey(owner) : null;
  const attempts: { key: string; via: 'own' | 'platform'; models: string[] }[] = [];
  if (own) attempts.push({ key: own.key, via: 'own', models: [...new Set([own.model, ...MODELS])] });
  if (GEMINI_KEY) attempts.push({ key: GEMINI_KEY, via: 'platform', models: [...new Set(MODELS)] });
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
        if (keyProblem(res.status, text)) {           // ключ не работает — к следующему ключу
          if (a.via === 'own') await admin.rpc('ai_key_mark', { p_owner: owner, p_ok: false, p_error: keyError(res.status, text) });
          break;
        }
        continue;                                     // перегрузка / нет модели — пробуем следующую модель
      }
      const data = await res.json();
      const text = data?.candidates?.[0]?.content?.parts?.map((p: any) => p.text || '').join('') || '';
      try {
        const plan = JSON.parse(text) as Plan;
        if (a.via === 'own') await admin.rpc('ai_key_mark', { p_owner: owner, p_ok: true, p_error: '' });
        return { ...plan, via: a.via };
      } catch { last = model + ': не удалось разобрать ответ'; }
    }
  }
  console.error('Gemini error', last);
  throw new Error('ИИ сейчас недоступен — попробуйте ещё раз через минуту');
}

// Проверка ключа и модели без траты квоты: запрос описания модели
async function checkKey(key: string, model: string): Promise<string> {
  const res = await fetch(GEMINI_API + model, { headers: { 'x-goog-api-key': key } });
  if (res.ok) return '';
  const text = await res.text();
  if (res.status === 404) return 'Модель ' + model + ' недоступна для этого ключа';
  if (res.status === 429) return '';                  // лимит — но ключ настоящий
  return keyError(res.status, text) + ' — проверьте, что скопировали его целиком';
}

async function saveKey(req: Request, b: any) {
  const user = asUser(req), owner = String(b.owner_id || '');
  const { data: u } = await user.auth.getUser();
  if (!u?.user || u.user.id !== owner) return json({ error: 'Ключом управляет только владелец кабинета' }, 403);
  const model = String(b.model || 'gemini-2.5-flash').trim();
  if (!/^[a-z0-9][a-z0-9.-]{2,79}$/.test(model)) return json({ error: 'Неверное название модели' }, 400);
  let key: string | null = typeof b.key === 'string' ? b.key.trim() : '';
  if (!key) key = null;
  if (key && (key.length < 20 || key.length > 200 || /\s/.test(key))) return json({ error: 'Это не похоже на ключ Gemini — скопируйте его целиком из AI Studio' }, 400);
  const testKey = key || (await ownKey(owner))?.key;
  if (!testKey) return json({ error: 'Вставьте ключ' }, 400);
  const err = await checkKey(testKey, model);
  if (err) return json({ error: err }, 400);
  const { data, error } = await admin.rpc('ai_key_store', { p_owner: owner, p_key: key, p_model: model, p_user: u.user.id });
  if (error) return json({ error: /ai_key_store|schema cache/.test(error.message) ? 'В базе нет таблицы ключей — выполните supabase/ai-keys.sql' : error.message }, 400);
  return json({ ok: true, last4: data?.last4, model: data?.model });
}

// Жёсткие границы поверх ответа модели: цена не ниже минимальной, не выше прайса и прошлого нашего предложения
function enforce(c: Ctx, p: Plan, auto: boolean): Plan {
  const o = c.order, buyer = num(o.price), list = num(o.list_price), floor = num(c.floor);
  const prev = [...c.messages].reverse().find((x) => x.side === 'supplier' && x.kind === 'offer');
  const cap = Math.min(list, prev?.price != null ? num(prev.price) : list);
  let { action, price } = p;
  let message = (p.message || '').trim().slice(0, 600), reason = (p.reason || '').trim().slice(0, 400);
  if (action === 'reject' && auto) action = 'counter';               // отказывать сам агент не может
  if (buyer >= cap) action = 'accept';                                // покупатель уже на нашей цене
  if (action === 'accept' && buyer < floor) { action = 'counter'; price = Math.max(num(price), floor); }
  if (action === 'counter') {
    price = r2(Math.min(cap, Math.max(floor, num(price) || floor)));
    if (price <= buyer) { action = 'accept'; price = buyer; }         // встречная ниже цены покупателя — просто принимаем
  }
  if (action === 'accept') price = buyer;
  if (action !== p.action)   // решение поменяли границы — текст модели ему больше не соответствует
    message = action === 'accept' ? 'Принимаем вашу цену ' + fmt(price) + ' ₽/' + o.unit + '. Заказ подтверждён.'
                                  : 'Можем предложить ' + fmt(price) + ' ₽/' + o.unit + ' за этот объём.';
  else if (action !== 'reject' && num(p.price) && Math.abs(num(p.price) - price) >= 0.01 && message.includes(fmt(p.price)))
    message = message.split(fmt(p.price)).join(fmt(price));          // модель назвала цену, которую мы поправили
  return { action, price, message, reason, via: (p as any).via };
}

async function context(db: ReturnType<typeof createClient>, orderId: string): Promise<Ctx> {
  const { data, error } = await db.rpc('agent_context', { p_order: orderId });
  if (error) throw new Error(/agent_context|schema cache/.test(error.message) ? 'В базе нет функций агента — выполните supabase/agent.sql' : error.message);
  return data as Ctx;
}

// Автоответ по одному заказу (ключ сервиса). Возвращает, что сделано, или почему пропущено.
async function autoReply(orderId: string) {
  const c = await context(admin, orderId);
  const o = c.order;
  if (!c.rules.auto_reply) return { skipped: 'Автоответ выключен' };
  if (o.status !== 'negotiation' || o.turn !== 'supplier') return { skipped: 'Не ход поставщика' };
  if (c.agent_today >= DAILY_LIMIT) return { skipped: 'Дневной лимит ответов агента исчерпан' };
  if (c.agent_offers >= num(c.rules.max_rounds)) return { skipped: 'Агент исчерпал раунды торга — решение за менеджером' };
  if (c.stock != null && num(c.stock) < num(o.qty)) return { skipped: 'На складе меньше, чем заказано — решение за менеджером' };
  const plan = enforce(c, await gemini(c), true);
  const { error } = await admin.rpc('order_agent_action', {
    p_order: orderId, p_action: plan.action, p_price: plan.action === 'counter' ? plan.price : null, p_text: plan.message,
  });
  if (error) return { skipped: error.message };
  return { done: plan.action, price: plan.price };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Только POST' }, 405);
  let b: any = {};
  try { b = await req.json(); } catch { return json({ error: 'Неверный запрос' }, 400); }
  try {
    if (b.action === 'suggest') {
      const user = asUser(req);
      const c = await context(user, String(b.order_id || ''));   // права проверяет база
      if (c.order.status !== 'negotiation') return json({ error: 'Заказ уже не в переговорах' }, 400);
      const plan = enforce(c, await gemini(c), false);
      return json({ ...plan, floor: c.floor, list_price: c.order.list_price, buyer_price: c.order.price, market: c.market });
    }
    if (b.action === 'auto') {
      return json(await autoReply(String(b.order_id || '')));
    }
    if (b.action === 'save_key') return await saveKey(req, b);
    if (b.action === 'sweep') {
      const user = asUser(req), owner = String(b.owner_id || '');
      const { data: ok } = await user.rpc('can_act_party', { p_owner: owner });
      if (!ok) return json({ error: 'Нет прав' }, 403);
      const { data: list } = await admin.from('orders').select('id')
        .eq('supplier_id', owner).eq('status', 'negotiation').eq('turn', 'supplier').order('updated_at').limit(10);
      const results = [];
      for (const o of list || []) results.push({ id: o.id, ...(await autoReply(o.id).catch((e) => ({ skipped: String(e.message || e) }))) });
      return json({ results });
    }
    return json({ error: 'Неизвестное действие' }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 400);
  }
});
