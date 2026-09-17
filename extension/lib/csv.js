// Reads the password CSV exported by Chrome, Safari, Edge, Brave or Firefox.
// Same rules as core/Sources/SafelyCore/CSVImport.swift.

export function parseRows(text) {
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ',') {
      row.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field);
      field = '';
      if (!(row.length === 1 && row[0] === '')) rows.push(row);
      row = [];
    } else {
      field += c;
    }
  }
  if (field !== '' || row.length) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

export function parsePasswordCsv(text) {
  const rows = parseRows(text);
  if (!rows.length) return [];
  const columns = rows[0].map((c) => c.trim().toLowerCase());
  const find = (...names) => names.map((n) => columns.indexOf(n)).find((i) => i >= 0) ?? -1;

  const urlCol = find('url', 'website', 'login_uri');
  const userCol = find('username', 'login', 'login_username');
  const passCol = find('password', 'login_password');
  const titleCol = find('name', 'title');
  const notesCol = find('note', 'notes');
  if (urlCol < 0 || userCol < 0 || passCol < 0) return [];

  const items = [];
  for (const row of rows.slice(1)) {
    const at = (i) => (i >= 0 && i < row.length ? row[i] : '');
    if (!at(passCol) || !at(urlCol)) continue;
    const item = { title: at(titleCol), url: at(urlCol), username: at(userCol), password: at(passCol) };
    if (at(notesCol)) item.notes = at(notesCol);
    items.push(item);
  }
  return items;
}

/** Groups items so each sealed message stays well below the 40 KB transport limit. */
export function batches(items, maxBytes = 6000) {
  const out = [];
  let current = [];
  let size = 0;
  for (const item of items) {
    const itemSize = JSON.stringify(item).length * 1.4 + 8;
    if (current.length && size + itemSize > maxBytes) {
      out.push(current);
      current = [];
      size = 0;
    }
    current.push(item);
    size += itemSize;
  }
  if (current.length) out.push(current);
  return out;
}
