import {readFile} from 'node:fs/promises';
import {after, before, beforeEach, test} from 'node:test';
import {initializeTestEnvironment, assertFails, assertSucceeds} from '@firebase/rules-unit-testing';
import {doc, getDoc, getDocs, collection, setDoc, updateDoc, deleteDoc, serverTimestamp} from 'firebase/firestore';

let env;
before(async () => {
  env = await initializeTestEnvironment({projectId: 'demo-stream-anime-sync', firestore: {
    host: '127.0.0.1', port: 8088, rules: await readFile(new URL('../firestore.rules', import.meta.url), 'utf8')
  }});
});
after(async () => { await env?.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); });
const db = (user = 'alice') => env.authenticatedContext(user).firestore();
const profilePath = 'users/alice/profiles/profile-1';
const progressPath = profilePath + '/progress/hianime-123';
const profile = () => ({schemaVersion: 1, name: 'Me', avatarKey: 'cat', avatarImage: '', deleted: false,
  revision: 1, updatedAt: serverTimestamp()});
const progress = () => ({schemaVersion: 1, provider: 'hianime', episodeId: '123', releaseId: 'sample-release',
  seriesId: '', season: 1, episodeNumber: 1, title: 'Synthetic test title', episodeTitle: 'Episode 1', posterUrl: '',
  positionMs: 30000, durationMs: 1200000, completed: false, watchedAtMs: Date.now(), revision: 1,
  sessionId: 'session-1', deviceId: 'phone', deleted: false, updatedAt: serverTimestamp()});
async function seed() {
  const store = db();
  await setDoc(doc(store, profilePath), profile());
  await setDoc(doc(store, progressPath), progress());
  return store;
}
test('owner can create, read and list their profiles and progress', async () => {
  const store = await seed();
  await assertSucceeds(getDoc(doc(store, progressPath)));
  await assertSucceeds(getDocs(collection(store, 'users/alice/profiles')));
  await assertSucceeds(getDocs(collection(store, profilePath + '/progress')));
});
test('other accounts and anonymous clients cannot read or change private data', async () => {
  await seed();
  for (const store of [db('bob'), env.unauthenticatedContext().firestore()]) {
    await assertFails(getDoc(doc(store, profilePath)));
    await assertFails(getDocs(collection(store, profilePath + '/progress')));
    await assertFails(setDoc(doc(store, progressPath), progress()));
    await assertFails(setDoc(doc(store, 'users/alice/profiles/new'), profile()));
  }
});
test('stale device revision cannot overwrite newer progress', async () => {
  const store = await seed();
  await assertSucceeds(updateDoc(doc(store, progressPath), {positionMs: 60000, revision: 2, updatedAt: serverTimestamp()}));
  await assertFails(setDoc(doc(store, progressPath), {...progress(), revision: 2}));
  await assertFails(updateDoc(doc(store, progressPath), {watchedAtMs: 1, revision: 3, updatedAt: serverTimestamp()}));
  // An intentional seek backwards is valid against the latest revision.
  await assertSucceeds(updateDoc(doc(store, progressPath), {positionMs: 10000, revision: 3, updatedAt: serverTimestamp()}));
});
test('deletions use revisioned tombstones rather than removing sync history', async () => {
  const store = await seed();
  await assertFails(deleteDoc(doc(store, progressPath)));
  await assertSucceeds(updateDoc(doc(store, progressPath), {deleted: true, revision: 2, updatedAt: serverTimestamp()}));
  await assertFails(setDoc(doc(store, progressPath), progress()));
  await assertFails(deleteDoc(doc(store, profilePath)));
});
test('deleted or missing profiles cannot receive progress', async () => {
  const store = db();
  await assertFails(setDoc(doc(store, progressPath), progress()));
  await setDoc(doc(store, profilePath), {...profile(), deleted: true});
  await assertFails(setDoc(doc(store, progressPath), progress()));
});
test('invalid times, unknown fields and client update timestamps are rejected', async () => {
  const store = await seed();
  for (const bad of [{positionMs: -1}, {positionMs: 1200001}, {durationMs: '1200000'},
    {password: 'must-not-be-stored'}, {updatedAt: new Date(0)}, {watchedAtMs: Date.now() + 86400000}]) {
    await assertFails(setDoc(doc(store, progressPath), {...progress(), revision: 2, ...bad}));
  }
});
test('episode identity cannot be changed under an existing progress key', async () => {
  const store = await seed();
  await assertFails(updateDoc(doc(store, progressPath), {episodeId: '456', revision: 2, updatedAt: serverTimestamp()}));
});
test('profile names, avatars and revision updates are bounded', async () => {
  const store = await seed();
  await assertFails(updateDoc(doc(store, profilePath), {name: '', revision: 2, updatedAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(store, profilePath), {avatarImage: 'x'.repeat(65537), revision: 2, updatedAt: serverTimestamp()}));
  await assertSucceeds(updateDoc(doc(store, profilePath), {name: 'Renamed', revision: 2, updatedAt: serverTimestamp()}));
});

test('watchlist removals survive offline saves and can be intentionally restored', async () => {
  const store = await seed();
  const path = profilePath + '/watchlist/synthetic-show-123';
  const changedAtMs = Date.now() - 1000;
  await assertSucceeds(setDoc(doc(store, path), {schemaVersion: 1, title: 'Synthetic show',
    posterUrl: '', deleted: false, changedAtMs, revision: 1, updatedAt: serverTimestamp()}));
  await assertFails(getDoc(doc(db('bob'), path)));
  await assertSucceeds(updateDoc(doc(store, path), {deleted: true, changedAtMs: changedAtMs + 2, revision: 2, updatedAt: serverTimestamp()}));
  await assertFails(updateDoc(doc(store, path), {deleted: false, changedAtMs: changedAtMs + 1, revision: 3, updatedAt: serverTimestamp()}));
  await assertSucceeds(updateDoc(doc(store, path), {deleted: false, changedAtMs: changedAtMs + 3, revision: 3, updatedAt: serverTimestamp()}));
});

test('caption preferences are private and reject unknown values', async () => {
  const store = await seed();
  const path = profilePath + '/settings/playback';
  const changedAtMs = Date.now() - 1000;
  await assertSucceeds(setDoc(doc(store, path), {schemaVersion: 1, subtitleLanguage: 'ar',
    subtitleSize: 'large', changedAtMs, revision: 1, updatedAt: serverTimestamp()}));
  await assertFails(getDoc(doc(db('bob'), path)));
  await assertFails(updateDoc(doc(store, path), {subtitleSize: 'huge', changedAtMs: changedAtMs + 1, revision: 2, updatedAt: serverTimestamp()}));
  await assertSucceeds(updateDoc(doc(store, path), {subtitleLanguage: 'off', changedAtMs: changedAtMs + 1, revision: 2, updatedAt: serverTimestamp()}));
});

test('release-local episode numbers are optional, bounded and support split seasons', async () => {
  const store = await seed();
  await assertSucceeds(updateDoc(doc(store, progressPath), {localEpisodeNumber: 1, episodeNumber: 13, revision: 2, updatedAt: serverTimestamp()}));
  for (const value of [-1, 1000001, '1']) {
    await assertFails(updateDoc(doc(store, progressPath), {localEpisodeNumber: value, revision: 3, updatedAt: serverTimestamp()}));
  }
});
