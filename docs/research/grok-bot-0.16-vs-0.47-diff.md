# Grok Bot (Anysphere/Cursor, product `sand`) — 0.16.0 → 0.47.0 feature diff

Evidence base:

* `/home/user/git/cowork/_scratch/grokbot16/asar_x/` (from `Grok_Bot_0.16.0.deb`, `opt/Grok Bot/resources/app.asar`)
* `/home/user/git/cowork/_scratch/grokbot47/asar_x/` (already extracted)

Method: `package.json` diff, proto `typeName` diff, Connect-RPC service method-table diff,
desktop↔host RPC contract method-name diff, and a diff of the compiled UI string catalogs.
Every claim below names the string or symbol it rests on. Anything I could not prove from the
bundles is marked **(inference)**.

Counted totals:

| | 0.16.0 | 0.47.0 |
|---|---|---|
| proto `typeName`s (all namespaces) | 5348 | 5753 (747 new, 342 dropped) |
| `aiserver.v1.GrokBot*` message types | 1 (`GrokBotService` only) | 295 |
| `aiserver.v1.GrokBotService` methods | 30 | 153 |
| desktop RPC contract methods | 234 | 389 (178 new, 23 dropped) |
| UI strings in the compiled catalogs | n/a (no i18n) | 2650 (1119 have no text match anywhere in 0.16) |
| shipped locales | 1 (English, hard-coded) | 26 |

---

## 0. Packaging / process layout

**Source maps and readable source are gone.** 0.16 ships `main.cjs.map`, `host-main.cjs.map`,
`preload*.cjs.map`, `node-agent-coordinator/main.cjs.map`, … and `dist/electron-main/main.cjs`
is *unminified* TypeScript output (16.9 MB, with comments such as
`// src/electron-main/vnc/vnc-trust.ts`). 0.47 ships no `.map` at all and everything is minified.

**The main process was split into four bundles.**

| 0.16 | 0.47 |
|---|---|
| `dist/electron-main/main.cjs` (16.9 MB, monolith) | `main.cjs` (11 KB launcher) + `main-core.cjs` (1.7 MB) + `main-app.cjs` (1.9 MB) + `proto.cjs` (3.9 MB) |
| — | `dist/electron-main/chrome-import-worker.cjs` (new) |
| — | `dist/electron-main/onepassword-connection-service.cjs` (new, 65 KB) |
| `dist/electron-dev-controls/main.cjs` + `preload-dev-controls.cjs` | removed |
| `dist/host/host-main.cjs` (24.6 MB) + `dist/host/agent-isolation/*` + `dist/host/extensions/box-store-sync/` + `dist/host/extensions/content-search/` | **not in the asar any more** |

The box-side "host" is no longer bundled with the desktop app. 0.47 still names it
(`"host-main"` appears in `main-app.cjs`) and gained RPCs to manage it out-of-band:
`getHostStatus`, `updateHostNow`, `getBoxHostPhase`, `getHostSettings/setHostSettings`,
`getHostSidebarSections`, `getHostPinnedAgents`, `setUpdateTrack`. **(inference)** the host is
now installed/updated on the cloud box independently of the desktop release; supporting strings:
`"Install the latest software on Grok Bot's computer and keep your files in place."`,
`"Waiting for the next Grok Bot update to be ready."`, and the proto family
`GrokBotHarnessMigrationPassStatus` / `GrokBotHarnessMigrationRolloutStatus` /
`EnsureGrokBotBoxHarnessMigrationPass`.

`local-exec-daemon`, `node-agent-coordinator` and `preload-vnc.cjs` exist in **both** versions —
they are not new in 0.47. (`local-exec-daemon/main.cjs` shrank 8.8 MB → 3.5 MB.)

### package.json

New workspace packages in 0.47:
`@anysphere/grok-bot-harness`, `@anysphere/grok-bot-voice-call-harness`,
`@anysphere/canvas-shared`, `@anysphere/mcp-core`, `@anysphere/messages-mac`,
`@anysphere/metrics`, `@anysphere/otel-proto`, `@anysphere/dune` (was `@sand/dune`).

