# iOS Runtime And Instance Safety

This is an experimental branch, not a verified iOS release.
The hardening build retains version `1.10.0`; it does not change the public
Android/Windows/Main release, install a client, or publish a Release.

## Native Ownership

`NodeRunner` invokes `node_start` once for the lifetime of the application.
`ios-supervisor.mjs` owns the individual server Workers. Start readiness requires
a real HTTP 200 response; stop resolves only after Worker termination and
listener closure. Explicit instance and operation identities reject obsolete
commands. A timed-out transport retains the identity until stop confirmation.
Worker stdout and stderr have separate bounded UTF-8 line buffers. Framed logs
carry their captured instance and operation identities into native storage;
unframed host output belongs to the runtime, not whichever instance is current.
Captured native/Capacitor diagnostics are stored without publishing a log event,
preventing listener delivery output from feeding itself back into the console.
Only validated Worker frames and explicit native business logs publish events.
Oversized lines and saturated output are discarded within explicit bounds.
Native accepted log work is bounded through disk completion; this does not
claim a global lifetime disk cap for all historical instance identities.
Ordered command names and cancellation tombstones prevent stop-before-start
delivery from leaving an orphan Worker. Host GC is acknowledged separately from
the request to collect an active Worker; embedded Worker collection is not
claimed verified merely because its request was sent.

`TarvenEnvPlugin` is an adapter rather than an installer or archive parser.
`IOSInstanceStore` handles managed identity, lightweight enumeration, YAML
configuration, staged provisioning, copy migration, and uninstall registration.
`IOSManagedFiles` and `IOSSafeArchive` enforce bounded regular-file inspection,
link rejection, checksums, exclusive destinations, and source identity checks.
Preparing a runtime never takes place in `scanInstances`. A new installation
is published by an exclusive staging-directory rename; no incomplete
`server.js` directory is silently treated as a prepared runtime.

The supported runtime is the one prepared by this build. Arbitrary server
versions, external takeover, and arbitrary custom destinations fail explicitly
on iOS. Copy migration retains source files, selects their user-data root, and
streams only filtered data into a fresh pinned runtime. Old dependencies, Git
metadata, and, unless explicitly selected, `secrets.json`/`secrets.json.enc`
never enter the destination. Files are SHA-256 verified, cancellation is checked
between chunks, and selected source guards are checked again before completion.
Flat single-user folders and ZIP contents go into `data/default-user`; multi-user
data roots retain their original user directories. A user handle named `chats`
or `characters` remains a user directory, not a flat-data marker. Mixed flat and
nested user layouts require an explicit source selection rather than guessing.
Migration is limited to 32,768 entries, 64 levels, and 2 GiB of user data. ZIP
imports have separate compressed/extraction limits. A selected external folder
does not authorize reading an outside `dataRoot`; select that data root itself.

## Maintenance And Authentication

`IOSInstanceMaintenance` only operates with a stopped runtime and uses one-use,
five-minute scan and recovery tokens. Suspected broken user extensions, stale
disabled references, and verified launcher-owned expired download caches are
handled individually. There is no arbitrary path deletion or blanket
settings reset. Selected contents, configuration, identity, and any reinstalled
extensions are checked again before applying changes. Backups are retained
and recovery identities are returned even when post-move verification fails.
Recovery refuses same-name replacements, changed settings, metadata, payloads,
or instance configuration. Completed records are archived outside the active
recovery list. Inspection is bounded and a partial list reports overflow;
empty prepared records do not consume the 256-payload active recovery capacity.
Expiration removes only expired tokens. Issuing another scan or recovery token
at the global capacity refuses that new token without discarding other instances'
live plans. User and extension names with terminal line controls are excluded
before snapshots, so maintenance cannot quarantine an unrecoverable name.

`IOSRemoteCredentials` stores one atomic Keychain record per remote identity.
Passwords never reach JavaScript, URLs, browser storage, or logs. Credentials
are bound to scheme, host, and effective port, not merely to an imported
instance ID. Unbound legacy records require explicit password verification.
For the existing frontend setter, a bounded, five-minute, one-use receipt from
a successful explicitly authenticated HEAD request binds the origin. Ambiguous
receipts are rejected; omitted passwords retain only an already-bound record
with the same username. Automatic ping and WebView authentication do not reuse
credentials for another origin. Remote HTTP requests reject redirects and
bound response bodies during reception.
Same-URL view reuse refreshes application-owned challenge credentials without
reloading the page. Clearing Keychain credentials also clears the matching
remote view's in-memory credential. Successful browser ownership closes the
old native Tavern session after its generation check. This is not a claim that WebKit's
authentication cache or an already authenticated website session is logged out.
Native events preserve the existing console's `message` and `launcher`
contracts. Local mode snapshots are rechecked on the main queue and cannot
replace an active remote view; status queries retain runtime ownership modes.

Optional preinstallation uses fixed commit/size/SHA-256 catalog metadata.
Third-party extension archives are downloaded at runtime; their implementation
code is not bundled into the MIT source. Archive, manifest entry, and license
validation completes in staging. Missing, null, and empty optional manifest
entries are allowed; nonempty entries must refer to verified regular files.
Existing extensions and disabled settings are preserved. SC Bordeaux uses the
existing pinned companion assets, without a replacement visual design.

## Build and Runtime Boundary

The workflow pins SillyTavern to commit
`06bde939fb1e9c4c8d8641d810f0a916b5bce127` and installs its lockfile with
`npm ci --omit=dev --omit=optional --ignore-scripts`.

