"""Exclusive, bounded reuse of fully drained model connections."""
from unittest.mock import Mock

from cowork_agent.connection_pool import BackendConnectionPool
from test_backend import MockWsServer, _client, _session


def test_finished_tasks_reuse_auth_and_keep_diagnostics():
    def script(*_):
        return [
            {'kind': 'meta', 'data': {'provider': {'slug': 'test'}}},
            {'kind': 'timing', 'data': {'phase': 'first_token', 'ttft_ms': 12}},
            {'kind': 'content', 'data': 'ok'},
            {'kind': 'usage', 'data': {'prompt_tokens': 50}},
            {'kind': 'tps', 'data': 100.0},
            {'kind': 'timing', 'data': {'phase': 'complete', 'ttft_ms': 12}},
            {'kind': 'done'},
        ]
    server = MockWsServer(script, valid_tokens={'valid-token'})
    pool = BackendConnectionPool()
    try:
        for _ in range(2):
            client = _client(server, _session(), connection_pool=pool)
            response = client.complete([{'role': 'user', 'content': 'hi'}])
            client.close()
            assert response.raw['timing']['server']['phase'] == 'complete'
            assert response.raw['timing']['first_done_ms'] >= response.raw['timing']['first_content_ms']
            assert response.raw['tps'] == 100
        assert server.auth_tokens_seen == ['valid-token']
    finally:
        pool.close()
        server.stop()


def test_pool_exclusive_bounded_and_expiring():
    pool = BackendConnectionPool(max_idle=1)
    a, b = Mock(), Mock()
    key = ('wss://api', 'token')
    try:
        pool.put(key, a)
        timer = pool._idle[0][2]
        pool.put(key, b)
        b.close.assert_called_once()
        assert pool.take(('wss://api', 'other-token')) is None
        assert pool.take(key) is a
        assert pool.take(key) is None  # cannot lease the same socket concurrently
        pool.put(key, a)
        pool._expire(a, timer)  # stale timer must not close a newly returned lease
        a.close.assert_not_called()
        pool._expire(a, pool._idle[0][2])
        a.close.assert_called_once()
        assert pool.take(key) is None
    finally:
        pool.close()


def test_error_stream_is_not_reused():
    server = MockWsServer(lambda *_: [{'kind': 'error', 'detail': 'failed'}, {'kind': 'done'}],
                          valid_tokens={'valid-token'})
    pool = BackendConnectionPool()
    try:
        import pytest
        from cowork_agent.backend import BackendModelError
        client = _client(server, _session(), connection_pool=pool)
        with pytest.raises(BackendModelError):
            client.complete([{'role': 'user', 'content': 'hi'}])
        client.close()
        assert not pool._idle
    finally:
        pool.close()
        server.stop()


def test_return_after_shutdown_closes_socket():
    pool = BackendConnectionPool()
    pool.close()
    ws = Mock()
    pool.put(('url', 'token'), ws)
    ws.close.assert_called_once()