New third-party deps: `@lingui/core`, `@lingui/react` (i18n), `ws` 8.20.0 → 8.21.3,
`katex` ^0.16.21 → ^0.16.45, `@sentry/node` → `@sentry/node-core`.
Dropped: `highlight.js`, `rehype-katex`.
New top-level key: `"desktopName": "grok-bot.desktop"`.

---

## 1. The server API the app talks to was rewritten around `GrokBot*`

In 0.16, `aiserver.v1.GrokBotService` had **30 methods and all of them were box lifecycle**:
`EnsureSandBox`, `RecreateSandBox`, `ListSandBoxes`, `PresignSandBoxStoreReads/Writes`,
`WatchSandBoxMigration`, `SaveTeamSandSetupManifest`, `AdminUpdateSandBoxHost`, … There was
**not a single `GrokBotAgent*` / `GrokBotTranscript*` / `GrokBotTemplate*` message type**
(`grep -c GrokBot` over all 0.16 `typeName`s = 1, and that one hit is the service name itself).

In 0.47 the box methods moved into a **new `aiserver.v1.SandBoxService`** (47 methods) and
`GrokBotService` grew to **153 methods** carrying the whole product surface:

* agents — `CreateGrokBotAgent`, `CreateGrokBotAgentFromTemplate`, `CreateGrokBotTemporalAgent`,
  `UpdateGrokBotAgent`, `DeleteGrokBotAgent`, `ListGrokBotAgents`, `InterruptGrokBotAgentRun`,
  `SetGrokBotAgentVisibility`, `ListGrokBotAgentSessions`, `ListGrokBotAgentAutomations`
* transcripts — `WatchGrokBotTranscripts`, `ListGrokBotTranscriptEntries`,
  `CommitGrokBotTranscriptEntries`, plus the streaming frames
  `GrokBotTranscriptWatchRows/Frame/Heartbeat/Cleared/CursorTooOld/ComputerActions`
* messaging — `SendGrokBotUserMessage`, `SendGrokBotAgentMessage`, `SendGrokBotDraft`,
  `DiscardGrokBotDraft`, `ReactToGrokBotMessage`, `GetGrokBotSendStatus`
* memory — `PutGrokBotMemoryShard`, `ListGrokBotMemoryShards`, `GrokBotMemoryFolder`
* rooms — `CreateGrokBotRoom`, `SetGrokBotRoomMembers`, `RequestGrokBotRoomMemberTurn`,
  `DeliverGrokBotRoomMemberTurnResult`, `CancelGrokBotRoomMemberTurn`

Services **dropped** between the two versions: `agent.v1.AgentService`, `agent.v1.ControlService`,
`agent.v1.ExecService`, `aiserver.v1.AutomationsService`, `aiserver.v1.InferenceService`.
The whole `Inference*` proto family (`InferenceStreamRequest`, `InferenceCoreMessage`,
`InferenceProviderOptions`, …, ~50 types) and the whole Cursor Automations/Crew family
(`Automation`, `AutomationRun`, `Crew`, `CrewAgent`, `CrewStandupDigestEntry`, `GitTrigger`,
`SlackTrigger`, `LinearTrigger`, `SentryTrigger`, `PagerDutyTrigger`, `MicrosoftTeamsTrigger`,
`WorkflowTemplate`, …) are gone from 0.47 and replaced by `GrokBotAgentAutomation` +
`ListGrokBotAgentAutomations`.

New namespace in 0.47: **`anyrun.v1`** (24 new types) — the box/VM control plane:
`EgressPolicy`, `EgressProxyRule`, `AnygressPodDenyRule`, `AllowedDomain`,
`AllowedTcpDestination`, `ComputerUseRequest/Response/Action`, `CreateProcessRequest`,
`DockerImageBuildEvent`, `ExternalSnapshot`, `HydrationProgress`.
Also new: 17 `opentelemetry.proto.*` types (OTLP tracing is now compiled in).

---

## 2. Credentials, 1Password and secret handling — mostly new

