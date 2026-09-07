import json

import pytest

from cowork_agent.chat_documents import DocumentStore, register_document_tool, workspace_documents, read_workspace_document
from cowork_agent.registry import ToolRegistry


def test_table_survives_reopen_and_is_scoped_to_chat(tmp_path):
    path = str(tmp_path / 'state.db')
    store = DocumentStore(path, 'chat-1')
    store.write('songs', title='Songs', kind='table', columns=['Reel', 'Song'],
                rows=[{'Reel': 'https://instagram.com/reel/a', 'Song': 'First'}])
    reopened = DocumentStore(path, 'chat-1')
    assert reopened.read('songs')['rows'][0]['Song'] == 'First'
    assert DocumentStore(path, 'chat-2').list() == []
    with pytest.raises(ValueError, match='changed'):
        reopened.write('songs', title='Songs', kind='table', columns=['Reel', 'Song'], rows=[])
    doc = reopened.write('songs', title='', kind='table', append=True, expected_version=1,
                         row_key='Reel', rows=[{'Reel': 'https://instagram.com/reel/a', 'Song': 'Corrected'}])
    assert doc['version'] == 2
    assert doc['rows'] == [{'Reel': 'https://instagram.com/reel/a', 'Song': 'Corrected'}]


def test_tool_emits_full_snapshot_and_failed_delivery_does_not_lose_it(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')
    registry = ToolRegistry()
    files = []
    register_document_tool(registry, store, files.append)
    result = registry.dispatch('chat_document', {'action': 'write', 'id': 'notes',
                                'title': 'Notes', 'text': '# Remember this'})
    assert result['saved'] and result['ui_delivered']
    assert json.loads(files[0].data) == files[0].document == store.read('notes')
    assert 'text' not in result  # document contents do not balloon every tool round


def test_workspace_inventory_and_reads_do_not_escape_root(tmp_path):
    root = tmp_path / 'workspace'
    root.mkdir()
    (root / 'report.md').write_text('# Report')
    (root / '.private').mkdir()
    (root / '.private' / 'private.md').write_text('secret')
    outside = tmp_path / 'outside.md'
    outside.write_text('outside')
    (root / 'escape.md').symlink_to(outside)
    assert [d['id'] for d in workspace_documents(str(root))] == ['file:report.md']
    assert read_workspace_document(str(root), 'file:report.md')['size'] == 8
    for path in ('file:../outside.md', 'file:escape.md', 'file:.private/private.md'):
        with pytest.raises(ValueError):
            read_workspace_document(str(root), path)


def test_chart_preserves_percentages_colors_and_source_across_updates(tmp_path):
    from cowork_agent.chat_documents import document_file
    store = DocumentStore(str(tmp_path / 'state.db'), 'election')
    rows = [{'label': name, 'value': value, 'color': color} for name, value, color in (
        ('Party A', 32.1, '#112233'), ('Party B', 24.5, '#ee2200'),
        ('Party C', 18.0, '#33aa55'), ('Party D', 8.3, '#aa22cc'))]
    doc = store.write('results', title='Election', kind='bar_chart', rows=rows,
                      source_url='https://example.org/results', retrieved_at='2026-09-06T18:00:00Z',
                      caption='Four strongest parties; test data')
    assert doc['rows'] == rows  # a subset must never be rescaled to 100%
    assert document_file(doc).name.endswith('.json')
    rows[0] = dict(rows[0], value=33.1)
    updated = store.write('results', title='Election', kind='bar_chart', rows=rows,
                          expected_version=1, source_url=doc['source_url'])
    assert updated['version'] == 2
    assert len(store.list()) == 1
    assert DocumentStore(str(tmp_path / 'state.db'), 'election').read('results') == updated
    for invalid in (-1, 101, True, float('nan'), float('inf')):
        with pytest.raises(ValueError, match='percentage'):
            store.write('bad', title='Bad', kind='bar_chart',
                        rows=[{'label': 'Party', 'value': invalid, 'color': '#112233'}])
    with pytest.raises(ValueError, match='color'):
        store.write('bad', title='Bad', kind='bar_chart',
                    rows=[{'label': 'Party', 'value': 10, 'color': 'red'}])


def test_tool_update_without_kind_preserves_chart_and_emits_chart(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')
    registry, files = ToolRegistry(), []
    register_document_tool(registry, store, files.append)
    rows = [{'label': 'A', 'value': 44.9, 'color': '#80cdec'}]
    registry.dispatch('chat_document', dict(action='write', id='chart', title='Results',
                      kind='bar_chart', rows=rows))
    registry.dispatch('chat_document', dict(action='write', id='chart',
                      expected_version=1, rows=rows, caption='New count'))
    doc = store.read('chart')
    assert doc['kind'] == 'bar_chart'
    assert doc['title'] == 'Results'
    assert doc['rows'] == rows
    assert files[-1].document == doc
    assert doc['version'] == 2


def test_text_write_rejects_structured_rows_without_destroying_document(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')
    original = store.write('note', title='Note', text='Keep me')
    with pytest.raises(ValueError, match='rows/columns'):
        store.write('note', title='', rows=[{'label': 'A', 'value': 10}], expected_version=1)
    assert store.read('note') == original
