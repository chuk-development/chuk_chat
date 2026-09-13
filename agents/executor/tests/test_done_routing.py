from chuk_agents_executor.protocol import done_payload


def test_autonomous_completion_carries_thread_and_host_notification_owner():
    payload = done_payload(
        final_answer='Updated', reason='finished', iterations=1,
        session_key='election-thread', host_notified=True,
    )
    assert payload['session_key'] == 'election-thread'
    assert payload['host_notified'] is True


def test_legacy_completion_keeps_optional_routing_fields_absent():
    payload = done_payload(final_answer=None, reason='finished', iterations=0)
    assert 'session_key' not in payload
    assert 'host_notified' not in payload