**1Password is a first-class credential provider in 0.47 and did not exist in 0.16.**
In 0.16 the only `1Password` hits in the whole tree are in `dist/electron-dev-controls/main.cjs`
(the removed dev window). In 0.47 there is a dedicated process
`dist/electron-main/onepassword-connection-service.cjs` and a proto family:
`BeginOnePasswordConnection`, `CompleteOnePasswordConnection`, `DeleteOnePasswordConnection`,
`SyncOnePasswordConnections`, `GetOnePasswordState`, `SetOnePasswordAlwaysAllow`,
`ApproveOnePasswordCredentialRequest`, `DenyOnePasswordCredentialRequest`,
`OnePasswordConnection`, `OnePasswordCredentialItem`, `OnePasswordState`.
Runtime strings prove a managed `op` CLI is downloaded and verified:
`"The 1Password CLI archive signature entry is invalid."`,
`"The 1Password CLI archive entry cannot be a symlink."`,
`"1Password desktop provisioning is supported on macOS only."`,
`"1Password did not return a valid service-account credential."`.
UI string: `"Connect 1Password"`.

New desktop RPCs: `getCredentialsStatus`, `getCredentialsDirectory`, `startCredentialMint`,
`detectCredentialMint`, `approveCredentialRequest`, `denyCredentialRequest`,
`setCredentialAlwaysAllow`, `disconnectCredentialProvider`, `storeSecret`,
`mintLocalExecDaemonCredential`, `mintVoiceCallCredential`, `getAutomationWebhookCredential`.
(`setBoxSecrets`, `listSecrets`, `revealSecret`, `upsertSecrets` already existed in 0.16.)

New server-side secret plumbing: `Keyring`, `KeyringSecret`, `KeyringGrant`,
`CreateKeyringFromTeamSecrets`, `CopyTeamSecretsToKeyring`, `GrantKeyringPermissions`,
`RevokeKeyringSecret`, plus `CreateBackgroundComposerSecretBatch`.

### Form autofill vault (new)
`GrokBotUserFormVaultEntry` / `GrokBotUserFormVaultKey`, RPCs
`listUserFormVaultEntries`, `updateUserFormVaultEntry`, `deleteUserFormVaultEntry`,
`getUserFormPrefill`, `submitUserForm`, `dismissUserForm`. UI:
`"Values you submit through forms (addresses, phone numbers, traveler IDs, …) are saved to your account after a successful fill and offered next time, on every device. Passwords, codes, and card numbers are never saved."`,
`"Saved form values"`, `"Filled into the page. Secret values were never shown to your Bot."`,
`"Could not fill into the page — it may have moved or changed. Secret values were never shown to your Bot."`

---

## 3. Browser / Chrome cookie import — new

Not present in 0.16 (`importChromeCookies`, `injectChromeCookies`, `listChromeProfiles` are all
absent from the 0.16 RPC tables; `dist/electron-main/chrome-import-worker.cjs` does not exist).

New RPCs: `listChromeProfiles`, `importChromeCookies`, `injectChromeCookies`,
`listChromeCookieAllowItems`, `requestCookieOriginApproval`, `presentCookieOriginApproval`,
`awaitCookieOriginApproval`, `cancelCookieOriginApproval`, `listCookieOriginGrants`,
`putCookieOriginGrants`, `removeCookieOriginGrants`.

UI evidence:
`"Import cookies from Chrome"`,
`"Sites you're signed into in Chrome will be signed in here too. Only cookies are copied, not passwords. macOS may ask for Keychain and Chrome cookie access."`,
`"Copies cookies from Chrome on your computer so the bot can use sites you're already signed into."`,
`"Google sign-in cookies may stop working after copying, because Google can tie them to your original device."`,
`"No cookies were found on this computer. Quit Chrome and try again."`,
`"Cookie approvals"`, `"Browser state access"`.

---

## 4. Voice calls — new

