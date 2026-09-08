# CoWork browser add-on

Your coworker, in the browser you already have open. Two things it does:

* **Talk about this page.** Right-click, or click the toolbar icon, and a panel
  opens on the right. The page's text, its address and anything you selected go
  along as context.
* **Let the coworker drive.** It opens its own tab (its own tab group, so your
  tabs stay yours), or takes over a tab you point it at, and works the page.

## How it drives

`chrome.debugger` — a declared, ordinary extension permission — gives the
add-on the DevTools protocol for one tab. Input goes out as
`Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` and `Input.insertText`, so
it is real browser input, indistinguishable from a mouse and a keyboard, and the
page sees nothing unusual. Chrome shows its "being debugged" bar for as long as
the coworker holds the tab.

Firefox never implemented that API, so there the add-on falls back to DOM events
from the content script. That works on most pages and fails on a few.

The page goes to the model as a small tree the content script builds —
`role`, `name`, `value`, `placeholder`, `interactive` and a box — not as a
screenshot with coordinates. Screenshots exist as an extra
(`browser_take_screenshot`), not as the main channel.

## How it reaches CoWork

Two transports, one command vocabulary:

* **native** — `runtime.connectNative("dev.chuk.cowork")` starts
  `tools/cowork-browser-bridge`, which passes frames to the CoWork host over a
  unix socket. The access rule is the host manifest's `allowed_origins`: it
  names this add-on and nothing else, and only you can write that file. No port,
  no token.
* **relay** — a WebSocket, for a CoWork host on another machine. Set it under
  the add-on's settings.

## Build and load

```bash
./build.sh chrome     # -> dist/chrome, load unpacked
./build.sh firefox    # -> dist/firefox, load temporary add-on
../tools/cowork-browser-bridge/install_host_manifest.py --chrome-id <id from chrome://extensions>
```

## The command vocabulary

`browser_navigate`, `browser_navigate_back`, `browser_snapshot`,
`browser_click`, `browser_type`, `browser_press_key`, `browser_scroll`,
`browser_take_screenshot`, `browser_tabs` (`list` / `select` / `new` / `close`),
`browser_close`.

The names are the ones the agent's browser tools already carry, so the host, the
wire contract and the app keep reading one transcript whether the coworker is
driving a sandbox browser or this one.

The list is closed and nothing in the add-on evaluates a string it was sent.
That is deliberate: both stores reject an extension that runs remotely supplied
code, and commands from a fixed vocabulary are not code.

## Layout

```
src/api.js         one name for chrome.* and browser.*
src/protocol.js    the command vocabulary and its validation
src/snapshot.js    content script: page -> small tree, ref -> geometry
src/driver.js      cdp and synthetic engines, the coworker's own tab
src/commands.js    one command in, one result out
src/transport.js   native messaging and relay
src/background.js  the long-lived piece
src/panel.*        the panel on the right
src/options.*      relay address, what this browser can do
src/indicator.js   the strip that shows the coworker is driving
```
