// Авторизация через Supabase Auth + таблица public.profiles.
// Используется лендингом (index.html) и личным кабинетом (cabinet.html).
(function () {
  // Ссылки из писем Supabase возвращают сюда токены или ошибку в #hash.
  // Сброс пароля обрабатывает только кабинет — если ссылка привела на
  // лендинг (Redirect URL не в белом списке), переносим её в кабинет.
  const hash = new URLSearchParams(location.hash.slice(1));
  const fromRecoveryLink = hash.get('type') === 'recovery';
  const onCabinet = /cabinet(\.html)?$/.test(location.pathname);
  if (!onCabinet && (fromRecoveryLink || hash.get('error_code'))) {
    location.replace('/cabinet.html' + location.hash);
    return;
  }
  const LINK_ERRORS = {
    otp_expired: 'Ссылка из письма устарела или уже использована — запросите новую',
    access_denied: 'Ссылка из письма недействительна — запросите новую',
  };
  const linkError = hash.get('error_code') ? (LINK_ERRORS[hash.get('error_code')] || hash.get('error_description') || 'Ошибка ссылки из письма') : '';

  const cfg = window.REZERV_CONFIG || {};
  const configured = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY && window.supabase);
  const sb = configured ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
  const NOT_CONFIGURED = 'Supabase не подключён: заполните site/config.js';

  // Подписываемся сразу, до загрузки React: событие PASSWORD_RECOVERY
  // приходит один раз и может опередить монтирование кабинета.
  let recovery = fromRecoveryLink;
  const recoveryListeners = [];
  if (sb) sb.auth.onAuthStateChange(ev => {
    if (ev !== 'PASSWORD_RECOVERY') return;
    recovery = true;
    recoveryListeners.splice(0).forEach(cb => cb());
  });

  const ERRORS = [
    [/invalid login credentials/i, 'Неверный email или пароль'],
    [/email not confirmed/i, 'Email не подтверждён — откройте письмо со ссылкой'],
    [/user already registered/i, 'Пользователь с таким email уже зарегистрирован'],
    [/password should be at least/i, 'Пароль слишком короткий — минимум 6 символов'],
    [/unable to validate email|invalid format|email address .* is invalid/i, 'Некорректный email'],
    [/rate limit|too many requests|security purposes/i, 'Слишком много попыток — подождите минуту'],
    [/failed to fetch|network/i, 'Нет связи с сервером Supabase'],
    [/permission denied|jwt expired|invalid jwt|not authenticated/i, 'Нет доступа: похоже, вы вышли из аккаунта или вошли в другой (например, в соседней вкладке). Обновите страницу и войдите снова'],
  ];
  function ruError(err) {
    const msg = (err && err.message) || String(err || '');
    for (const [re, ru] of ERRORS) if (re.test(msg)) return ru;
    return msg || 'Неизвестная ошибка';
  }
  function fail(err) { return { error: ruError(err) }; }

  async function loadProfile(user) {
    const { data, error } = await sb.from('profiles').select('*').eq('id', user.id).maybeSingle();
    if (error) console.warn('[auth] profiles:', error.message);
    const meta = user.user_metadata || {};
    return data || { id: user.id, email: user.email, full_name: meta.full_name || '', company: meta.company || '', role: meta.role || 'buy' };
  }

  // Текущая сессия → { user, profile } или null
  async function current() {
    if (!sb) return null;
    const { data } = await sb.auth.getSession();
    const user = data.session && data.session.user;
    if (!user) return null;
    return { user, profile: await loadProfile(user) };
  }

  async function signIn(email, password) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.auth.signInWithPassword({ email: email.trim(), password });
    if (error) return fail(error);
    return { user: data.user, profile: await loadProfile(data.user) };
  }

  async function signUp({ email, password, fullName, company, role }) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.auth.signUp({
      email: email.trim(),
      password,
      options: {
        data: { full_name: fullName.trim(), company: company.trim(), role: role === 'sell' ? 'sell' : 'buy' },
        emailRedirectTo: location.origin + '/cabinet.html',
      },
    });
    if (error) return fail(error);
    // Если в проекте включено подтверждение email — сессии ещё нет
    if (!data.session) return { needConfirm: true };
    return { user: data.user, profile: await loadProfile(data.user) };
  }

  // Повторно отправить письмо подтверждения регистрации
  async function resendConfirmation(email) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { error } = await sb.auth.resend({
      type: 'signup',
      email: email.trim(),
      options: { emailRedirectTo: location.origin + '/cabinet.html' },
    });
    return error ? fail(error) : {};
  }

  async function resetPassword(email) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { error } = await sb.auth.resetPasswordForEmail(email.trim(), { redirectTo: location.origin + '/cabinet.html' });
    return error ? fail(error) : {};
  }

  async function updatePassword(password) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { error } = await sb.auth.updateUser({ password });
    if (error) return fail(error);
    recovery = false;
    history.replaceState(null, '', location.pathname);
    return {};
  }

  // Обновить поля своего профиля (имя, реквизиты компании)
  async function updateProfile(patch) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data: s } = await sb.auth.getSession();
    const user = s.session && s.session.user;
    if (!user) return { error: 'Сессия истекла — войдите заново' };
    const { data, error } = await sb.from('profiles').update(patch).eq('id', user.id).select().single();
    if (!error) return { profile: data };
    const m = error.message || '';
    if (/column .* does not exist|schema cache/i.test(m)) return { error: 'В базе нет полей компании — выполните supabase/company.sql' };
    if (/permission denied/i.test(m)) return { error: 'Нет прав на изменение — выполните supabase/company.sql' };
    if (/check constraint/i.test(m)) return { error: 'База отклонила данные: проверьте формат ИНН, КПП и ОГРН' };
    return fail(error);
  }

  // ── Команды ──────────────────────────────────────────────────────────
  const TEAM_SQL_HINT = 'В базе нет таблиц команды — выполните supabase/team.sql';
  function teamFail(error) {
    const m = (error && error.message) || '';
    if (/relation .* does not exist|could not find the (table|function)|schema cache/i.test(m)) return { error: TEAM_SQL_HINT };
    if (/row-level security|Нет прав/i.test(m)) return { error: 'Недостаточно прав для этого действия' };
    return fail(error);
  }
  async function uid() {
    const { data } = await sb.auth.getSession();
    return data.session ? data.session.user.id : null;
  }

  // Команды, в которых я участник: [{ owner_id, access, position, owner: {…профиль владельца} }]
  async function myTeams() {
    if (!sb) return { teams: [] };
    const me = await uid();
    const { data, error } = await sb.from('team_members')
      .select('owner_id, access, position, owner:profiles!team_members_owner_id_fkey(*)')
      .eq('user_id', me);
    if (error) return { ...teamFail(error), teams: [] };
    return { teams: (data || []).filter(t => t.owner) };
  }

  // Состав команды владельца ownerId: { owner, members: [{ user_id, access, position, user }] }
  async function loadTeam(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const [o, m] = await Promise.all([
      sb.from('profiles').select('*').eq('id', ownerId).maybeSingle(),
      sb.from('team_members')
        .select('user_id, access, position, created_at, user:profiles!team_members_user_id_fkey(id, full_name, email)')
        .eq('owner_id', ownerId).order('created_at'),
    ]);
    if (o.error) return teamFail(o.error);
    if (m.error) return teamFail(m.error);
    return { owner: o.data, members: m.data || [] };
  }

  async function listInvites() {
    const { data, error } = await sb.from('team_invites').select('*')
      .is('used_at', null).gt('expires_at', new Date().toISOString()).order('created_at', { ascending: false });
    return error ? teamFail(error) : { invites: data || [] };
  }
  async function createInvite(access, position) {
    const { data, error } = await sb.from('team_invites').insert({ access, position }).select().single();
    return error ? teamFail(error) : { invite: data };
  }
  async function revokeInvite(id) {
    const { error } = await sb.from('team_invites').delete().eq('id', id);
    return error ? teamFail(error) : {};
  }
  async function updateMember(userId, patch) {
    const me = await uid();
    const { error } = await sb.from('team_members').update(patch).eq('owner_id', me).eq('user_id', userId);
    return error ? teamFail(error) : {};
  }
  async function removeMember(userId) {
    const me = await uid();
    const { error } = await sb.from('team_members').delete().eq('owner_id', me).eq('user_id', userId);
    return error ? teamFail(error) : {};
  }
  async function leaveTeam(ownerId) {
    const me = await uid();
    const { error } = await sb.from('team_members').delete().eq('owner_id', ownerId).eq('user_id', me);
    return error ? teamFail(error) : {};
  }
  async function getInvite(token) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.rpc('get_invite', { p_token: token });
    if (error) return teamFail(error);
    return { invite: (data && data[0]) || { status: 'not_found' } };
  }
  async function acceptInvite(token) {
    const { data, error } = await sb.rpc('accept_invite', { p_token: token });
    return error ? teamFail(error) : { ownerId: data };
  }
  async function updateTeamCompany(ownerId, patch) {
    const { data, error } = await sb.rpc('update_team_company', { p_owner: ownerId, p_patch: patch });
    if (error) {
      if (/check constraint/i.test(error.message || '')) return { error: 'База отклонила данные: проверьте формат ИНН, КПП и ОГРН' };
      return teamFail(error);
    }
    return { profile: data };
  }
  // ── Каталог и прайс ─────────────────────────────────────────────────
  function catalogFail(error) {
    const m = (error && error.message) || '';
    if (/relation .*catalog_items.* does not exist|could not find the (table|function).*catalog|schema cache/i.test(m)) return { error: 'В базе нет таблицы каталога — выполните supabase/catalog.sql' };
    if (/duplicate key|catalog_items_unique_name/i.test(m)) return { error: 'Такая позиция (наименование + стандарт) уже есть в каталоге' };
    if (/check constraint/i.test(m)) return { error: 'База отклонила данные: проверьте наименование, цену и остаток' };
    if (/row-level security|Нет прав/i.test(m)) return { error: 'Недостаточно прав для изменения каталога' };
    return fail(error);
  }
  async function listCatalog(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.from('catalog_items').select('*').eq('owner_id', ownerId).order('created_at');
    return error ? catalogFail(error) : { items: data || [] };
  }
  async function addCatalogItem(ownerId, item) {
    const { data, error } = await sb.from('catalog_items').insert({ ...item, owner_id: ownerId }).select().single();
    return error ? catalogFail(error) : { item: data };
  }
  async function updateCatalogItem(id, patch) {
    const { data, error } = await sb.from('catalog_items').update(patch).eq('id', id).select().single();
    return error ? catalogFail(error) : { item: data };
  }
  async function deleteCatalogItem(id) {
    const { error } = await sb.from('catalog_items').delete().eq('id', id);
    return error ? catalogFail(error) : {};
  }
  async function importCatalog(ownerId, rows) {
    const { data, error } = await sb.rpc('import_catalog', { p_owner: ownerId, p_rows: rows });
    if (error) return catalogFail(error);
    const r = (data && data[0]) || { inserted: 0, updated: 0 };
    return { inserted: r.inserted, updated: r.updated };
  }

  // ── Рейтинг поставщика ──────────────────────────────────────────────
  async function loadRating(supplierId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const [r, v] = await Promise.all([
      sb.rpc('get_supplier_rating', { p_supplier: supplierId }),
      sb.from('supplier_reviews').select('id, buyer_company, rating, on_time, quality_ok, comment, created_at')
        .eq('supplier_id', supplierId).order('created_at', { ascending: false }).limit(20),
    ]);
    const err = r.error || v.error;
    if (err) {
      if (/does not exist|could not find|schema cache/i.test(err.message || '')) return { error: 'В базе нет таблиц рейтинга — выполните supabase/rating.sql' };
      return fail(err);
    }
    return { stats: (r.data && r.data[0]) || null, reviews: v.data || [] };
  }

  // ── Поставщики для покупателя ───────────────────────────────────────
  function supFail(error) {
    const m = (error && error.message) || '';
    if (/list_suppliers|set_supplier_mark|buyer_suppliers/i.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет функций поставщиков — выполните supabase/suppliers.sql' };
    if (/Нет прав/i.test(m)) return { error: 'Недостаточно прав для изменения списка поставщиков' };
    return fail(error);
  }
  async function listSuppliers(buyerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.rpc('list_suppliers', { p_buyer: buyerId });
    return error ? supFail(error) : { suppliers: data || [] };
  }
  // Видимые позиции поставщика и последние отзывы о нём
  async function supplierDetails(supplierId) {
    const [items, revs] = await Promise.all([
      sb.from('catalog_items').select('id, name, standard, unit, price, stock')
        .eq('owner_id', supplierId).eq('visible', true).order('name'),
      sb.from('supplier_reviews').select('buyer_company, rating, on_time, quality_ok, comment, created_at')
        .eq('supplier_id', supplierId).order('created_at', { ascending: false }).limit(5),
    ]);
    if (items.error) return supFail(items.error);
    return { items: items.data || [], reviews: revs.error ? [] : (revs.data || []) };
  }
  async function setSupplierMark(buyerId, supplierId, whitelisted, blocked) {
    const { error } = await sb.rpc('set_supplier_mark', { p_buyer: buyerId, p_supplier: supplierId, p_whitelisted: whitelisted, p_blocked: blocked });
    return error ? supFail(error) : {};
  }

  // ── Уведомления ─────────────────────────────────────────────────────
  function ntfFail(error) {
    const m = (error && error.message) || '';
    if (/notification|notify_prefs/i.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет уведомлений — выполните supabase/notifications.sql' };
    return fail(error);
  }
  // Последние уведомления кабинета и момент, когда текущий пользователь их просматривал
  async function listNotifications(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const [n, seen] = await Promise.all([
      sb.from('notifications').select('id, kind, title, body, order_id, created_at')
        .eq('owner_id', ownerId).order('created_at', { ascending: false }).limit(40),
      sb.from('notification_seen').select('seen_at').eq('owner_id', ownerId).maybeSingle(),
    ]);
    if (n.error) return ntfFail(n.error);
    return { items: n.data || [], seenAt: seen.data ? seen.data.seen_at : null };
  }
  async function markNotificationsSeen(ownerId) {
    const { error } = await sb.rpc('notifications_mark_seen', { p_owner: ownerId });
    return error ? ntfFail(error) : {};
  }
  async function saveNotifyPrefs(prefs) {
    const me = await uid();
    const { error } = await sb.from('profiles').update({ notify_prefs: prefs }).eq('id', me);
    return error ? ntfFail(error) : {};
  }

  // ── Склад покупателя ────────────────────────────────────────────────
  function stockFail(error) {
    const m = (error && error.message) || '';
    if (/stock_(items|moves|move)/i.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет таблиц склада — выполните supabase/stock.sql' };
    if (/duplicate key|stock_items_unique_name/i.test(m)) return { error: 'Позиция с таким названием уже есть на складе' };
    if (/check constraint/i.test(m)) return { error: 'База отклонила данные: проверьте числа и длину полей' };
    if (/row-level security|Нет прав/i.test(m)) return { error: 'Недостаточно прав для изменения склада' };
    return fail(error);
  }
  // Позиции склада и движения за 60 дней
  async function listStock(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const since = new Date(Date.now() - 60 * 864e5).toISOString();
    const [it, mv] = await Promise.all([
      sb.from('stock_items').select('*').eq('owner_id', ownerId).order('name'),
      sb.from('stock_moves').select('id, item_id, kind, qty, before, after, note, order_id, created_at')
        .eq('owner_id', ownerId).gte('created_at', since).order('created_at', { ascending: false }).limit(2000),
    ]);
    if (it.error) return stockFail(it.error);
    return { items: it.data || [], moves: mv.error ? [] : (mv.data || []) };
  }
  async function addStockItem(ownerId, item) {
    const { data, error } = await sb.from('stock_items').insert({ ...item, owner_id: ownerId }).select().single();
    return error ? stockFail(error) : { item: data };
  }
  async function updateStockItem(id, patch) {
    const { data, error } = await sb.from('stock_items').update(patch).eq('id', id).select().single();
    return error ? stockFail(error) : { item: data };
  }
  async function deleteStockItem(id) {
    const { error } = await sb.from('stock_items').delete().eq('id', id);
    return error ? stockFail(error) : {};
  }
  async function importStock(ownerId, rows, fileName) {
    const { data, error } = await sb.rpc('import_stock', { p_owner: ownerId, p_rows: rows, p_file: fileName || '' });
    if (error) {
      if (/import_stock/i.test(error.message || '') && /does not exist|could not find|schema cache/i.test(error.message || '')) return { error: 'В базе нет функции загрузки остатков — выполните supabase/stock.sql ещё раз' };
      return stockFail(error);
    }
    const r = (data && data[0]) || { inserted: 0, updated: 0, unchanged: 0 };
    return r;
  }
  async function stockMove(id, kind, qty, note) {
    const { data, error } = await sb.rpc('stock_move', { p_item: id, p_kind: kind, p_qty: qty, p_note: note || '' });
    return error ? stockFail(error) : { item: data };
  }

  // ── Отзыв о поставке ────────────────────────────────────────────────
  async function createReview(orderId, rating, onTime, qualityOk, comment) {
    const { data, error } = await sb.rpc('review_create', {
      p_order: orderId, p_rating: rating, p_on_time: onTime, p_quality_ok: qualityOk, p_comment: comment || '',
    });
    if (error) {
      if (/review_create/i.test(error.message || '') && /does not exist|could not find|schema cache/i.test(error.message || '')) return { error: 'В базе нет функции отзывов — выполните supabase/reviews.sql' };
      return fail(error);
    }
    return { review: data };
  }

  // ── Сравнение цен с рынком ──────────────────────────────────────────
  function marketFail(error) {
    const m = (error && error.message) || '';
    if (/market_|pg_trgm|similarity/i.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет функций сравнения — выполните supabase/market.sql' };
    return fail(error);
  }
  async function marketCompare(supplierId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.rpc('market_compare', { p_supplier: supplierId });
    return error ? marketFail(error) : { rows: data || [] };
  }
  async function marketOffers(itemId) {
    const { data, error } = await sb.rpc('market_offers', { p_item: itemId });
    return error ? marketFail(error) : { rows: data || [] };
  }
  async function marketSearch(query) {
    const { data, error } = await sb.rpc('market_search', { p_query: query });
    return error ? marketFail(error) : { rows: data || [] };
  }

  // ── Заказы и переговоры ─────────────────────────────────────────────
  function orderFail(error) {
    const m = (error && error.message) || '';
    if (/(orders|order_messages|order_create|order_action).*(does not exist|could not find)|could not find the function public\.order|schema cache/i.test(m)) return { error: 'В базе нет таблиц заказов — выполните supabase/orders.sql' };
    return fail(error);
  }
  // side: 'buyer' — заказы кабинета как покупателя, 'supplier' — как поставщика
  async function listOrders(ownerId, side) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.from('orders').select('*')
      .eq(side === 'buyer' ? 'buyer_id' : 'supplier_id', ownerId)
      .order('updated_at', { ascending: false }).limit(200);
    return error ? orderFail(error) : { orders: data || [] };
  }
  async function orderMessages(orderId) {
    const { data, error } = await sb.from('order_messages').select('*').eq('order_id', orderId).order('created_at');
    return error ? orderFail(error) : { messages: data || [] };
  }
  async function createOrder(buyerId, itemId, qty, price, pay, due, comment) {
    const { data, error } = await sb.rpc('order_create', {
      p_buyer: buyerId, p_item: itemId, p_qty: qty, p_price: price, p_pay: pay, p_due: due || null, p_comment: comment || '',
    });
    return error ? orderFail(error) : { id: data };
  }
  async function orderAction(orderId, side, action, price, text) {
    const { data, error } = await sb.rpc('order_action', {
      p_order: orderId, p_side: side, p_action: action, p_price: price == null ? null : price, p_text: text || '',
    });
    return error ? orderFail(error) : { order: data };
  }

  // ── ИИ-агент поставщика ──
  function agentFail(error) {
    const m = (error && error.message) || '';
    if (/seller_agent|agent_context|by_agent/.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет таблиц агента — выполните supabase/agent.sql' };
    return fail(error);
  }
  async function agentRules(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.from('seller_agent').select('*').eq('owner_id', ownerId).maybeSingle();
    return error ? agentFail(error) : { rules: data };
  }
  async function saveAgentRules(ownerId, rules) {
    const { data, error } = await sb.from('seller_agent').upsert({ owner_id: ownerId, ...rules }, { onConflict: 'owner_id' }).select().single();
    return error ? agentFail(error) : { rules: data };
  }
  // ── ИИ-агент покупателя ──
  async function buyerAgentRules(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.from('buyer_agent').select('*').eq('owner_id', ownerId).maybeSingle();
    if (error && /buyer_agent/.test(error.message || '') && /does not exist|could not find|schema cache/i.test(error.message || '')) return { error: 'В базе нет таблиц агента покупателя — выполните supabase/buyer-agent.sql' };
    return error ? fail(error) : { rules: data };
  }
  async function saveBuyerAgentRules(ownerId, rules) {
    const { data, error } = await sb.from('buyer_agent').upsert({ owner_id: ownerId, ...rules }, { onConflict: 'owner_id' }).select().single();
    return error ? fail(error) : { rules: data };
  }

  // Вызов Edge Function seller-agent: { action: 'suggest', order_id } | { action: 'sweep', owner_id }
  // fn: 'seller-agent' (поставщик) или 'buyer-agent' (покупатель)
  async function agentCall(body, fn) {
    fn = fn || 'seller-agent';
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.functions.invoke(fn, { body });
    if (!error) return data && data.error ? { error: data.error } : data;
    const res = error.context;
    if (res && typeof res.json === 'function') {
      if (res.status === 404) return { error: 'ИИ-агент не подключён — разверните функцию ' + fn + ' в Supabase' };
      try { const j = await res.json(); if (j && j.error) return { error: j.error }; } catch (e) {}
    }
    if (/failed to send|fetch/i.test(error.message || '')) return { error: 'ИИ-агент не отвечает — проверьте, что функция ' + fn + ' развёрнута' };
    return fail(error);
  }

  // ── Свой ключ Gemini кабинета (хранится в Vault, с сайта виден только хвост) ──
  function keyFail(error) {
    const m = (error && error.message) || '';
    if (/ai_key/.test(m) && /does not exist|could not find|schema cache/i.test(m)) return { error: 'В базе нет таблицы ключей — выполните supabase/ai-keys.sql' };
    return fail(error);
  }
  async function aiKeyInfo(ownerId) {
    if (!sb) return { error: NOT_CONFIGURED };
    const { data, error } = await sb.from('ai_keys')
      .select('owner_id, provider, model, last4, status, last_error, last_used_at, uses, updated_at')
      .eq('owner_id', ownerId).maybeSingle();
    return error ? keyFail(error) : { key: data };
  }
  // key пустой — сменить только модель
  function aiKeySave(ownerId, key, model) { return agentCall({ action: 'save_key', owner_id: ownerId, key: key || '', model }); }
  async function aiKeyDelete(ownerId) {
    const { error } = await sb.rpc('ai_key_delete', { p_owner: ownerId });
    return error ? keyFail(error) : {};
  }

  function inviteLink(token) { return location.origin + '/cabinet.html?invite=' + token; }

  async function signOut() {
    if (sb) await sb.auth.signOut();
  }

  // Изменения входа — в том числе из других вкладок этого браузера (вход общий на весь сайт).
  // cb(userId | null)
  function onSessionChange(cb) {
    if (!sb) return;
    sb.auth.onAuthStateChange((ev, session) => {
      if (ev === 'INITIAL_SESSION') return;
      cb(session && session.user ? session.user.id : null, ev);
    });
  }

  // Колбэк при переходе по ссылке «сбросить пароль» из письма
  function onRecovery(cb) {
    if (recovery) setTimeout(cb, 0);
    else recoveryListeners.push(cb);
  }
  function isRecovery() { return recovery; }

  function initials(name, email) {
    const parts = (name || '').trim().split(/\s+/).filter(Boolean);
    if (parts.length) return parts.slice(0, 2).map(p => p[0].toUpperCase()).join('');
    return (email || '?').slice(0, 2).toUpperCase();
  }

  window.RezervAuth = { configured, NOT_CONFIGURED, client: sb, current, signIn, signUp, resendConfirmation, resetPassword, updatePassword, updateProfile, signOut,
    myTeams, loadTeam, listInvites, createInvite, revokeInvite, updateMember, removeMember, leaveTeam,
    getInvite, acceptInvite, updateTeamCompany, inviteLink,
    loadRating, listSuppliers, supplierDetails, setSupplierMark, listOrders, orderMessages, createOrder, orderAction, agentRules, saveAgentRules, agentCall, buyerAgentRules, saveBuyerAgentRules, aiKeyInfo, aiKeySave, aiKeyDelete, marketCompare, marketOffers, marketSearch, listNotifications, markNotificationsSeen, saveNotifyPrefs, createReview, listStock, addStockItem, updateStockItem, deleteStockItem, stockMove, importStock, listCatalog, addCatalogItem, updateCatalogItem, deleteCatalogItem, importCatalog, onRecovery, onSessionChange, isRecovery, linkError, initials };
})();
