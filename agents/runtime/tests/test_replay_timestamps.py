from chuk_agents_runtime import StateStore


def test_replayed_chat_events_carry_actual_stored_message_time(tmp_path):
    store = StateStore(str(tmp_path / 'state.db'))
    try:
        sid = store.route('timestamp-test')
        store.append_message(sid, 'user', {'role': 'user', 'content': 'Hey'})
        store.append_message(sid, 'assistant', {
            'role': 'assistant', 'content': 'Hello', 'reasoning': 'checking',
        })
        rows = store.get_conversation(sid)
        events = store.replay_events(sid)
        assert [event['type'] for event in events] == ['user', 'reasoning', 'delta']
        assert events[0]['created_at'] == rows[0].created_at
        assert events[1]['created_at'] == events[2]['created_at'] == rows[1].created_at
    finally:
        store.close()
