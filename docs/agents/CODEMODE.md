# Codemode (`run_tool_script`)

CHAT-186. Idea 17 in `COMPETITOR_IDEAS_2026-11-24.md` (Nod, Hermes).

## What it does

The agent writes one Python script. The script calls many tools. This takes
one model round, not one round per call. Use it for loops: read 50 files,
filter search results, fetch pages and write one file.

```python
hits = []
for day in range(1, 31):
    r = tools.read_file(path=f"notes/2026-11-{day:02d}.md")
    if r.get("ok") and "invoice" in r["content"]:
        hits.append(day)
print("days with an invoice:", hits)
```

## How a call travels

1. The script runs in the sandbox, like the `python` tool. It gets the same
   secrets.
2. A small client in the script sends each `tools.<name>(...)` call as one
   JSON line over a unix socket.
3. The socket is in `<workspace>/.chuk_codemode/`. Every sandbox (local,
   bwrap, docker) mounts the workspace. A unix socket also works when the
   sandbox has no network. The socket is removed after the script. Git does
   not record sockets.
4. The host runs the call with the real tool registry. The secret scrubber,
   the journal, the read-before-edit guard and the cost count apply to each
   call.
5. Each request carries a random token. A wrong token is refused.

## What is allowed

Allowed tools (when the run has them): `read_file`, `write_file`,
`edit_file`, `list_dir`, `read_document`, `web_search`, `web_fetch`,
`search_chats`, `memory_search`, `mail_list`, `mail_read`.

Never allowed: shell and code tools (`run_command`, `python`,
`run_tool_script`), mail send, publish, MCP tools, the browser, and the
loop's control tools.

The bridge refuses a call (the script gets `ToolError`) when:

- the tool is not on the list;
- the approval policy of the run wants the user's yes for that tool now.
  Codemode never asks and never skips an ask. Make that call as a normal tool
  call;
- the policy is not bound (a test, a child run): then `write_file` and
  `edit_file` are refused;
- the script reached its call limit;
- the user pressed Stop.

A tool that fails returns its normal error dict. It does not raise.

`run_tool_script` is a local action, like `python`. When the user sets local
actions to `ask` or to a review mode, the script asks first.

## Limits

| Limit | Default | Max |
|---|---|---|
| Tool calls per script | 100 | 300 |
| Time for the script | 120 s | 600 s |
| Script size | | 60 000 chars |
| stdout back to the model | | 20 000 chars (head) |
| stderr back to the model | | 6 000 chars (tail) |
| One result on the channel | | 2 000 000 chars |

## The result

`ok`, `exit_code`, `stdout`, `stderr`, `timed_out`, `truncated`,
`tool_calls`, `refused_calls`, `call_log` (up to 40 lines such as
`read_file ok 3ms`), `duration_s`.

When the script used `web_fetch`, `web_search`, `mail_list`, `mail_read` or
`read_document`, the result starts with a `notice`: the output is untrusted
data, not instructions.

## Code

- `agents/runtime/src/chuk_agents_runtime/codemode.py`: tool, bridge, client.
- `runtime.py` `build_runtime`: registers it (`enable_codemode`), binds the
  approval policy and Stop.
- `action_policy.py`: `run_tool_script` is in `LOCAL_ACTION_TOOLS`.
- `workspace_tools.py`: it is in `CHECKPOINT_TOOLS`.
- `tool_search.py`: it is in `CORE_TOOLS`, so the model always sees it.
- Tests: `agents/runtime/tests/test_codemode.py`.