With Node 22, `scripts/prepare-ios-frontend.mjs` runs Webpack once, without its
filesystem cache, into `dist/ios-frontend`. Compilation errors, error stats,
missing output, and compiler close errors fail the build. The manifest records
the server version, file sizes, and SHA-256 hashes.

Only after successful compilation is `native-src/prebuilt-webpack.mjs` copied
over SillyTavern's `src/middleware/webpack-serve.js`. Its existing
`runWebpackCompiler` interface now validates the manifest and every file before
the server listens. It never imports Webpack or `webpack.config.js`. GET and
HEAD requests for manifest entries use the verified directory. Other requests
continue through the normal SillyTavern middleware.

The loader does not fabricate WebAssembly. In a no-WASM runtime it uses the
already-installed `node-fetch` implementation for fetch and its related
classes, avoiding the built-in Undici HTTP parser. Tiktoken imports remain
possible, but unavailable tokenization throws `ERR_IOS_WASM_UNAVAILABLE`
instead of inventing token IDs or empty decoded text.

The supervisor selects the real server working directory before creating its
Worker. The loader verifies that inherited directory before importing server
code. Upstream's unconditional same-directory `process.chdir` is an idempotent
Worker-local confirmation; a request for another directory fails explicitly.
This does not provide arbitrary Worker directory changes. A stopped Worker must
terminate before the host selects another instance directory. Main-thread loader
execution retains normal `process.chdir` behavior.

Detected startup errors write `server-failed.json` beside the server directory.
The native readiness poll and simulator test read this marker instead of
waiting for the entire timeout. Simulator acceptance requires HTTP 200, a
matching `lib.js` hash, and the existing webview DOM-ready marker. Diagnostics
are collected on failure and their artifact upload uses `always()`.

## Verification

Unit tests need no installed project dependencies:

```sh
node --test tests/ios-runtime.test.mjs tests/ios-ci.test.mjs tests/ios-supervisor.test.mjs
```

The Debug-only native test harness executes the actual Swift modules against
synthetic sandbox fixtures. It is absent from Release execution and requires an
explicit test launch argument. The simulator driver checks actual HTTP/asset
responses, complete Tavern WebView initialization, start/stop/closed port,
same-process restart, obsolete operation rejection, real bridge copy migration,
source and runtime hashes, and maintenance quarantine/restore/token replay.
The Debug simulator links its test-only application identity into the app's
Mach-O `__TEXT,__entitlements` section for real Keychain fixtures. Frameworks
and the application are then ad-hoc signed without those simulator entitlements
in their host signatures. That identity is never applied to the separately
archived unsigned Release IPA. Its capability-probe
process never creates a production console or deploys an instance. Tests,
source assertions, host fixtures, simulator acceptance, and physical-device
acceptance are distinct evidence categories.
The current harness contains 27 fixture groups, including full-capacity token
recovery, flat/multi-user migration layouts, and captured-output event routing.
Debug bridge rejection envelopes retain bounded, redacted native diagnostics;
oversized diagnostics fail closed without leaking a truncated credential.
WebKit fallback reports only a sanitized domain and numeric code.

Prepare a disposable SillyTavern copy with the workflow's pinned revision and
dependencies. Do not use a personal installation: compatibility preparation
modifies dependencies and the startup loader can patch them again.

```sh
# Run preparation with Node 22 from this branch.
node native-src/patch-sillytavern.mjs /path/to/disposable/SillyTavern
ST_DISABLE_SHARP=true node scripts/prepare-ios-frontend.mjs /path/to/disposable/SillyTavern
cp native-src/ios-loader.mjs native-src/patch-sillytavern.mjs /path/to/disposable/SillyTavern/

# Switch to Node 18.20.4, matching the embedded NodeMobile version.
SILLYCLIENT_IOS_SERVER=/path/to/disposable/SillyTavern \
  node --test tests/ios-runtime.test.mjs tests/ios-server.test.mjs
```

`SILLYCLIENT_TEST_TMP` sets the temporary directory parent.
`SILLYCLIENT_TEST_LOG` optionally preserves the full server subprocess log.
The integration test uses fresh synthetic user data and an ephemeral loopback
port. It disables WASM, blocks runtime Webpack imports, checks outbound fetch
against the local server, and verifies homepage and asset responses. Its second
case runs the production supervisor and loader with the real prepared server,
checks actual Worker fetch/response classes, confirms listener closure, and
restarts with a new operation in the same host process. Worker output is decoded
from its identity-bound frames rather than treating a host log as Worker proof.
Both cases kill and await their child processes before clearing markers and
removing synthetic data. Run them serially for any one prepared server copy.

The host integration test intentionally uses Node 18.20.4. Desktop Node
22.16.0 eagerly initializes Undici through ESM `node:http` exports under
`--jitless`, so it is not an equivalent substitute for this runtime test.
The workflow restores Node 22 before running Capacitor tools.

## Remaining Limits

- A Windows host startup test does not validate NodeMobile's small-ICU build,
  Swift compilation, iOS signing, simulator behavior, or physical devices.
- No-WASM tokenization, image codecs, and model inference are not made
  functional by this startup repair. Their feature-level behavior still needs
  separate validation.
- SillyTavern declares Node >=20; the embedded runtime remains 18.20.4.
  A successful smoke test does not establish full upstream compatibility.
- Existing installations must contain their loader and prebuilt manifest;
  incompatible or partial copied runtimes fail explicitly rather than falling
  back to an unprepared `server.js`. User data can be copied into a fresh pinned
  runtime, but old runtime versions are not upgraded in place.
- The maintenance backend does not authorize synchronizing its new frontend
  panel. That preview retains its separate user approval gate.
- No subjective visual review, physical-device operations, Release, or
  main-branch integration are part of this hardening verification.