`@anysphere/grok-bot-voice-call-harness` is a new workspace dependency.
New protos: `MintSandVoiceCallSecret`, `MintDesktopRealtimeVoiceSecret`,
`TextToSpeechRequest/Response`.
New RPCs: `getVoiceCall`, `recordVoiceCall`, `nudgeVoiceCall`, `setVoiceCallPresence`,
`readVoiceCallAgentContext`, `readVoiceCallSentMessages`, `mintVoiceCallCredential`,
`setAgentVoice`, `previewVoice`.
(`transcribeAudio` already existed in 0.16.)

UI evidence: `"Voice call"`, `"Voice call transcript"`, `"Voice call feedback"`,
`"How was the call?"`, `"How quickly this Bot speaks on a call"`,
`"Only one voice call can run at a time. The call in progress ends before this call reaches ."`,
`"No speech was transcribed on this call"`,
`"The microphone is unavailable: the permission prompt was never answered."`

---

## 5. Slack — install/management moved into the app

Channel connect existed in 0.16 (`connectChannel`, `disconnectChannel`, `refreshChannel`).
**New in 0.47**: the app installs and owns the Slack app itself —
`startGrokBotSlackConnect`, `installGrokBotSlackApp`, `reinstallGrokBotSlackApp`,
`uninstallGrokBotSlackApp`, `getGrokBotSlackInstallState`; protos `GrokBotSlackConnection`,
`GrokBotSlackWorkspace`, `GrokBotSlackDraft`, `GrokBotAgentDefinitionSlack`.

UI evidence: `"Add to Slack"`, `"Remove Slack app"`, `"Waiting for a Slack admin to approve"`,
`"A Slack admin denied this app. Ask an admin to approve it, then try again."`,
`"This Slack app predates the current setup. Update it so DMs and mentions reach ."`,
`"Slack did not return the signing credentials this older app needs. Remove the Slack app, then add it again."`,
`"Slack threads and DMs appear here as separate conversations."`,
`"Slack is rate limiting these requests. Wait a moment, then try again."`

Email: `GrokBotEmailDraft` proto is new; UI `"Draft ready in Gmail for  — “”"`,
`"Inbox Manager"`, `"Triages email, surfaces urgent threads, and drafts replies for your approval"`.
There is no dedicated email-connector RPC — **(inference)** email arrives through the same
channel/connector mechanism, not a separate transport.

---

## 6. macOS Messages (iMessage) bridge — new

New workspace package `@anysphere/messages-mac`. New RPCs `checkMessagesPermissions`,
`requestMessagesGrants`, `awaitMessagesGrants`, `resolveMessagesGrants`, `cancelMessagesGrants`,
`getMessagesAppIcon`, `getCurrentMachineMessagesEnabled`, `updateCurrentMachineMessagesEnabled`.
New protos `GrokBotUserComputerMessagesOp/Consent/ConsentResult/Accepted/Result/Error`,
`GetSandMachineMessagesEnabled`, `UpdateSandMachineMessagesEnabled`.

UI: `"Allow Grok Bot to use Messages on your local computer?"`, `"Use Messages"`,
`"Lets Grok Bot send texts through Messages"`, `"Read your Messages on your computer"`,
`"macOS is blocking Messages Automation. Turn on Messages under Grok Bot Computer Use in Privacy & Security → Automation."`,
`"Open System Settings for Messages Automation"`.

---

## 7. "Your computer" — agent control of the local machine

`GrokBotUserComputer*` is a whole new proto family (≈25 types): `GrokBotUserComputerHello`,
`…Exec`, `…File`, `…Upload`, `…Download`, `…Presence`, `…QueuedRequest`, `…RequestFrame`,
`…ResponseFrame`, `…RetireApproval`, `…Capabilities`, plus
`IssueGrokBotUserComputerCredential`, `PollGrokBotUserComputerRequests`,
`WatchGrokBotUserComputerRequests`, `SubmitGrokBotUserComputerResponses`,
`OpenGrokBotUserComputerRequest`, `CancelGrokBotUserComputerRequest`,
`ListGrokBotUserComputers`. None of these exist in 0.16.
Machine registry: `RegisterSandMachine`, `ListSandMachines`, `UpdateSandMachineLabel`,
`UpdateSandMachineLocalToolPermission`; RPCs `getSandMachines`, `updateSandMachineLabel`,
`getMachineId`, `isProcessAlive`, `terminateProcess`, `spawnLocalExecDaemon`, `sealLocalExecFile`.

