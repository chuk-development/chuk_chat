# Gateways: talk to your agents from a chat app

CHAT-184. A gateway connects the Agents host to a chat network. You can then
talk to your agents without the Agents app. Telegram is the first gateway.
The code is in `agents/host/src/chuk_agents_host/gateways/`.

## What it does

- You send a message to your own Telegram bot. The host starts a run of your
  agent. This is the same run that a message from the app starts.
- The answer comes back into one Telegram message. The host edits this
  message while the agent writes. The host edits it at most every 1.5
  seconds. An answer longer than 4096 characters comes as more messages.
- An approval (for example "send this mail") comes as a message with
  buttons: **Allow once**, **Always** and **Skip**. The app shows the same
  approval. The first answer counts.
- A photo or a document that you send goes into the agent workspace, in the
  folder `telegram/`. The message to the agent names the file.
- A file that the agent sends to you comes as a Telegram document.
- The conversation is also in the app. It is a chat of the agent.

## Set it up

1. In Telegram, open `@BotFather`. Send `/newbot` and follow the steps. You
   get a token. It looks like `123456:ABC-xyz`.
2. On the computer of the host, store the token:

   ```bash
   agents-host telegram token
   ```

   Paste the token at the hidden prompt. You can also pipe it in:
   `agents-host telegram token < file`. Do not put the token on the command
   line. Other users of the computer can read a command line.
3. Restart the host: `systemctl --user restart agents-manager`.
4. Make a pairing code:

   ```bash
   agents-host telegram pair
   ```

5. In Telegram, send `/pair <code>` to your bot within 10 minutes.

The host must have a connection to the app one time after each restart.
Until then the bot answers: "The Agents host is not ready yet."

Other commands:

| Command | What it does |
|---|---|
| `agents-host telegram status` | Shows if a token is stored and who is paired. |
| `agents-host telegram unpair <user id>` | Removes one paired user. |
| `agents-host telegram off` | Deletes the token. Restart the host after it. |

The token can also come from the host secret `TELEGRAM_BOT_TOKEN` (the
Secrets page of the app). The stored token from `telegram token` wins. Use
`telegram token` if you can: a host secret can go into the sandbox of an
agent, the stored token cannot.

`AGENTS_GATEWAYS=0` turns off all gateways.

## Commands in Telegram

| Command | What it does |
|---|---|
| `/pair <code>` | Pairs your Telegram account with the host. |
| `/agent` | Shows the agents. A star marks the current agent. |
| `/agent <name>` | You talk to this agent from now on. |
| `/new` | Starts a new conversation with the current agent. |
| `/stop` | Stops the run of the current conversation. |
| `/help` | Shows the commands. |

Each Telegram chat has one conversation for each agent. Its thread key on the
host is `<agent id>#auto-telegram-<random>`. The host and the app read the
agent from the part before `#auto-`. Thus the run uses the sandbox, the
workspace and the model of that agent. `/new` makes a new thread key.

## Security model

- **Only paired users.** The host keeps a list of Telegram user ids. A
  message from any other user starts nothing. That user gets one short
  refusal ("This bot is private.") at most one time in each hour. All
  refusals together are at most 20 in each minute.
- **Pairing codes.** A code has 8 characters, works one time and expires
  after 10 minutes. The host stores only the SHA-256 of the code. After 5
  wrong codes in 10 minutes, the bot ignores `/pair` from that user.
- **Private chats only.** The bot ignores groups. In a group, other members
  could read the answers.
- **Buttons.** A button works only for a paired user, only in the chat of
  the approval, and only while the approval is open.
- **The token.** The token is stored with AES-256-GCM in
  `<host state>/gateways/telegram-token.enc` (mode 0600). The key comes from
  the host identity (`host_device.key`) with HKDF and its own label. No log
  line, error text or status output contains the token. The Bot API puts the
  token in each URL. Thus the client never writes a URL or an httpx error
  text into an error.
- **The state file** `<host state>/gateways/telegram.json` (mode 0600) holds
  the paired user ids, the code hashes, the routes and the poll offset. The
  CLI and the host change it under a file lock.
- **Incoming files.** The agent controls its workspace. Thus the host opens
  `telegram/` and the file with `O_NOFOLLOW`, and the file with `O_EXCL`.
  A symlink that the agent made cannot send the file to another place. A
  file can be at most 20 MB (the Bot API limit).
- **Same rules as the app.** A Telegram run has `origin: telegram`. It has
  the same approvals, sandbox and budget as a run from the app. It does not
  get the rights of an app message (for example `user_requested` mail).
- **Telegram sees the text.** Telegram is not end-to-end encrypted for bots.
  Telegram can read the messages, the answers and the files. Do not use the
  gateway for data that Telegram must not see.

## Add a new gateway (Matrix, Discord)

1. Make a class that extends `Gateway` (`gateways/base.py`): `start`,
   `stop`, `status`, `owns_run`.
2. Use only `GatewayHost` to talk to the host: `ready`, `subscribe`,
   `submit`, `stop`, `resolve_approval`, `agents`, `default_agent`,
   `workspace_for`, `secret`. `HostBridge` (`gateways/host_bridge.py`)
   is the real one.
3. Use `GatewayStore` for paired users, routes and codes, and `TokenStore`
   for the secret. Give the gateway its own name.
4. Add it to `build_gateways` (`gateways/__init__.py`). It must be off
   until its secret exists.

The executor gives the events of a run to `add_event_listener`. A listener
gets each event as plaintext after the secret scrub, with `run_id` and
`session_key`. It runs on the thread of the run, so it must return fast. The
Telegram gateway only puts the event into a queue.

## Open points

- `ask_user` questions do not come to Telegram. Answer them in the app.
- A browser takeover only shows a note and a **Skip** button.
- The gateway reads the token when the host starts. After a change, restart
  the host.
