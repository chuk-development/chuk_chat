# Hand test: connect an MCP connector and prove the backend got the token

Five steps, about two minutes. It proves the whole chain: the device signs in
through a browser, keeps the refresh material, forwards it in the sealed task
frame, and the Python backend calls the server with it — and renews it by
itself when the app is closed.

Use a Google connector (Google Drive or Gmail) or Notion. Any catalogue entry
marked as an OAuth connector works.

## 1. Open the connectors page

In the app: Settings, then Connectors. The catalogue lists 54 servers. They are
the same servers as chuk_chat. Find the connector you want under its category.

## 2. Press Connect

The app opens a browser. On Android and iOS it is an in-app tab. On Linux it is
a browser window.

What must happen: the provider's own sign-in page opens, on the provider's own
domain. The address bar shows a `redirect_uri` of `http://127.0.0.1:<port>/mcp/callback`.
That loopback address is the app itself listening on this machine. Nothing goes
to a server of ours.

If no browser opens, the test stops here. Report it.

## 3. Sign in and approve

Sign in with your account and approve the access the provider asks for.

The browser then shows one line: "Connected. You can close this tab and go back
to CoWork." On Android and iOS the tab closes by itself.

Back in the app the connector moves to the "Connected" section. That means the
token exchange worked and the record is in the OS keychain — access token,
refresh token, token endpoint and the client the app registered.

If the browser instead shows the provider's error page, the provider refused
this app. Report which connector, and the error text.

## 4. Make the backend use it

Open any agent chat and ask for something only that connector can answer.

For Google Drive: "list my five most recent Drive files".
For Gmail: "how many unread mails do I have".
For Notion: "list my Notion pages".

A real answer with your own data proves the backend has a working token: the
app forwarded it inside the sealed task frame, the executor put it on the
`Authorization` header, and the server accepted it.

An answer of the shape "the connector refused the token" or "401" means the
token did not arrive, or arrived dead. Report the exact wording.

## 5. Prove the backend renews the token on its own

This is the part that makes the app disposable.

1. Close the app completely.
2. Wait for longer than the provider's access-token lifetime. Google is one
   hour. Notion does not expire, so use Google for this step.
3. Open the app again and ask the same question as in step 4.

A real answer means the backend minted a new access token itself, from the
refresh token, with nobody signed in and no browser open. That is the whole
point of the change.

A faster version of the same proof, if you do not want to wait an hour: ask the
question, then leave the chat open and idle for over an hour, then ask again in
the same chat. The second answer runs on a token the backend made.

## If something fails

| What you see | What it means |
|---|---|
| No browser opens | The device could not start the sign-in. The connector never reached the OAuth flow. |
| The browser shows the provider's error page | The provider refused to register this app, or refused the loopback redirect. Some providers only allow a fixed list of apps. |
| "Sign-in was cancelled" | The flow was closed before the provider answered. Press Connect again. |
| The connector shows as connected but the agent says 401 | The token reached the backend and the server refused it. Disconnect the connector and connect it again. |
| The agent says the connector is not configured | The connector was not forwarded. Check that it is in the Connected section. |

## What is stored where

- The access token, the refresh token, the token endpoint and the registered
  client id stay in the OS keychain of this device, under `mcp_secrets_<id>`.
- The same record is mirrored to Supabase, encrypted on this device first. Only
  ciphertext is stored there. That is what lets you delete the app, install it
  again, sign in, and find your connectors still connected.
- The backend gets the record inside the sealed task frame, per task. It is not
  written to disk there.

The wire shape is in `docs/WIRE_CONTRACT.md`, section
"`mcp_servers` on `task`".