Per-tool permission gate (new): `resolveLocalToolPermission`, `setLocalToolPermission`,
`getLocalToolPermission`, `getLocalToolPermissionCeiling`, `recordLocalToolApproval`,
`recordLocalToolStandingGrant`, `clearLocalToolApprovals`,
proto `ResolveGrokBotLocalToolPermission`.
UI: `"Run a command on your local computer"`, `"Read a file on your computer"`,
`"Write a file on your computer"`, `"List a folder on your computer"`, `"Allow Once"`,
`"Let Grok Bot open files and run tasks on your computer. Auto-review still checks everything first."`

Auto-review (new): `GrokBotUserAutoReviewInstructions`, `SandAutoReviewControls`,
`ResolveGrokBotAutoReviewApproval`; RPCs `getAutoReviewInstructions`, `setAutoReviewInstructions`,
`getAutoReviewTeamPolicy`, `resolveAutoReviewApproval`.
Audit trail (new): `SandAuditEvent` with `.ShellCommand`, `.BrowserNavigation`,
`.ComputerUseSession`, `.McpToolCall`; `SandActionAuditSettings`.

---

## 8. Cloud box ("computer") lifecycle — scheduled upgrades and recovery

New: `ScheduleSandBoxUpgrade`, `RescheduleSandBoxUpgrade`, `CancelSandBoxUpgrade`,
`GetSandBoxUpgradeSchedule`, `SandBoxUpgradeSchedule`, `SandUpgradeRecommendation`,
`SandBoxMigrationEvent`, `AdminRestoreSandBoxStoreSnapshot`,
`AdminListSandBoxStoreManifestVersions`, `RecreateTeamMemberSandBox`.
RPCs `scheduleComputerUpgrade`, `rescheduleComputerUpgrade`, `cancelComputerUpgrade`,
`getComputerUpgradeSchedule`, `attachProdBoxStatus`, `setAttachProdBoxEnabled`,
`getBoxHostPhase`, `getBoxMigrationStatus`, `forceRecreateComputer`.

**Dropped** from the 0.16 RPC contract: `autoUpdateBoxNow`, `getBoxStoreStatus`,
`snapshotBoxStoreNow`, `clearBoxStoreNow`, `prepareBoxForRecreate`, `resumeBoxAfterRecreate`,
`setBoxMigrating`, `resetForeverBox` — consistent with 0.16's in-asar
`dist/host/extensions/box-store-sync/box-store-vacuum-worker.cjs` disappearing.

UI: `"Schedule computer update"`, `"Cancel scheduled update"`, `"Computer update was missed"`,
`"The update runs at this local time in ."`,
`"Warning: Work that has not synced to the snapshot yet, including recent Bots and files, will be lost. Installed apps and packages are removed."`,
`"Wipe Grok Bot's computer and start it fresh, which removes the files on it."`,
`"Your computer needs a rebuild, and computer rebuilds are temporarily paused."`

---

## 9. Bot templates + public marketplace — new

New protos: `GrokBotTemplate`, `CreateGrokBotTemplate`, `DeleteGrokBotTemplate`,
`GetGrokBotTemplateVersion`, `ActivateGrokBotTemplateVersion`, `SetGrokBotTemplateVisibility`,
`GetGrokBotTemplateExportPolicy`, `GetGrokBotTemplateImportDetails`,
`GetPublicGrokBotTemplate`, `CreateGrokBotAgentFromTemplate`,
`GrokBotAgentDefinitionTemplateImport`,
and the marketplace: `GrokBotMarketplaceListing`, `GrokBotMarketplaceCategory`,
`GrokBotMarketplaceCreator`, `GrokBotMarketplaceDefaultAvatar`,
`PublicGrokBotMarketplaceListing`, `ListPublicGrokBotMarketplaceListings`,
`PresignGrokBotMarketplaceImageUploadInternal`, `UpdateGrokBotAgentMarketplace`,
`SandShareBotExportSettings`.

