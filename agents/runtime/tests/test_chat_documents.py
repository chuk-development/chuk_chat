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


ELECTION_CHART = {
    'kind': 'bar', 'title': 'Landtagswahl Sachsen-Anhalt', 'subtitle': 'Zweitstimmen',
    'unit': '%', 'decimals': 1, 'decimal_separator': ',',
    'reference_line': {'value': 5, 'label': '5 % threshold'},
    'source': 'Landeswahlleiter', 'retrieved_at': '2026-09-12T20:15:00Z',
    'points': [{'label': 'AfD', 'value': 43.8, 'color': '#009EE0'},
               {'label': 'CDU', 'value': 17.2, 'color': '#32302E'},
               {'label': 'SPD', 'value': 9.3, 'color': '#E3000F', 'note': 'worst result yet'}],
}


def test_chart_spec_rides_the_chart_kind_and_survives_a_reopen(tmp_path):
    """A spec document is a bar_chart, so every store, panel and file name that
    already knows that kind keeps working; nothing had to learn a new one."""
    path = str(tmp_path / 'state.db')
    store = DocumentStore(path, 'chat')
    doc = store.write('lt26', title='Sachsen-Anhalt', kind='bar_chart', chart=ELECTION_CHART,
                      source_url='https://example.org/lt26', caption='Provisional result')
    assert doc['kind'] == 'bar_chart' and doc['chart'] == ELECTION_CHART
    assert doc['rows'] == []  # the spec is the numbers now, not a second copy
    assert DocumentStore(path, 'chat').read('lt26') == doc

    # A caption-only update keeps the chart: the model does not resend it.
    updated = store.write('lt26', title='', expected_version=1, caption='Final result',
                          source_url=doc['source_url'])
    assert updated['chart'] == ELECTION_CHART and updated['version'] == 2
    assert updated['caption'] == 'Final result'


def test_chart_spec_and_legacy_rows_live_side_by_side(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')
    rows = [{'label': 'AfD', 'value': 43.8, 'color': '#009ee0'}]
    legacy = store.write('old', title='Old', kind='bar_chart', rows=rows)
    assert legacy['rows'] == rows and 'chart' not in legacy
    series = {'kind': 'line', 'unit': '$',
              'series': [{'name': 'BTC', 'direction': 'up',
                          'points': [{'label': 'Mo', 'value': 61200}, {'label': 'Di', 'value': 62800}]}]}
    assert store.write('new', title='New', kind='bar_chart', chart=series)['chart'] == series


def test_a_malformed_chart_is_named_not_silently_trimmed(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')

    cases = [
        ({'points': []}, 'points array'),
        ({'points': [{'label': 'A', 'value': float('nan')}]}, 'finite number'),
        ({'points': [{'label': 'A', 'value': True}]}, 'finite number'),
        ({'points': [{'label': ' ', 'value': 1}]}, 'needs a label'),
        ({'points': [{'label': 'A', 'value': 1, 'color': 'blue'}]}, 'hex color'),
        ({'points': [{'label': 'A', 'value': 1, 'colour': '#009EE0'}]}, 'unknown keys'),
        ({'kind': 'pie', 'points': [{'label': 'A', 'value': 1}]}, 'kind must be one of'),
        ({'points': [{'label': 'A', 'value': 1}], 'series': []}, 'either points'),
        ({}, 'either points'),
        ({'points': [{'label': 'A', 'value': 1}], 'axis': {'min': 10, 'max': 1}}, 'below max'),
        ({'points': [{'label': 'A', 'value': 1}], 'decimals': 9}, 'decimals'),
        ({'series': [{'points': [{'label': 'A', 'value': 1}], 'direction': 'sideways'}]}, 'direction'),
        ({'series': [{'name': 'S'}]}, 'points array'),
        ({'points': [{'label': 'A', 'value': 1}], 'reference_line': {'label': 'x'}}, 'reference_line value'),
    ]
    for chart, message in cases:
        with pytest.raises(ValueError, match=message):
            store.write('chart', title='Chart', kind='bar_chart', chart=chart)
    assert store.list() == []  # nothing half-written

    with pytest.raises(ValueError, match='kind=bar_chart'):
        store.write('note', title='Note', kind='markdown', chart=ELECTION_CHART)


def test_the_tool_takes_a_chart_and_the_description_teaches_the_contract(tmp_path):
    store = DocumentStore(str(tmp_path / 'state.db'), 'chat')
    registry, files = ToolRegistry(), []
    register_document_tool(registry, store, files.append)
    result = registry.dispatch('chat_document', {'action': 'write', 'id': 'lt26', 'title': 'LT26',
                                                 'kind': 'bar_chart', 'chart': ELECTION_CHART})
    assert result['saved'] and files[-1].document['chart'] == ELECTION_CHART
    assert files[-1].name.endswith('.json')

    description = registry.spec('chat_document').schema['description']
    for phrase in ('DESCRIBE the chart', 'no image', 'ONE document', 'in the chat message',
                   '"label":"AfD","value":43.8', 'column_delta'):
        assert phrase in description
