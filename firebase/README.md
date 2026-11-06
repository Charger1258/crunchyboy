# Stream Anime account sync

Status: backend rules and shared contract prepared; not deployed. Neither app is
connected yet. The Firebase project ID and registered client configuration are
required before implementing and testing live sign-in and synchronization.

## Project setup

1. Create a Firebase project on Spark. Analytics is optional and unnecessary for sync.
2. Enable Authentication > Sign-in method > Email/Password.
3. Create Cloud Firestore **Standard edition**, Native mode, in production mode.
   For the initial US deployment, choose a suitable US region before creation;
   the database location cannot be changed in place.
4. Register the Android anime application: `com.example.streamtv.anime`.
5. Register the iPhone application: `com.streamanime.iphone`.
   SideStore changes the installed bundle identifier; email/password sign-in must
   be verified on the signed device build before claiming device compatibility.
6. Provide the project ID and the downloaded `google-services.json` and
   `GoogleService-Info.plist` client configurations. These are client settings,
   not Admin SDK credentials. Do not provide a service-account private key.

No Functions, Storage bucket, hosted website or billing upgrade is required for
the initial implementation. Do not enable permissive test-mode rules. Deploy
the tested rules explicitly to the intended project with:

```sh
npm ci
npm test
npx firebase deploy --project YOUR_PROJECT_ID --only firestore:rules,firestore:indexes
```

Deployment is a separate action after the intended project is identified.

## Shared contract, version 1

Paths:

```
users/{firebaseAuthUid}/profiles/{cloudProfileUuid}
users/{firebaseAuthUid}/profiles/{cloudProfileUuid}/progress/{episodeKey}
```

An account owns its profiles. Profiles within the same account are household
viewers, not separate authentication/security boundaries. Separate accounts
cannot read each other's profiles or history.

Profile fields: `schemaVersion`, `name`, `avatarKey`, `avatarImage`, `deleted`,
`revision`, `updatedAt`. `avatarKey` uses shared asset identifiers rather than
Android drawable indices or Apple SF Symbol names. `avatarImage` is an optional
base64 JPEG thumbnail capped at 64 KiB encoded (empty when absent). It avoids a
Storage dependency; full-resolution avatar uploads are out of scope.

Progress fields and types are enforced in `firestore.rules`. All positions,
durations and original watch dates use integer **milliseconds**. iPhone seconds
and Foundation dates must be converted explicitly. `updatedAt` is a server
timestamp for synchronization; `watchedAtMs` preserves when the viewing actually
happened, including imports. Cloud arrival time must not reorder old imports as
new viewing activity.

The initial provider is `hianime`. Both clients already expose its numeric
episode ID (iPhone `Episode.id`; Android episode URL's `ep` parameter). Use this
provider ID for exact episode matching across the two clients. Document keys
will be SHA-256 of `provider + "\n" + episodeId`, in lowercase hexadecimal;
neither component may contain a newline. Display titles and domains are not
identity keys. `releaseId` retains the provider release; `seriesId` can carry a
verified canonical metadata ID but is empty when unavailable. Do not invent
title-specific mappings or merge episodes solely by season display numbers.

## Required client behavior

- Keep the existing guest library intact. Use separate local storage and queues
  per authenticated UID. Signing out or changing accounts must immediately stop
  the prior listener and switch to the appropriate local library.
- Import guest profiles/history only after an explicit choice. Never merge
  profiles by display name. Assign stable cloud UUIDs and persist mappings for
  Android's local `default` profile and previously created device profiles.
- Save locally at the existing cadence. Coalesce cloud progress writes to about
  30 seconds and flush on pause, close, completion and app backgrounding when
  possible. Persist unsent changes across app restarts, partitioned by UID.
- Store one progress document per episode, not a single replaceable history blob.
  Fetch changes without repeatedly downloading unchanged history or avatar data.
- New documents start at revision 1. Updates must increment the existing revision
  exactly once. Keep the expected remote revision with each local queued mutation.
  After reconnecting, re-read the server revision before submitting queued work.
- If that revision changed on another device, preserve the local conflict and
  prefer the remote state until reconciled. Do not blindly retry with an increased
  revision: that would let stale offline progress overwrite newer viewing.
  Intentionally seeking backwards or rewatching is valid and must not be replaced
  by a simplistic maximum-position merge.
- Keep deletion tombstones so offline clients cannot accidentally resurrect
  removed history. Deleted profiles cannot accept progress writes. Restoring a
  deleted item requires an intentional mutation against its current revision.
- A remote update must never seek or change a currently playing episode. Apply it
  to the library and use it the next time playback is opened.
- Use Firebase SDK session persistence/refresh, never store account passwords in
  the cloud or sync provider login credentials, cookies or expiring stream URLs.

## Verification

`npm test` uses only the `demo-stream-anime-sync` Firestore emulator on loopback,
with synthetic records. It does not log in, read imported history, or contact a
live database. Node 22 and Java 21 are supported by the pinned tooling.

The rule tests cover account isolation, malformed documents, server timestamps,
revision conflicts, intentional backwards seeks, deletion tombstones, missing or
deleted parent profiles, and bounded profile/avatar data.

Before release, test real phone-to-TV and TV-to-phone resume, next-up completion,
offline reconnect conflicts, process restart with queued changes, account A/B
switching, existing-library migration, auth session restoration, and profile
avatar transfer. Emulator rule tests do not prove those client flows work.
