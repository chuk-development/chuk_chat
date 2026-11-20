# DuskBot: what we take over (2026-11-20)

Source: github.com/DuskBotAI/duskbot (shallow clone, read only). License:
PolyForm Noncommercial. We take ideas only. We copy no code, no text and no
art. We build every item again in our own stack (Flutter app, Python host).

Full findings:

- `design.md`: layout, design system, messages, settings, groups UI.
- `product.md`: features, groups (rooms), agents, connectors, onboarding,
  prices, changelog order.
- `architecture.md`: host, drivers, computer control, cloud VMs, security,
  updates, tests.

## Order of work

In progress now (2026-11-20):

1. Groups that work: create, @mentions, responder modes (everyone, only
   mentioned, auto pick, lead with caps), shared instructions. CHAT-155.
2. Stacked bubbles per speaker, short agent settings, global connectors with
   a grant per agent, model choice in the right pane. CHAT-152.
3. One-pill composer (min 48 px, max 144 px, Stop in the place of Send).
   CHAT-153.
4. One shared page header and one row shape for all states. CHAT-154.
5. Signed apt and rpm repository (they have none). CHAT-151.

Next, by value:

6. Approval levels per agent: reads never ask; a daily cap for messages that
   an agent sends in the user's name.
7. Routine checks as code before the AI turn: the run starts only when the
   check finds a change. This saves tokens on watchers.
8. Memory with provenance ("learned by"), a nightly tidy and undo.
9. Vault: the agent fills in a secret without seeing it.
10. Settled cards (approval, question, connector) fold to a one-line receipt.
    Tool calls show as folded rows with a status word.
11. Security on the host: a credential broker (keys stay in the host, the
    agent process gets a token), a sandbox for each run (bubblewrap) with an
    egress gate (no private or metadata IPs), and a restart rule that never
    sends a message two times.
12. More engines through one adapter layer (ACP): the user brings Claude Code,
    Codex, Gemini or Kimi plans.
13. A desktop container per agent with a browser view and "take control",
    which pauses the agent.
14. Onboarding without an account wall, with the price on the first screen.

Their cloud VM cost (their docs): 2 vCPU and 4 GiB cost about 1.7 cent per
hour on InstaBox (Firecracker), one VM for each customer.
