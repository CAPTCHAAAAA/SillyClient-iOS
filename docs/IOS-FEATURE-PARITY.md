# iOS Feature Sync Status

## Scope And Baselines

This iteration continues the existing iOS experimental branch. It neither opens
a fourth product repository nor changes the released Windows/Android clients.
Previously uncommitted iOS rename, relocation, and frontend work is preserved.

Source baselines verified for this iteration:

| Source | Branch / revision | Use |
| --- | --- | --- |
| Windows | `feature/windows-migration-and-ui` / `1659e98f67e75bca4f0388f693a035f3180b63c4` | Management UI, password contract, onboarding |
| Android | `main` / `d930d488665d2a1ace06b65f49a04fb4b24ba85f` | Release comparison |
| Main | `main` / `bdacad13f37d03b6bcc5b3020d08d0e96695cf52` | Published release context |
| iOS | `feature/sillyclient-ios` / `875d4726a86ace6de91d06adcd5e265ac99ca316` plus retained local edits | Native implementation and preview base |

The older workspace notes saying all frontend copies are identical are not an
implementation inventory: the checked Android release still contains older
management/snapshot code. No platform is overwritten wholesale to match it.

## Implemented, Not Released

| Feature | Native iOS | Synchronized frontend |
| --- | --- | --- |
| Instance access password | Five bridge methods; atomic Keychain store; Windows-compatible digest vectors | Set/change/clear; card lock badge; fresh checks on launch, retry, return, and online remote entries |
| Physical rename | Stable instance ID, collision checks, runtime exclusion, registry/path update | Existing async rename and path updates preserved |
| Storage relocation | Same-volume rename, verified cross-volume copy, recovery journal and rollback | Storage actions and relocation dialog retained |
| Legacy migration | Real scan, per-item results, partial failure preserved | Migration result handling retained |
| Deletion retry | Persist intent first; delete in place; unregister last | Failed/unavailable records remain manageable rather than being silently reinstalled |
| Management cleanup | Existing maintenance quarantine/recovery unchanged | Four tabs, no configuration-snapshot feature, no redundant footer menus; rename/delete in storage tab |
| Preinstallation | Existing fixed catalog and SC Bordeaux assets retained | Wording aligned to "预设安装"; no unsupported runtime ZIP selection |
| Onboarding | No new native dependency | Seven steps, 14 views, five additional existing Windows assets |
| Supported runtime list | Only the bundled, verified runtime version is offered | Capability flags remove arbitrary-runtime and takeover choices; data-copy import remains |

Password reads and verification results are bound to the selected instance,
target path/URL, and current request. Closing/switching the dialog or changing
password protection invalidates older access attempts. Even a delayed mutation
that finishes after its dialog closes reports the changed protection status for
the original instance. Remote local-password removal precedes removal of the
remote launcher record, so a protected Keychain entry is not silently orphaned.
No plaintext access password is persisted in production JavaScript storage.
The preview's in-memory test credentials are development-only fixtures.

## Recovery Boundaries

The new journal is stored under `Documents/.sillyclient-relocations`.
Unverified copies that must be preserved are recorded separately under
`Documents/.sillyclient-relocations-retained`. The latter is not an automatic
cleanup queue and does not authorize deleting external files. A pending
maintenance recovery payload must be restored before relocation/rename.
Uninstall failure retains a `removalPending` record and its directory identity.

Startup retains its normal cancellation identity before queueing recovery.
Filesystem recovery holds a maintenance lease, not the serial runtime state
queue. Cancelling a queued operation cannot start an orphan Worker later.

## What Is Not Equivalent

These are current implementation boundaries, not a blanket claim that every
missing feature is impossible on iOS:

- Multiple stored instances share one embedded Node host, but only one local
  server Worker may run at once. This iteration does not add concurrent servers.
- Runtime code is prepared at build time from the pinned Tavern revision.
  Arbitrary server ZIP/version installation and original-directory takeover are
  unavailable; importing filtered user data by copy is supported.
- A custom external directory requires retained authorization and local runtime
  filesystem capabilities. No claim is made for every iCloud/File Provider path.
- NodeMobile remains `18.20.4`; the pinned upstream manifest requires Node 20 or
  later. Host tests are not proof that every upstream API works under Node 18.
- No-WASM tokenization, WASM image codecs, transformer inference, and native npm
  addons need individual compatibility work. Returning invented tokens or
  silently disabling features is not an acceptable substitute.
- Extension ZIP preinstallation does not prove Git-based extension updating,
  arbitrary server plugins, or every extension's runtime dependencies work.
- Background suspension cannot be described as guaranteed continuous service.
  The existing audio-based keep-alive is not proof of App Review acceptability.
- Unsigned IPA output requires a separate signing/distribution route. A hosted
  simulator run is not physical-device installation or acceptance.

## Verification And Build Handoff

The full host runtime/CI/supervisor/feature-sync suite passes 114 tests on both
Node 18.20.4 and Node 22.16.0. This
includes executable JavaScript runtime fixtures and Swift source assertions;
the latter are not Swift execution. The synchronized frontend passes typechecking,
40 pure tests, and production building. The prior isolated preview passed
18 nonvisual browser scenarios. Browser evidence is archived in
`Local/evidence/ios-feature-sync`; current command logs are in
`Local/evidence/ios-xcode-feature-sync` in the workspace.

On 2026-10-06 the user authorized local synchronization and continuation of the
Xcode build/test flow. The 23 reviewed frontend files were copied from
`.worktrees/ios-feature-sync-preview` into this worktree after SHA-256 checks;
all prior uncommitted changes were backed up under the workspace's
`Local/evidence/ios-xcode-feature-sync/baseline`. Local upstream tracking now
points to `ios/feature/sillyclient-ios`, not the older `ios/main`.

Build 28 retains version 1.10.0. CI now runs all frontend tests before building;
the native harness declares 44 groups and the driver checks the same count.
The new Xcode execution is pending at this source handoff, not proven by the
historical 24-stage/33-group reports. Two new host CI checks prevent unasserted
UI showcase hooks from being counted as acceptance. The driver explicitly
reports `uiInteractionTested: false`; the 18 browser cases remain separate
development-preview evidence, not native iOS UI testing.

The repository has no configured physical-device runner or signing secrets.
The workflow builds an unsigned generic-device archive and runs the actual
application in a hosted simulator. It does not install on a physical iPhone,
publish a Release, or merge into any released platform. Current build logs and
artifact verification belong in `Local/evidence/ios-xcode-feature-sync`.
