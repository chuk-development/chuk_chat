"""Versioned documents scoped to a chat, independent of model context/memory."""
from __future__ import annotations

import json
from contextlib import contextmanager
import re
import sqlite3
import time
from pathlib import Path

from .files_out import FileSink, SentFile, sanitize_name
from .registry import ToolRegistry

MAX_DOCUMENT_BYTES = 256 * 1024
_ID = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$')


class DocumentStore:
    def __init__(self, db_path: str, session_key: str):
        self.path = db_path
        self.session = session_key
        with self._connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS chat_documents (
                session_key TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
                PRIMARY KEY(session_key, id))''')

    @contextmanager
    def _connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        try:
            with db:
                yield db
        finally:
            db.close()

    def list(self) -> list[dict]:
        with self._connect() as db:
            return [json.loads(row[0]) for row in db.execute(
                'SELECT payload FROM chat_documents WHERE session_key=? ORDER BY id', (self.session,))]

    def read(self, document_id: str) -> dict:
        with self._connect() as db:
            row = db.execute('SELECT payload FROM chat_documents WHERE session_key=? AND id=?',
                             (self.session, document_id)).fetchone()
        if row is None:
            raise ValueError('Document not found in this chat; use action=list.')
        return json.loads(row[0])

    def write(self, document_id: str, *, title: str, kind: str | None = None, text: str = '',
              columns: list | None = None, rows: list | None = None,
              expected_version: int | None = None, append: bool = False,
              row_key: str | None = None, source_url: str = '',
              retrieved_at: str = '', caption: str = '') -> dict:
        if not _ID.fullmatch(document_id):
            raise ValueError('Use a short document id with letters, numbers, dots, underscores or hyphens.')
        with self._connect() as db:
            db.execute('BEGIN IMMEDIATE')
            old_row = db.execute('SELECT payload FROM chat_documents WHERE session_key=? AND id=?',
                                 (self.session, document_id)).fetchone()
            old = json.loads(old_row[0]) if old_row else None
            kind = kind if kind is not None else (old['kind'] if old else 'markdown')
            if kind not in ('table', 'markdown', 'text', 'bar_chart'):
                raise ValueError('kind must be table, markdown, text or bar_chart')
            if kind in ('markdown', 'text') and (rows is not None or columns is not None):
                raise ValueError('rows/columns require kind=table or kind=bar_chart; no data was saved')
            title = title or (old['title'] if old else document_id)
            if old and columns is None and kind == old['kind'] == 'table':
                columns = old['columns']
            version = old['version'] if old else 0
            if old and expected_version != version:
                raise ValueError(f'Document changed: read version {version} before updating.')
            if not old and expected_version not in (None, 0):
                raise ValueError('Document does not exist; expected_version must be 0.')
            if append:
                if not old or old['kind'] != 'table':
                    raise ValueError('append requires an existing table')
                kind, columns = 'table', old['columns']
                title = title or old['title']
                combined = list(old['rows'])
                for row in rows or []:
                    if row_key and row_key in row:
                        combined = [r for r in combined if r.get(row_key) != row[row_key]]
                    combined.append(row)
                rows = combined
            if kind == 'table':
                if (not columns or len(columns) > 30 or
                        any(not isinstance(c, str) or not c.strip() for c in columns) or
                        len(set(columns)) != len(columns)):
                    raise ValueError('Table needs 1-30 distinct column names')
                if row_key and row_key not in columns:
                    raise ValueError('row_key must name a table column')
                if not isinstance(rows, list) or len(rows) > 2000:
                    raise ValueError('Table needs a rows array (at most 2000 rows)')
                if any(not isinstance(r, dict) or set(r) - set(columns) or
                       any(not isinstance(v, (str, int, float, bool, type(None))) for v in r.values())
                       for r in rows):
                    raise ValueError('Rows must map column names to text, numbers, booleans or null')
            if kind == 'bar_chart':
                if not isinstance(rows, list) or not 1 <= len(rows) <= 20:
                    raise ValueError('Chart needs 1-20 rows: label, value (percent), color (#RRGGBB)')
                for row in rows:
                    if (not isinstance(row, dict) or not isinstance(row.get('label'), str)
                            or not row['label'].strip()
                            or type(row.get('value')) not in (int, float)
                            or not 0 <= row['value'] <= 100
                            or not re.fullmatch(r'#[0-9A-Fa-f]{6}', str(row.get('color', '')))):
                        raise ValueError('Each chart row needs label, percentage 0-100 and color #RRGGBB')
            now = time.time()
            doc = {'id': document_id, 'session_key': self.session,
                   'title': (title.strip() or document_id)[:160], 'kind': kind,
                   'version': version + 1, 'created_at': old['created_at'] if old else now,
                   'updated_at': now}
            if kind == 'table':
                doc.update(columns=columns, rows=rows, source_url=source_url,
                           retrieved_at=retrieved_at, caption=caption)
            elif kind == 'bar_chart':
                doc.update(rows=rows, source_url=source_url, retrieved_at=retrieved_at, caption=caption)
            else:
                doc['text'] = text
            raw = json.dumps(doc, ensure_ascii=False, allow_nan=False)
            if len(raw.encode()) > MAX_DOCUMENT_BYTES:
                raise ValueError('Document exceeds 256 KiB; split it into smaller documents')
            db.execute('INSERT INTO chat_documents VALUES(?,?,?) ON CONFLICT(session_key,id) '
                       'DO UPDATE SET payload=excluded.payload', (self.session, document_id, raw))
        return doc


def document_file(doc: dict) -> SentFile:
    data = json.dumps(doc, ensure_ascii=False).encode()
    return SentFile(name=sanitize_name(doc['title'] + ('.json' if doc['kind'] in ('table', 'bar_chart') else '.md')),
                    mime_type='application/vnd.cowork.document+json', size=len(data), data=data,
                    document=doc)


def register_document_tool(registry: ToolRegistry, store: DocumentStore, sink: FileSink):
    def chat_document(action: str, id: str = '', title: str = '', kind: str | None = None,
                      text: str = '', columns: list | None = None, rows: list | None = None,
                      expected_version: int | None = None, row_key: str | None = None,
                      source_url: str = '', retrieved_at: str = '', caption: str = ''):
        if action == 'list':
            return [{k: d[k] for k in ('id', 'title', 'kind', 'version')} for d in store.list()]
        if action == 'read':
            return store.read(id)
        if action not in ('write', 'append'):
            raise ValueError('action must be list, read, write or append')
        doc = store.write(id, title=title, kind=kind, text=text, columns=columns, rows=rows,
                          expected_version=expected_version, append=action == 'append', row_key=row_key,
                          source_url=source_url, retrieved_at=retrieved_at, caption=caption)
        # Persistence precedes UI delivery: a reconnect can always recover it.
        try:
            sink(document_file(doc))
            delivered = True
        except Exception:
            delivered = False
        return {'id': doc['id'], 'version': doc['version'], 'saved': True, 'ui_delivered': delivered}

    registry.register('chat_document', {
        'type': 'object',
        'description': 'Create/update persistent tables and Markdown documents visible in the chat Documents panel. '
                       'Separate from semantic memory: documents survive context compaction and task restarts. '
                       'Use list/read to recover earlier documents. Read before updating and pass expected_version. '
                       'A document NEVER replaces the answer: the reader must see the result in the message itself, '
                       'as a Markdown table when it is tabular. Write the document as well only when the numbers '
                       'have to survive a restart or be updated again later; do not split one result over several '
                       'documents, and do not answer with a document reference alone. '
                       'For song collections, keep Reel URL, Spotify search URL, song and artist in a table; '
                       'append with row_key to replace an existing row for the same Reel. '
                       'For a result tracked over time (an election night, a running count), keep ONE document: '
                       'rows with label, value (actual percentage, never renormalize), color (#RRGGBB), distinct '
                       'party colors, exact source_url and retrieved_at. Say in the caption if it holds only the '
                       'largest parties, and put the complete numbers in the message.',
        'properties': {
            'action': {'type': 'string', 'enum': ['list', 'read', 'write', 'append']},
            'id': {'type': 'string'}, 'title': {'type': 'string'},
            'kind': {'type': 'string', 'enum': ['table', 'markdown', 'text', 'bar_chart'],
                     'description': 'Omit on updates to retain the existing document type. Set explicitly when creating a table or chart.'},
            'text': {'type': 'string'},
            'columns': {'type': 'array', 'items': {'type': 'string'}},
            'rows': {'type': 'array', 'items': {'type': 'object'}},
            'expected_version': {'type': 'integer'}, 'row_key': {'type': 'string'},
            'source_url': {'type': 'string'}, 'retrieved_at': {'type': 'string'},
            'caption': {'type': 'string'},
        }, 'required': ['action'],
    }, chat_document)


DOCUMENT_SUFFIXES = {'.md', '.txt', '.csv', '.pdf', '.docx', '.xlsx', '.pptx', '.html', '.svg'}


def workspace_documents(root: str | None) -> list[dict]:
    """Read-only inventory; hidden/internal trees and escaping symlinks stay out."""
    if not root:
        return []
    import os
    base = Path(root).resolve()
    out = []
    for parent, dirs, files in os.walk(base, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not d.startswith('.') and d not in ('node_modules', '__pycache__'))
        for name in sorted(files):
            path = Path(parent) / name
            if name.startswith('.') or path.suffix.lower() not in DOCUMENT_SUFFIXES:
                continue
            resolved = path.resolve()
            if not resolved.is_relative_to(base) or not resolved.is_file():
                continue
            stat = resolved.stat()
            out.append({'id': 'file:' + path.relative_to(base).as_posix(), 'title': name,
                        'kind': 'file', 'path': path.relative_to(base).as_posix(),
                        'size': stat.st_size, 'updated_at': stat.st_mtime})
            if len(out) >= 500:
                return out
    return out


def read_workspace_document(root: str, document_id: str) -> dict:
    import base64
    import mimetypes
    base = Path(root).resolve()
    path = (base / document_id.removeprefix('file:')).resolve()
    if not path.is_relative_to(base) or not path.is_file() or path.suffix.lower() not in DOCUMENT_SUFFIXES:
        raise ValueError('Not a workspace document')
    if any(part.startswith('.') for part in path.relative_to(base).parts):
        raise ValueError('Internal files are not documents')
    if path.stat().st_size > 8 * 1024 * 1024:
        raise ValueError('Document exceeds the 8 MiB download limit')
    data = path.read_bytes()
    if len(data) > 8 * 1024 * 1024:
        raise ValueError('Document exceeds the 8 MiB download limit')
    return {'id': document_id, 'title': path.name, 'kind': 'file',
            'mime': mimetypes.guess_type(path.name)[0] or 'application/octet-stream',
            'data': base64.b64encode(data).decode(), 'size': len(data)}
