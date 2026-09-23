---
name: secrets
description: Use the user's API keys and tokens (PEXELS_API_KEY, OPENAI_API_KEY, ...) without seeing them. Use whenever a task needs an API key, a token or a password for a service. Ask by name with request_secrets, then read the value only inside a script as os.environ["NAME"].
metadata:
  version: "1.0"
---

# Secrets: keys you can use but never read

The user keeps API keys in a vault. You can use them. You cannot see them.
This is by design. Do not try to work around it, and do not ask the user to
paste a key into the chat.

## How it works

1. A key has a NAME in the style of an environment variable:
   `PEXELS_API_KEY`, `OPENAI_API_KEY`, `SMTP_PASSWORD`.
2. Every key that is set is an environment variable of that name inside
   `run_command` and `python`. Nowhere else. There is no `.env` file.
3. Every output that comes back to you is masked: the value shows as
   `[REDACTED:NAME]`. This applies to stdout, stderr, files you read, error
   texts and the output of subagents. Base64 and URL-encoded forms are
   masked too. Values shorter than 8 characters are not masked: they are
   too short to be a real key and would mask normal text.

## The two tools

`list_secrets()` returns the names that are set. Only names. Example
result: `{"secrets": {"PEXELS_API_KEY": "set"}, "count": 1}`.

`request_secrets(names, purpose)` asks the user for the keys you name. The
app shows a dialog with one field per name. The user types the values and
submits. You get back a status map and nothing else:

```json
{"PEXELS_API_KEY": "set", "PIXABAY_API_KEY": "missing"}
```

`set` means the key is now available in your scripts. `missing` means the
user did not enter it (cancelled, left it empty, or did not answer within
ten minutes). The call blocks until the user answers. Ask for all keys of
one task in ONE call. Write a short `purpose` in the user's language: it is
shown in the dialog.

## Use a key in a script

Read the value inside the script. Never print it. Never write it to a file.
Never put it into a command line argument (a command line is visible to
other processes).

```python
import os, sys
import urllib.request

key = os.environ.get("PEXELS_API_KEY")
if not key:
    sys.exit("PEXELS_API_KEY is not set: call request_secrets first")

req = urllib.request.Request(
    "https://api.pexels.com/v1/search?query=mountains&per_page=3",
    headers={"Authorization": key},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    print(resp.read()[:800].decode("utf-8", "replace"))
```

In a shell command the same rule applies: `curl -H "Authorization: $PEXELS_API_KEY" ...`
works. `echo $PEXELS_API_KEY` shows only the mask.

## The order of work

1. Call `list_secrets()` when you do not know which keys exist.
2. If a key you need is missing, call `request_secrets` once, with every
   name you need and a one-line purpose.
3. If the result says `missing`, tell the user which key is missing and
   what it is for. Then stop. Do not retry the request in a loop.
4. If the result says `set`, run your script. Read the key with
   `os.environ["NAME"]`.

## What not to do

- Do not ask the user to type a key into the chat. Use `request_secrets`.
- Do not print, log, or store a value. It will be masked anyway, and the
  masked text is useless to you.
- Do not `export` a key into the shell session or write a `.env` file.
  The key is already in the environment of every `run_command` and `python`
  call.
- Do not guess a name. Use the name the user gave, or a clear one like
  `<SERVICE>_API_KEY`. The user manages the names under Settings > API Keys.
