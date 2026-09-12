"""Streaming must stay incremental and may not silently replay partial turns."""

import json

import pytest
from websockets.exceptions import ConnectionClosedError

from cowork_agent.backend import BackendModelClient, BackendModelError
from test_backend import _session


class Socket:
    def __init__(self, frames):
        self.frames = iter(frames)
        self.request = None
        self.closed = False

    def send(self, raw):
        frame = json.loads(raw)
        if frame['type'] == 'chat':
            self.request = frame['req_id']

    def recv(self, **kwargs):
        frame = next(self.frames)
        if isinstance(frame, Exception):
            raise frame
        if 'kind' in frame:
            frame = {**frame, 'req_id': self.request}
        return json.dumps(frame)

    def close(self):
        self.closed = True


@pytest.mark.parametrize('kind', ['content', 'reasoning', 'tool_calls'])
@pytest.mark.parametrize('failure', ['disconnect', 'auth'])
def test_partial_output_is_not_silently_replayed(kind, failure):
    data = [{'id': 'one'}] if kind == 'tool_calls' else 'partial'
    end = (ConnectionClosedError(None, None) if failure == 'disconnect'
           else {'kind': 'error', 'code': 'auth_error', 'detail': 'token expired'})
    ws = Socket([{'type': 'auth_ok'}, {'kind': kind, 'data': data}, end])
    connections = []

    def connect(*args, **kwargs):
        connections.append(ws)
        return ws

    client = BackendModelClient(_session(), model_id='m', provider_slug='p', connect=connect)
    with pytest.raises(BackendModelError) as error:
        client.complete([{'role': 'user', 'content': 'Hi'}])
    assert error.value.code == 'stream_interrupted'
    assert len(connections) == 1
    assert ws.closed


def test_idle_connection_drop_still_retries_before_output():
    sockets = [Socket([{'type': 'auth_ok'}, ConnectionClosedError(None, None)]),
               Socket([{'type': 'auth_ok'}, {'kind': 'content', 'data': 'Hi'},
                       {'kind': 'done'}])]
    connections = []

    def connect(*args, **kwargs):
        ws = sockets[len(connections)]
        connections.append(ws)
        return ws

    client = BackendModelClient(_session(), model_id='m', provider_slug='p', connect=connect)
    try:
        assert client.complete([{'role': 'user', 'content': 'Hi'}]).text == 'Hi'
        assert len(connections) == 2
    finally:
        client.close()


def test_tokens_reach_sink_before_next_frame_and_done():
    seen = []

    class CheckedSocket(Socket):
        def recv(self, **kwargs):
            frame = super().recv(**kwargs)
            kind = json.loads(frame).get('kind')
            if kind == 'content':
                assert seen == [('reasoning', 'thinking')]
            if kind == 'done':
                assert seen == [('reasoning', 'thinking'), ('content', 'answer')]
            return frame

    ws = CheckedSocket([{'type': 'auth_ok'},
                        {'kind': 'reasoning', 'data': 'thinking'},
                        {'kind': 'content', 'data': 'answer'}, {'kind': 'done'}])
    client = BackendModelClient(_session(), model_id='m', provider_slug='p',
                                connect=lambda *a, **k: ws)
    client.on_reasoning = lambda text: seen.append(('reasoning', text))
    client.on_delta = lambda text: seen.append(('content', text))
    try:
        assert client.complete([{'role': 'user', 'content': 'Hi'}]).text == 'answer'
    finally:
        client.close()
