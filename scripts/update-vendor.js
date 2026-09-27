// Обновить библиотеки в site/vendor из node_modules.
// Нужно только при обновлении версий:  npm install  →  npm run vendor  →  закоммитить site/vendor
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const files = {
  'site/vendor/supabase.js': 'node_modules/@supabase/supabase-js/dist/umd/supabase.js',
  'site/vendor/xlsx.js': 'node_modules/xlsx/dist/xlsx.full.min.js',
};
for (const [to, from] of Object.entries(files)) {
  fs.copyFileSync(path.join(root, from), path.join(root, to));
  console.log(from, '→', to);
}