New RPCs: `listBotTemplates`, `publishBotTemplate`, `deleteBotTemplate`,
`setBotTemplateVisibility`, `getBotTemplateVersion`, `getBotTemplateExportPolicy`,
`getBotTemplateForSourceAgent`, `getPublicBotTemplate`, `listPublicBotMarketplace`,
`createAgentFromTemplate`, `updateGrokBotAgentMarketplace`.

UI: `"Back to Marketplace"`, `"Marketplace content"`, `"Bot categories"`,
`"Anyone can now use this template"`, `"Only your team can now use this template"`,
`"Shared bot template:"`, `"This template was deleted. Its link no longer works."`,
`"Create a template of yourself that I can share with somebody else."`

A catalogue of **42 preset bots** ships as UI strings, none of which exist in 0.16 — e.g.
`"Inbox Manager"`, `"Calendar Coordinator"`, `"Account Manager"`, `"Call FAQ Miner"`,
`"Beta Adoption Watcher"`, `"Onboarding Manager"`, `"Account Health"`, `"Bug Reproduction"`,
with one-line descriptions such as
`"Scans Slack, email, and calendar and delivers a readout on what needs you"`,
`"Triages email, surfaces urgent threads, and drafts replies for your approval"`,
`"Builds a prep pack from calendar, CRM, and Slack before every meeting"`,
`"Reviews contracts in  and drafts redlines for approval"`,
`"Scores applications against a defined bar and hands off an ATS-ready review"`.

---

## 10. Cursor account integration — new

New RPCs: `loginCursor`, `logoutCursor`, `addCursorAccount`, `removeCursorAccount`,
`switchCursorAccount`, `listCursorAccounts`, `listCursorTeamMemberships`, `selectCursorTeam`,
`getCursorSelectedTeam`, `checkCursorTeamAccess`, `ackCursorTeamFallback`,
`getCursorLoginFlight`, `cancelCursorLoginFlight`, `getCursorUsageSummary`,
`getCursorWeeklyUsage`, `getCursorEnterpriseUsage`, `setCursorSpendLimit`,
`getCursorPrivacyModeEnabled`, `getCursorOriginPrStatus`, `getCursorPrReviewPreferences`,
`invokeCursorDashboardAction`, `cancelCursorSandTrial`, `getCursorAvatar`.
(`loginCursor`/`logoutCursor`/`getCursorUsageSummary` existed in 0.16; the **multi-account,
team-selection, spend-limit and PR-status** parts are new.)

Server-side account merge machinery, all new:
`StartXaiCursorTeamMerge`, `ConfirmXaiCursorTeamMerge`, `CancelXaiCursorTeamMergeProposal`,
`GetXaiCursorTeamMergeStatus`, `GetXaiCursorTeamMembershipPreview`,
`StartUnifyGrokOAuth` / `CompleteUnifyGrokOAuth`, `UnificationIntent`,
`FinalizeIndividualUnification`, `AccountCollapseRun`, `CollapseLinkedGrokAccount`,
`ListCollapseCandidates`.

UI: `"Billed through Cursor"`, `"Manage on-demand billing on Cursor"`,
`"Sign in to Cursor to manage plugins"`, `"PR status may be stale: sign in to Cursor again"`,
`"Get $1,000 of Grok Bot usage each week with Ultra"`,
`"Upgrade to Cursor Pro, or link a SuperGrok, SuperGrok Plus, or SuperGrok Heavy subscription, to send messages with Grok Bot."`,
`"You’ve hit your weekly usage limit."`, `"Cancel Trial"`.

---

## 11. Payments: Stripe Link wallet + virtual cards — new

