# CoWork — What This Product Is

One line: it is a chat box. Anyone, even the least technical user, types a problem
into it, and the agent solves the problem. That is the whole product.

## The core promise

The user does not want a process. The user wants the result.

The value is not that the agent runs commands, opens files, or reasons out loud.
The value is that a problem goes in and a finished result comes out. Everything the
user sees between those two points is friction, and friction is what makes a chat
box feel like work instead of magic.

## Rules that follow from this

1. **Deliver the result, not the journey.** The final message is the answer or the
   finished thing. It is not a report of steps, a list of commands, or a tour of
   what went wrong on the way.

2. **Do not narrate problems.** The user does not care that a command failed, that
   a path was wrong, or that the third attempt worked. Retry, route around it, and
   solve it silently. Surface a problem only when the user must decide something
   that the agent genuinely cannot decide alone (a real fork, missing credentials,
   an irreversible money action).

3. **Talk to the user as little as possible.** Every extra message the agent sends
   is a demand on the user's attention. One message at the end beats five along the
   way. If the agent can finish without asking, it finishes without asking.

4. **No apologies, no status updates, no meta.** "I ran into an issue but fixed it"
   is noise. Just hand over the working result. If nothing is broken from the
   user's side, the user hears about nothing.

5. **The dumbest possible input must still work.** A vague, misspelled, one-line
   request is a valid request. The agent figures out intent and delivers, instead
   of interrogating the user for a spec.

## The server is the truth, the client is just a window

The Python server is the product. It runs on the user's own machine and keeps
running whether the app is open or not. The Flutter client is only a window onto
that server.

- **Give a task, close the phone.** The user hands over a task and closes the app.
  The agent keeps working on the Python server. Nothing pauses because the client
  went away.
- **Reinstall anywhere, reconnect automatically.** The user can delete the client
  or reinstall it on a new phone. It signs in, reads the connection info (stored
  encrypted in Supabase), and reconnects to the same running server on its own. No
  re-pairing ritual.
- **Full history comes back from the server.** After reconnect the client shows
  exactly what the agent did — the whole transcript, replayed from the server,
  which is the authoritative store. The client never has to be the source of truth,
  so losing the client loses nothing.
- **Auth flows one way, then refreshes on its own.** The client sends MCP-server
  auth once to the server. The server holds it and refreshes it itself when it
  expires. Both sides can refresh; the server does not depend on a live client to
  stay authenticated.

## Two views, one truth: quiet by default, full log on demand

By default the user sees only results (the section above). But a Settings toggle,
off by default, turns on the full informative view: every command the agent runs,
every MCP call, every Playwright browser action, all as a normal log. The server
always streams these events; the toggle only decides whether the client shows them.
Turning it on never changes what the agent does, only what the user sees.

## The look

The chat UI is the familiar chat-app layout the user already knows, matched
closely. The one deliberate difference is the input box, and the left sidebar: it
lists **agents (coworkers)**, not chats or sessions. There is one long-lived
session per agent; the user treats it as infinite.

## What "done" looks like

The user typed one thing. Some time later, one message came back, and the thing
they wanted exists. They never saw a command, an error, or an excuse — unless they
asked for the full log. And if they threw the client away and came back on a new
phone, everything was still there, waiting.

That is the product working as intended.
