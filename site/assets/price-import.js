// Чтение прайса из .xlsx / .xls / .csv для каталога поставщика.
// Библиотека SheetJS (/vendor/xlsx.js) подгружается только при первой загрузке файла.
(function () {
  const MAX_ROWS = 2000;
  const MAX_SIZE = 5 * 1024 * 1024;

  let xlsxLoading = null;
  function loadXlsx() {
    if (window.XLSX) return Promise.resolve(window.XLSX);
    if (!xlsxLoading) {
      xlsxLoading = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'vendor/xlsx.js';
        s.onload = () => resolve(window.XLSX);
        s.onerror = () => { xlsxLoading = null; reject(new Error('Не удалось загрузить модуль чтения Excel')); };
        document.head.appendChild(s);
      });
    }
    return xlsxLoading;
  }

  // Колонки: ключ → варианты заголовков (сравниваются после нормализации)
  const COLUMNS = [
    ['price',    ['цена', 'стоимость', 'price', 'прайс']],
    ['name',     ['наименование', 'название', 'товар', 'позиция', 'номенклатура', 'продукция', 'name', 'product']],
    ['standard', ['стандарт', 'гост', 'ту', 'standard', 'нормативныйдокумент']],
    ['unit',     ['едизм', 'единицаизмерения', 'единица', 'ед', 'unit']],
    ['stock',    ['остаток', 'наличие', 'количество', 'колво', 'склад', 'stock', 'qty']],
    ['visible',  ['видна', 'видимость', 'показывать', 'опубликовать', 'visible']],
  ];
  const norm = v => String(v == null ? '' : v).toLowerCase().replace(/ё/g, 'е').replace(/[^a-zа-я0-9]/g, '');

  function detectColumns(headerRow, columns) {
    columns = columns || COLUMNS;
    const map = {};
    headerRow.forEach((cell, idx) => {
      const h = norm(cell);
      if (!h) return;
      for (const [key, variants] of columns) {
        if (map[key] != null) continue;
        if (variants.some(v => h === v || (v.length > 2 && h.startsWith(v)))) { map[key] = idx; break; }
      }
    });
    return map;
  }

  function parseNumber(v) {
    if (v == null || v === '') return null;
    if (typeof v === 'number') return isFinite(v) ? v : NaN;
    let s = String(v).replace(/[\s ]/g, '').replace(/[^\d,.\-]/g, '');
    if (!s) return NaN;
    if (s.includes(',') && s.includes('.')) s = s.replace(/\./g, '').replace(',', '.');
    else s = s.replace(',', '.');
    const n = Number(s);
    return isFinite(n) ? n : NaN;
  }

  function parseBool(v) {
    const s = norm(v);
    if (!s) return null;
    if (['да', 'yes', 'y', '1', 'true', 'показывать', 'видна', 'вкл'].includes(s)) return true;
    if (['нет', 'no', 'n', '0', 'false', 'скрыть', 'скрыта', 'выкл'].includes(s)) return false;
    return undefined;
  }

  const UNIT_ALIASES = { 'тонна': 'т', 'тонн': 'т', 'тн': 'т', 'шт.': 'шт', 'штук': 'шт', 'штука': 'шт', 'кг.': 'кг', 'м.': 'м', 'м2': 'м²', 'м3': 'м³', 'литр': 'л' };
  function parseUnit(v) {
    const s = String(v == null ? '' : v).trim().toLowerCase();
    if (!s) return null;
    return (UNIT_ALIASES[s] || s).slice(0, 10);
  }

  async function readRows(file) {
    const XLSX = await loadXlsx();
    const buf = await file.arrayBuffer();
    let wb;
    if (/\.csv$/i.test(file.name)) {
      // Excel сохраняет русский CSV в Windows-1251, остальные программы — в UTF-8
      let text;
      try { text = new TextDecoder('utf-8', { fatal: true }).decode(buf); }
      catch (e) { text = new TextDecoder('windows-1251').decode(buf); }
      wb = XLSX.read(text.replace(/^﻿/, ''), { type: 'string', raw: true });
    } else {
      wb = XLSX.read(buf, { type: 'array' });
    }
    const ws = wb.Sheets[wb.SheetNames[0]];
    if (!ws || !ws['!ref']) return { table: [], firstRow: 1 };
    // blankrows: true — чтобы номера строк в ошибках совпадали с номерами в Excel
    const table = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: '', blankrows: true });
    return { table, firstRow: XLSX.utils.decode_range(ws['!ref']).s.r + 1 };
  }

  // → { rows, errors, total, columns } или { error }
  async function parse(file) {
    if (!/\.(xlsx|xls|csv)$/i.test(file.name)) return { error: 'Поддерживаются файлы .xlsx, .xls и .csv' };
    if (file.size > MAX_SIZE) return { error: 'Файл больше 5 МБ — разбейте прайс на части' };
    let table, firstRow;
    try { ({ table, firstRow } = await readRows(file)); }
    catch (e) { return { error: 'Не удалось прочитать файл: ' + (e.message || e) }; }

    // Строка заголовков — первая из первых 10, где нашлись «Наименование» и «Цена»
    let headerIdx = -1, cols = null;
    for (let i = 0; i < Math.min(10, table.length); i++) {
      const c = detectColumns(table[i]);
      if (c.name != null && c.price != null) { headerIdx = i; cols = c; break; }
    }
    if (headerIdx < 0) return { error: 'Не нашли заголовки «Наименование» и «Цена» в первых строках файла — сверьтесь с инструкцией' };

    const rows = [], errors = [];
    const body = table.slice(headerIdx + 1);
    for (let i = 0; i < body.length; i++) {
      const r = body[i] || [], line = firstRow + headerIdx + 1 + i;
      const cell = k => (cols[k] != null ? r[cols[k]] : '');
      const name = String(cell('name') == null ? '' : cell('name')).trim();
      const rawPrice = cell('price');
      if (!name && (rawPrice === '' || rawPrice == null)) continue;        // пустая строка
      if (!name) { errors.push({ line, msg: 'нет наименования' }); continue; }
      if (name.length > 200) { errors.push({ line, msg: 'наименование длиннее 200 символов' }); continue; }
      const price = parseNumber(rawPrice);
      if (price == null) { errors.push({ line, msg: 'не указана цена' }); continue; }
      if (isNaN(price) || price < 0) { errors.push({ line, msg: 'цена «' + rawPrice + '» — не число' }); continue; }
      let stock = null;
      if (cols.stock != null) {
        stock = parseNumber(cell('stock'));
        if (stock != null && (isNaN(stock) || stock < 0)) { errors.push({ line, msg: 'остаток «' + cell('stock') + '» — не число' }); continue; }
      }
      let visible = null;
      if (cols.visible != null) {
        visible = parseBool(cell('visible'));
        if (visible === undefined) { errors.push({ line, msg: 'в колонке «Видна» ожидается «да» или «нет»' }); continue; }
      }
      rows.push({
        name,
        standard: cols.standard != null ? String(cell('standard') || '').trim().slice(0, 100) : '',
        unit: cols.unit != null ? parseUnit(cell('unit')) : null,
        price: Math.round(price * 100) / 100,
        stock,
        visible,
      });
      if (rows.length > MAX_ROWS) return { error: 'В файле больше ' + MAX_ROWS + ' позиций — разбейте прайс на части' };
    }
    if (!rows.length && !errors.length) return { error: 'В файле нет строк с товарами' };
    return { rows, errors, total: rows.length + errors.length, columns: Object.keys(cols) };
  }

  async function downloadTemplate() {
    const XLSX = await loadXlsx();
    const price = XLSX.utils.aoa_to_sheet([
      ['Наименование', 'Стандарт', 'Ед.', 'Цена', 'Остаток', 'Видна'],
      ['Сталь 09Г2С лист 10 мм', 'ГОСТ 19281-2014', 'т', 56200, 340, 'да'],
      ['Арматура А500С 12 мм', 'ГОСТ 34028-2016', 'т', 49500, 420, 'да'],
      ['Электроды ОК 46 3 мм', '', 'кг', 372, 1500, 'да'],
      ['Уголок 50×5 Ст3', 'ГОСТ 8509-93', 'т', 64800, 0, 'нет'],
    ]);
    price['!cols'] = [{ wch: 34 }, { wch: 18 }, { wch: 6 }, { wch: 10 }, { wch: 10 }, { wch: 8 }];
    const help = XLSX.utils.aoa_to_sheet([
      ['Как заполнять прайс для РЕЗЕРВ'],
      [''],
      ['Колонка', 'Обязательно', 'Что указывать'],
      ['Наименование', 'да', 'Название позиции. Вместе со стандартом определяет, какую позицию обновить'],
      ['Цена', 'да', 'Рубли за единицу, без НДС или с НДС — как у вас принято. Пробелы и «₽» можно оставить'],
      ['Стандарт', 'нет', 'ГОСТ, ТУ или марка'],
      ['Ед.', 'нет', 'т, кг, шт, м, м², м³, л. Если пусто — «т»'],
      ['Остаток', 'нет', 'Сколько есть в наличии. Если пусто — 0 для новых позиций'],
      ['Видна', 'нет', '«да» — позицию видят покупатели, «нет» — скрыта'],
      [''],
      ['Данные читаются с первого листа. Первая строка — заголовки. До 2000 позиций за раз.'],
    ]);
    help['!cols'] = [{ wch: 16 }, { wch: 12 }, { wch: 90 }];
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, price, 'Прайс');
    XLSX.utils.book_append_sheet(wb, help, 'Инструкция');
    XLSX.writeFile(wb, 'rezerv-prais-shablon.xlsx');
  }

  // ── Остатки склада покупателя ──────────────────────────────────────
  const STOCK_COLUMNS = [
    ['use',   ['расходвдень', 'расходдень', 'среднесуточныйрасход', 'расходвсутки', 'расход', 'usage']],
    ['lead',  ['срокпоставки', 'срок', 'leadtime', 'lead']],
    ['sku',   ['артикул', 'кодтовара', 'код', 'арт', 'sku']],
    ['stock', ['остаток', 'фактическийостаток', 'наличие', 'количество', 'колво', 'запас', 'факт', 'stock', 'qty']],
    ['name',  ['наименование', 'название', 'товар', 'позиция', 'номенклатура', 'материал', 'name', 'product']],
    ['unit',  ['едизм', 'единицаизмерения', 'единица', 'ед', 'unit']],
  ];

  // → { rows: [{name, sku, unit, stock, use, lead}], errors, total } или { error }
  async function parseStock(file) {
    if (!/\.(xlsx|xls|csv)$/i.test(file.name)) return { error: 'Поддерживаются файлы .xlsx, .xls и .csv' };
    if (file.size > MAX_SIZE) return { error: 'Файл больше 5 МБ — разбейте его на части' };
    let table, firstRow;
    try { ({ table, firstRow } = await readRows(file)); }
    catch (e) { return { error: 'Не удалось прочитать файл: ' + (e.message || e) }; }
    let headerIdx = -1, cols = null;
    for (let i = 0; i < Math.min(10, table.length); i++) {
      const c = detectColumns(table[i], STOCK_COLUMNS);
      if (c.name != null && c.stock != null) { headerIdx = i; cols = c; break; }
    }
    if (headerIdx < 0) return { error: 'Не нашли заголовки «Наименование» и «Остаток» в первых строках файла — сверьтесь с инструкцией' };
    const rows = [], errors = [];
    const body = table.slice(headerIdx + 1);
    for (let i = 0; i < body.length; i++) {
      const r = body[i] || [], line = firstRow + headerIdx + 1 + i;
      const cell = k => (cols[k] != null ? r[cols[k]] : '');
      const name = String(cell('name') == null ? '' : cell('name')).trim();
      const rawStock = cell('stock');
      if (!name && (rawStock === '' || rawStock == null)) continue;
      if (!name) { errors.push({ line, msg: 'нет наименования' }); continue; }
      if (name.length > 200) { errors.push({ line, msg: 'наименование длиннее 200 символов' }); continue; }
      const stock = parseNumber(rawStock);
      if (stock == null) { errors.push({ line, msg: 'не указан остаток' }); continue; }
      if (isNaN(stock) || stock < 0) { errors.push({ line, msg: 'остаток «' + rawStock + '» — не число' }); continue; }
      let use = null, lead = null;
      if (cols.use != null) { use = parseNumber(cell('use')); if (use != null && (isNaN(use) || use < 0)) { errors.push({ line, msg: 'расход «' + cell('use') + '» — не число' }); continue; } }
      if (cols.lead != null) { lead = parseNumber(cell('lead')); if (lead != null && (isNaN(lead) || lead < 0 || lead > 365)) { errors.push({ line, msg: 'срок поставки — от 0 до 365 дней' }); continue; } if (lead != null) lead = Math.round(lead); }
      rows.push({
        name,
        sku: cols.sku != null ? String(cell('sku') || '').trim().slice(0, 60) : '',
        unit: cols.unit != null ? parseUnit(cell('unit')) : null,
        stock: Math.round(stock * 1000) / 1000, use, lead,
      });
      if (rows.length > MAX_ROWS) return { error: 'В файле больше ' + MAX_ROWS + ' позиций — разбейте его на части' };
    }
    if (!rows.length && !errors.length) return { error: 'В файле нет строк с позициями' };
    return { rows, errors, total: rows.length + errors.length };
  }

  async function downloadStockTemplate() {
    const XLSX = await loadXlsx();
    const data = XLSX.utils.aoa_to_sheet([
      ['Наименование', 'Артикул', 'Ед.', 'Остаток', 'Расход в день', 'Срок поставки, дн.'],
      ['Сталь 09Г2С лист 10 мм', 'MT-0912', 'т', 34, 8.5, 5],
      ['Гранулы ПП 21030', 'PL-2103', 'кг', 5200, 620, 6],
      ['Подшипник 6204-2RS', 'BR-6204', 'шт', 1300, '', 3],
      ['Смазка Литол-24', 'LB-0024', 'кг', 180, '', ''],
    ]);
    data['!cols'] = [{ wch: 30 }, { wch: 12 }, { wch: 6 }, { wch: 10 }, { wch: 14 }, { wch: 18 }];
    const help = XLSX.utils.aoa_to_sheet([
      ['Как заполнять остатки для РЕЗЕРВ'], [''],
      ['Колонка', 'Обязательно', 'Что указывать'],
      ['Наименование', 'да', 'Название позиции. По нему (или по артикулу) находится позиция на складе'],
      ['Остаток', 'да', 'Фактический остаток сейчас. У существующих позиций записывается как инвентаризация'],
      ['Артикул', 'нет', 'Код позиции. Если указан — сначала ищем совпадение по артикулу'],
      ['Ед.', 'нет', 'т, кг, шт, м, м², м³, л. Для новых позиций, если пусто — «т»'],
      ['Расход в день', 'нет', 'Если указан — расход считается вручную. Пусто — считать автоматически по списаниям'],
      ['Срок поставки, дн.', 'нет', 'Сколько дней идёт поставка. Для новых позиций, если пусто — 7'],
      [''], ['Данные читаются с первого листа. Первая строка — заголовки. До 2000 позиций за раз.'],
    ]);
    help['!cols'] = [{ wch: 20 }, { wch: 12 }, { wch: 90 }];
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, data, 'Остатки');
    XLSX.utils.book_append_sheet(wb, help, 'Инструкция');
    XLSX.writeFile(wb, 'rezerv-ostatki-shablon.xlsx');
  }

  window.PriceImport = { parse, downloadTemplate, loadXlsx, parseStock, downloadStockTemplate };
})();