`GrokBotStripeLinkPaymentMethod`, `ListGrokBotStripeLinkPaymentMethods`,
`RaiseGrokBotVirtualCard`, `ResolveGrokBotVirtualCardApproval`; RPC `resolveVirtualCardApproval`.
Prepaid billing protos are new too (`CreatePrepaidTopUp`, `PrepaidAutoTopUpRule`,
`SetUserPrepaidBillingMode`, `GetTeamPrepaidBilling`), as are
`VerifyGooglePlayPurchase` / `GetGooglePlayBillingAccountId`.

UI: `"Virtual card approval"`, `"Approve a card for"`, `"This card was declined. No charge was made."`,
`"Reconnect Link to choose a payment method. Link charges your default."`,
`"No payment methods in your Link wallet. Add one in the Link app."`,
`"This card was approved. Finish authorizing on the Stripe Link page that just opened."`

---

## 12. Localization — new

0.16 has no i18n at all (no `@lingui`, no locale table, no message catalogs).
0.47 adds `@lingui/core` + `@lingui/react`, 58 compiled catalog chunks
(`JSON.parse(\`{"+52YnJ":["No messages yet"],…}\`)` in `dist/renderer/assets/`), and a
26-locale table: English, Hindi, Simplified Chinese, Traditional Chinese, Polish, Spanish,
Portuguese, Japanese, French, Korean, German, Russian, Turkish, Arabic, Italian, Swedish,
Ukrainian, Dutch, Greek, Afrikaans, Hebrew, Vietnamese, Indonesian, Urdu, Thai, Bengali —
with an RTL flag per row (`direction:"ltr"`).
New RPCs `getLanguageState`, `setLanguagePreference`; UI `"Choose the language Grok Bot uses for menus and messages."`,
`"Language this Bot listens and replies in"`, `"Search language"`, `"Follow System"`.

---

## 13. Desktop app polish (all new RPCs)

* Window control: `focusWindow`, `closeWindow`, `minimizeWindow`, `toggleMaximizeWindow`,
  `resizeWindowWidth`, `getWindowState`, `setTitleBarOverlayTone`, `relaunchDesktop`.
* Rendering: `getHardwareAcceleration`, `setHardwareAccelerationEnabled` —
  `"Let your graphics card draw the app, or turn it off if the window flickers or stays blank."`
* Notifications: `getDesktopNotificationPreferences`, `setDesktopNotificationPreferences`,
  `getAgentNotificationAvatar` — `"Play Sound for Notifications"`, `"Notification Sound"`,
  `"Pick the sound that plays when Grok Bot sends you a message."` — and five new sound assets
  `tmp-1-open-blip.wav` … `tmp-5-chime-b.wav` (none in 0.16).
* Client-side persistence layer: `readClientPersistence`, `readManyClientPersistence`,
  `writeClientPersistence`, `removeClientPersistence`, `listClientPersistenceKeys`,
  `migrateClientPersistence`, `hasMigratedClientPersistence`.
* Deep links: `deepLinkEmit`, `markDeepLinksReady`.
* Updater: `checkForUpdates`, `quitAndInstallUpdate`, `getUpdateStatus`, `setUpdateTrack`,
  `setAutoUpdateWhenIdleOptIn`, `reportUpdatePrompt`.
* Onboarding: `getOnboardingSeen`, `setOnboardingSeen`, `skipOnboarding`,
  `reportOnboardingStep`, `reportOnboardingCompleted`, `SandOnboardingState`,
  `StartCloudOnboarding`, `SendTeamSandOnboardingInvites`; UI `"Restart Onboarding"`.
* Timezone: `getTimeZone`, `setTimeZoneOverride`; theme: `getThemeState`, `setThemePreference`.
* Avatars: `getAgentAvatar`, `setAgentAvatarBytes`, `generateAgentAvatarImage`, `pickAvatarFile`,
  `pickAvatarSource` — UI `"Edit Bot avatar"`.
* Attachments: chunked upload/download added (`uploadAttachmentChunk`, `stageAttachmentBytes`,
  `stageAttachmentPath`, `commitStagedAttachments`, `discardStagedAttachment`,
  `downloadAttachment`, `resolveAttachmentMedia`, `readAttachmentBytes`).

## 14. Telemetry expansion

16 new `report*` RPCs in 0.47 that have no 0.16 counterpart: `reportTurnClientStart`,
`reportTurnClientOutcome`, `reportTranscriptParity`, `reportTranscriptRowLoss`,
`reportTranscriptSource`, `reportTransportStage`, `reportGatewayReachability`,
`reportGatewayDnsDiagnostic`, `reportGatewayCommandSpan`, `reportHeapMetrics`,
`reportProcessCrash`, `reportPolicyStopped`, `reportAccessBlocked`, `reportUsageWarning`,
`reportLocalExecSupervisorFailed`, `reportOnboardingCompleted`.
Plus `startRpcTraceWindow` / `getRpcTraceWindowTraceparent`, `runNetworkDiagnostics`
(UI `"Network Debugger"`), `noteSentryConversation`, and 17 compiled
`opentelemetry.proto.*` types.

---

## 15. Things that were already in 0.16 (do **not** claim as new)

All of these appear in the 0.16 RPC contract tables or proto set:
teach/record (`startTeachRecording`, `stopTeachRecording`, `getTeachRecordingStatus`),
automations and workflows (`createAgentAutomation`, `runAgentWorkflowNow`,
`importAgentWorkflowUrl`, …), groups (`createGroup`, `setGroupMembers`),
subagents (`getSubagents`), skills (`publishSkill`, `skillsCatalog`, `portAgentLocalSkills`),
MCP / plugins (`getMcpCatalog`, `installEntry`, `toggleMcpToolDisabled`, `getEffectivePlugins`),
egress tunnel (`getEgressTunnelEnabled`, `isEgressTunnelAvailable`),
WebAuthn proxy (`requestWebAuthnCeremony`, `setWebauthnProxyEnabled`),
VNC (`preload-vnc.cjs`, `reportVncSession`, `reportVncLiveness`),
box secrets (`setBoxSecrets`, `listSecrets`, `revealSecret`),
cloud agents (`openCloudAgent`, `getCloudAgentInfo`), `transcribeAudio`.

## 16. Removed from the desktop RPC contract in 0.47 (23 methods)

Shared rooms went server-side: `createSharedRoom`, `joinSharedRoom`, `leaveSharedRoom`,
`createRoomInvite`, `respondToRoomJoinRequest`, `setSharedRoomTyping`, `createRoomFromAgent`,
`addOwnAgentToSharedRoom`, `removeOwnAgentFromSharedRoom`, `getSharingState` — replaced by
`isServerRoomsEnabled` plus the server protos `CreateGrokBotRoom` / `SetGrokBotRoomMembers` /
`RequestGrokBotRoomMemberTurn`.
Box-store maintenance: `getBoxStoreStatus`, `snapshotBoxStoreNow`, `clearBoxStoreNow`,
`autoUpdateBoxNow`, `prepareBoxForRecreate`, `resumeBoxAfterRecreate`, `setBoxMigrating`,
`resetForeverBox`.
Misc: `deleteAgent` (→ `deleteAgents`), `setAgentWorkflowEnabled`, `isAgentNetworkEnabled`,
`appendConnectorCard`, `cancelCursorLogin` (→ `cancelCursorLoginFlight`).

---

## Caveats

* The proto counts compare what each build *bundles*, not the server's real schema. 0.47 ships a
  dedicated `proto.cjs` (3.9 MB); 0.16 inlined protos into `main.cjs`/`host-main.cjs`. Parts of
  the 747-type growth are unrelated Cursor-server messages (Jira/Linear/GitHub/organization/
  billing) that the desktop app probably never calls. Feature claims above therefore lean on the
  RPC method tables and the UI string catalogs, with proto names as corroboration.
* The 1119 "new" UI strings are strings with no exact text match anywhere in 0.16's renderer,
  main, host, preload, coordinator or daemon bundles. A reworded 0.16 string counts as new; the
  grouped claims above were each cross-checked against an RPC or proto symbol.
* `dist/host/*` is absent from the 0.47 asar. Whether it is downloaded at runtime or shipped
  outside `app.asar` could not be determined from the asar alone.
