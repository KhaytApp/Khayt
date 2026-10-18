import Foundation
import UniformTypeIdentifiers
import AppKit
import Observation
import KhaytCore

extension Shop {

    // MARK: - Keeping the shop's data

    /// Take the day's backup, once, when a real book is opened.
    ///
    /// A shop running only this app had no backup at all — one disk failure
    /// from losing its book. Khayt writes one a day into the same folder, so
    /// between them the two apps keep one set of backups rather than two that
    /// each know half the days.
    ///
    /// Failure is recorded and not raised: a backup that could not be written
    /// is worth saying out loud, and is not a reason to refuse to open the
    /// book it was protecting.
    func keepTheDaysBackup() async {
        guard let build = source.build else { lastBackup = nil; return }
        // Only the app holding the book. Two apps writing the same folder in
        // the same second is a race for no gain, and the one that does not own
        // the store is the one reading a copy.
        guard StoreLock.weOwnIt(build) else {
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            return
        }
        do {
            _ = try await Backups.writeDaily(for: build, engine: engine)
            backupProblem = nil
        } catch {
            backupProblem = self.said(error)
        }
        lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
        lastCrash = LastWords.read(for: build)
    }

    // MARK: - What the cloud held, last time this app looked

    /// The cloud's own store as this app last saw it, and the revision it was.
    ///
    /// ── WHY THIS HAS TO EXIST FOR `?since=` TO ────────────────────────────
    ///
    /// khayt-cloud sends the base blob ONLY to a caller that is behind it. A
    /// device that is already current asks `?since=N` and gets the deltas
    /// after N and nothing else — which is the entire saving, and which leaves
    /// nothing to fold those deltas onto unless the device kept the store it
    /// had at N. So the two changes are one change.
    ///
    /// IN MEMORY, NOT ON DISK, deliberately. A relaunch pulls cold exactly as
    /// this app always has, which is the behaviour every failure falls back to
    /// — and nothing here has to be reconciled with a book on disk that is the
    /// SHOP's copy, not the cloud's. The two are different stores and confusing
    /// them is how a sync writes somebody else's records over yours.
    struct CloudSeen {
        /// The shop it belongs to. A book that switches clouds must not fold a
        /// new shop's chain onto an old shop's store.
        let shopId: String
        let rev: Int
        let store: [String: JSONValue]
    }

    /// The highest revision this book has seen of its cloud, per shop — the
    /// client-side rollback check (`CloudReader.RevisionMemory`). Kept in user
    /// defaults for a book on disk; a book with no file behind it (the sample,
    /// and tests) keeps it in memory only.
    var cloudRevisions: CloudReader.RevisionMemory {
        source.build == nil ? ephemeralCloudRevisions : .standard
    }

    /// The revision a pull was refused at for going backwards, while it still is.
    var cloudRollbackRefused: Int? {
        guard let connection = try? CloudReader.connection(settingsDict) else { return nil }
        return cloudRevisions.refusal(connection)
    }

    /// The shop reset or restored its cloud on purpose: carry on from the
    /// older copy. The next check pulls it cold, as after any reset.
    func acceptCloudRollback() {
        guard let connection = try? CloudReader.connection(settingsDict) else { return }
        if cloudRevisions.accept(connection) {
            cloudSeen = nil
            cloudProblem = nil
        }
    }

    /// Pull the cloud's store, asking only for what this app has not seen.
    ///
    /// Falls back to a cold pull — no `since`, base included — whenever the
    /// cache cannot be trusted, and that list is the whole safety argument:
    ///
    ///   * no cache at all (first pull of the run, or after a whole-book push);
    ///   * a cache belonging to a different shop;
    ///   * a reply whose head is BEHIND the cache, which means the cloud went
    ///     backwards — a reset, or a restore from a backup. Folding a shorter
    ///     chain onto a store from the future would report this device's own
    ///     records as the cloud's, and then push them.
    ///
    /// A cold pull is what this app did on every save until now, so every one
    /// of those is a return to the old cost, never to a wrong answer.
    func pullCloudStore(_ connection: CloudReader.Connection, token: String,
                        dek: Data, engine: KhaytEngine,
                        fetch: (URLRequest) async throws -> (Data, URLResponse))
    async throws -> (reply: CloudReader.Reply, folded: CloudReader.Folded) {
        let warm = cloudSeen.flatMap { $0.shopId == connection.shopId ? $0 : nil }
        if let warm {
            let reply = try await CloudReader.pull(connection, token: token,
                                                   since: warm.rev, memory: cloudRevisions,
                                                   fetch: fetch)
            if reply.rev >= warm.rev {
                let folded = try await CloudReader.store(reply, dek: dek, engine: engine,
                                                         onto: warm.store)
                cloudSeen = CloudSeen(shopId: connection.shopId, rev: reply.rev,
                                      store: folded.store)
                return (reply, folded)
            }
            // The cloud is behind what this app remembers. Distrust the memory.
            cloudSeen = nil
        }
        let reply = try await CloudReader.pull(connection, token: token,
                                               memory: cloudRevisions, fetch: fetch)
        let folded = try await CloudReader.store(reply, dek: dek, engine: engine)
        cloudSeen = CloudSeen(shopId: connection.shopId, rev: reply.rev, store: folded.store)
        return (reply, folded)
    }

    /// Remember what the cloud holds now that this device has changed it.
    ///
    /// After a delta push the cloud's store is the one just pulled with this
    /// payload folded on — which `sendToCloud` computes anyway, to say what is
    /// true now rather than what was true before the send.
    func rememberCloud(shopId: String, rev: Int, store: [String: JSONValue]) {
        cloudSeen = CloudSeen(shopId: shopId, rev: rev, store: store)
    }

    /// Forget it. Used after a whole-book push, where what the service ended up
    /// holding is worth one cold pull rather than an argument.
    func forgetCloud() { cloudSeen = nil }

    /// What this sign-in may do to the shop, as the cloud recorded it.
    ///
    /// `settings.cloud.role` is written by `CloudSignIn`. The service refuses
    /// a WRITE from `viewer` and allows every other role — `owner` for the
    /// shop's own token, and a member account's role otherwise — so the rule
    /// is stated the way the server states it: only a viewer is stopped.
    ///
    /// UNKNOWN IS ALLOWED, deliberately, and it is the opposite of the usual
    /// rule here. A book that predates this field, or one that arrived by
    /// restore, has no role at all — and refusing to sync it would break
    /// syncing for every existing install to guard against a case the server
    /// already refuses properly. The server is the authority; this only saves
    /// a viewer from being told its token is broken.
    var cloudRoleCanWrite: Bool { Self.cloudRoleCanWrite(settingsDict) }

    static func cloudRoleCanWrite(_ settings: [String: JSONValue]) -> Bool {
        guard case .object(let cloud)? = settings["cloud"],
              case .string(let role)? = cloud["role"] else { return true }
        return role.lowercased() != "viewer"
    }

    /// The same, as a function of the settings alone — `settingsValue` is only
    /// the model's to set, and a rule about a shop's data should be testable
    /// without building one.
    static func cloudConnected(_ settings: [String: JSONValue]) -> Bool {
        guard case .object(let cloud)? = settings["cloud"] else { return false }
        if case .bool(let on)? = cloud["enabled"], on == false { return false }
        guard case .string(let shop)? = cloud["shopId"], !shop.isEmpty else { return false }
        // A shop that started connecting and never finished is not connected,
        // and telling it its changes are stranded would be a false alarm.
        if case .bool(let verified)? = cloud["verified"] { return verified }
        return false
    }

    // MARK: - What the cloud holds

    // MARK: - Orders a storefront has already sent

    func publishLivePrinters() async {
        guard case .store(let build) = source else { return }
        let connection = try? CloudReader.connection(settingsDict)
        await livePublisher.publishIfDue(
            rows: machinesLive(), connection: connection, dek: cloudDek, canWrite: cloudRoleCanWrite,
            token: { [weak self] in
                guard let self, let c = connection else { return nil }
                _ = self
                return try? await Secrets.open(c.storedToken, for: build)
            })
    }

    /// Has somebody unlocked the cloud this session?
    var cloudUnlocked: Bool { cloudDek != nil }

    /// The key the off-site backup seals the book with — the cloud's own data
    /// key, so a backup opens on a new Mac with the passphrase. Nil while the
    /// cloud is locked or not set up, and then nothing is uploaded.
    var offsiteKey: Data? { cloudDek }

    /// "Remember me on this Mac", from the sign-in sheet. On unless the shop
    /// turned it off: keeping the key is what stops the passphrase being asked
    /// at every launch, and a shared Mac is the case to opt out for.
    static let rememberCloudKeyDefault = "cloud.rememberOnThisMac"
    static var rememberCloudKey: Bool {
        UserDefaults.standard.object(forKey: rememberCloudKeyDefault) as? Bool ?? true
    }

    /// Keep the unwrapped key on this Mac, or make sure none is kept, as the
    /// shop chose.
    private func keepCloudKey(_ dek: Data, keyset: [String: JSONValue], shopId: String) async {
        if Self.rememberCloudKey {
            await CloudKeyMemory.remember(dek, fingerprint: CloudKeyMemory.fingerprint(of: .object(keyset)) ?? "",
                                          shopId: shopId)
        } else {
            await CloudKeyMemory.forget(shopId: shopId)
        }
    }

    /// The book's side of signing out: `settings.cloud.enabled = false`, and
    /// everything else in `settings.cloud` left as it was — the other app's
    /// Disconnect writes exactly this.
    nonisolated static func markSignedOut(_ root: inout [String: JSONValue]) {
        var settings = Self.settings(root)
        guard case .object(var cloud)? = settings["cloud"] else { return }
        cloud["enabled"] = .bool(false)
        settings["cloud"] = .object(cloud)
        root["settings"] = .object(settings)
    }

    /// Sign this Mac out of Khayt Cloud.
    ///
    /// What the other app's Disconnect does, and nothing more: stop syncing,
    /// drop the key (here, and the copy kept in the Keychain), and write
    /// `settings.cloud.enabled = false`. The book and the cloud copy both stay,
    /// and the address and email are kept so signing in again is two fields.
    func signOutOfCloud() async {
        guard permitted("cloud", "edit") else { return }
        forgetCloudKey()
        guard let build = source.build else { return }
        do {
            try await StoreWriter.updateOffMain(build) { root in Self.markSignedOut(&root) }
            await load(source)
            moveNotices = [words.callIt("mac.cloud_signed_out")]
        } catch {
            cloudProblem = self.said(error)
        }
    }

    private var cloudShopId: String? {
        guard case .object(let cloud)? = settingsDict["cloud"],
              case .string(let shopId)? = cloud["shopId"], !shopId.isEmpty else { return nil }
        return shopId
    }

    /// Unlock with the key this Mac kept at the last unlock, so opening the
    /// app does not ask for the passphrase again. Only while the book's keyset
    /// is the one that key came from; see `CloudKeyMemory`.
    func restoreCloudKey() async {
        guard permitted("cloud", "edit") else { return }
        guard Self.rememberCloudKey,
              cloudDek == nil, !cloudLockedByShop, Self.cloudConnected(settingsDict), let shopId = cloudShopId,
              let print = CloudKeyMemory.fingerprint(of: cloudKeyset()) else { return }
        guard let dek = await CloudKeyMemory.recall(shopId: shopId, fingerprint: print),
              cloudDek == nil else { return }
        cloudDek = dek
    }

    /// Lock the cloud again: drop the data key and stop syncing until somebody
    /// unlocks it. The shop's own choice, from the menu bar.
    func forgetCloudKey() {
        // The cloud is the owner's (lib/rbac.js `cloud`).
        guard permitted("cloud", "edit") else { return }
        // Off this Mac as well: "Lock" means the next launch asks again.
        if let shopId = cloudShopId { Task { await CloudKeyMemory.forget(shopId: shopId) } }
        // And no restore this session: the Keychain delete runs off the main
        // actor, and a reload in between would read the old key straight back.
        cloudLockedByShop = true
        cloudDek = nil
        cloudSent = nil
        // And what the cloud held, which is a decrypted copy of the shop's
        // book: locking the cloud and keeping its contents in memory would
        // be the opposite of what the menu item says.
        forgetCloud()
        cancelPendingSync()
        syncStatus = Self.cloudConnected(settingsDict) ? .locked : .off
    }

    /// Is there anything this Mac could send, and the key to send it with?
    var canSendToCloud: Bool {
        cloudDek != nil && !cloudBusy && (cloudCheck?.sendable ?? 0) > 0
    }

    /// Ask Khayt Cloud what it holds and say how far apart the two books are.
    ///
    /// READ ONLY. Nothing is pushed, nothing is merged and nothing is written
    /// on either side — this counts. `cloud-backend.js` §7 is why: a push with
    /// a baseRev the server accepts replaces its newer copy and every device
    /// pulls the older store down, with nothing said. Counting cannot do that.
    ///
    /// The passphrase is asked for, used, and not kept. It is the one thing
    /// Khayt deliberately stores nowhere — that is what makes the cloud copy
    /// end-to-end encrypted — so this app must ask each time and hold it no
    /// longer than the unwrap.
    /// Sign this Mac in to the shop's cloud, and unlock it in the same breath.
    ///
    /// THE TOKEN IS A SESSION, NOT A SETTING. The server issues it at login and
    /// it is sealed against the Keychain of the machine that asked — so a book
    /// carried to another Mac arrives with a token nothing here can read, and
    /// until this existed the only cure was to open the other app. That is the
    /// one thing this app is for not needing.
    ///
    /// Four things happen, in this order and for these reasons:
    ///
    ///   1. **Log in**, which is the only part that was missing.
    ///   2. **Unwrap the keyset with the passphrase, BEFORE anything is
    ///      written.** A token saved beside a passphrase that does not fit
    ///      leaves the shop connected and unable to read a word of its own
    ///      cloud data, which looks like the server losing it.
    ///   3. **Seal the token.** A token written in plaintext would sit in a
    ///      file that syncs, backs up and exports. `Secrets.seal` refuses
    ///      rather than downgrading, so a Mac with no Keychain is told.
    ///   4. **Write `settings.cloud` whole**, inside the write chain — the
    ///      same shape `renderer/settings.js` writes, so the other app reads
    ///      this Mac's sign-in as its own.
    ///
    /// The passphrase is used and not kept, the way `checkCloud` uses it: it is
    /// the one thing Khayt stores nowhere, which is what makes the cloud copy
    /// end-to-end encrypted.
    func signInToCloud(url: String, email: String, password: String,
                       passphrase: String) async {
        guard permitted("cloud", "edit") else { return }
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let session = try await CloudSignIn.logIn(url: url, email: email,
                                                      password: password, engine: engine)
            // ── WHERE THE KEYSET COMES FROM, AND WHY BOTH PLACES COUNT ────
            //
            // The server returns `keyset: null` from login quite legitimately —
            // it is stored and fetched separately (`PUT /v1/shops/{id}/keyset`),
            // and login does not always carry it. The book has its own copy,
            // which is what `checkCloud` has always unlocked with.
            //
            // So: the server's when it sends one, because another device may
            // have rotated it; otherwise the book's. Demanding it from the
            // login response refused a shop whose book HAS a key — which is
            // precisely the restored-book case this whole path exists for, and
            // it is how this was found.
            var fromServer = true
            var keysetValue = session.keyset
            if keysetValue == nil {
                keysetValue = cloudKeyset()
                fromServer = false
            }
            guard case .object(let keyset)? = keysetValue else {
                throw CloudSignIn.Failure.noKeyset
            }
            guard case .object(let wrappedFields)? = keyset["wrappedByPassphrase"],
                  let wrapped = try? JSONDecoder().decode(
                      SyncCrypto.Blob.self,
                      from: JSONEncoder().encode(JSONValue.object(wrappedFields)))
            else {
                throw CloudReader.Failure.malformed("the keyset has no passphrase-wrapped key")
            }
            // Before the write, so a wrong passphrase changes nothing.
            // The keyset says how its key was stretched — `lib/sync-crypto.js`
            // writes `kdf` when it creates one and reads it back to unlock.
            // Built-in defaults would refuse a keyset made with anything else,
            // with a decryption error that says nothing about why.
            let dek = try SyncCrypto.unwrapDek(secret: passphrase, wrapped: wrapped,
                                               kdf: SyncCrypto.Kdf.from(keyset["kdf"]))
            let sealed = try await Secrets.seal(session.token, for: build)

            try await StoreWriter.updateOffMain(build) { root in
                var settings = Self.settings(root)
                // `lastServerRev: 0` on purpose, exactly as the other app writes
                // it: this machine has seen nothing from the server yet, and a
                // carried-over rev would let a push claim a base it never read.
                settings["cloud"] = .object([
                    "enabled": .bool(true),
                    "url": .string(url),
                    "email": .string(email),
                    "shopId": .string(session.shopId),
                    "token": .string(sealed),
                    "keyset": .object(keyset),
                    "lastServerRev": .number(0),
                    "verified": .bool(session.verified),
                    "role": .string(session.role),
                ])
                root["settings"] = .object(settings)
            }

            cloudDek = dek
            cloudLockedByShop = false
            // Kept on this Mac, so the next launch does not ask again.
            await keepCloudKey(dek, keyset: keyset, shopId: session.shopId)
            if case .locked = syncStatus { syncStatus = .idle }
            Telemetry.feature(.cloudSignedIn, in: self)
            await load(source)
            // ── A KEY ONLY THIS BOOK HOLDS GOES TO THE CLOUD ──────────────
            //
            // The server sent none, and the book's has just been proven with
            // the passphrase. A server with no keyset cannot hand the key to
            // the NEXT device — a phone stops at "no keyset" and never syncs —
            // so it is published now, only if the cloud truly has none
            // (`KeysetPublisher`), and then the book is sent: a keyset with
            // nothing behind it is a shop that restores to empty.
            var published = false
            if !fromServer, session.role != "viewer" {
                do {
                    let connection = CloudReader.Connection(url: url, shopId: session.shopId, storedToken: sealed)
                    let web = CloudReader.session
                    published = try await KeysetPublisher.publishIfAbsent(
                        connection, token: session.token, keyset: keyset) { try await web.data(for: $0) } == .published
                } catch {
                    cloudProblem = words.callIt("mac.cloud_key_not_published") + " "
                        + ((error as? CustomStringConvertible)?.description ?? self.said(error))
                }
                if published { await sendToCloud() }
            }
            moveNotices = fromServer || published
                ? [words.callIt("mac.cloud_signed_in")] + (published ? [words.callIt("mac.cloud_key_published")] : [])
                : [words.callIt("mac.cloud_signed_in"), words.callIt("mac.cloud_key_local")]
        } catch let failure as CloudSignIn.Failure {
            cloudProblem = failure.errorDescription ?? String(describing: failure)
        } catch let locked as Secrets.Failure {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " " + locked.description
        } catch let crypto as SyncCrypto.Failure {
            // The overwhelmingly common one, and worth its own sentence: the
            // login succeeded and the passphrase did not fit.
            cloudProblem = words.callIt("mac.cloud_wrong_passphrase")
                + " (" + String(describing: crypto) + ")"
        } catch {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? self.said(error))
        }
    }

    /// Ask the cloud to email a reset code.
    ///
    /// Nothing is written and nothing changes until the code comes back with a
    /// new password. What this reports is whether the SERVER can send mail at
    /// all — a server with none configured accepts the request and delivers
    /// nothing, which from a shop's side looks exactly like an email that has
    /// not arrived yet, and it would wait for it.
    func requestPasswordReset(url: String, email: String) async {
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let engine else { cloudProblem = words.callIt("mac.move_no_engine"); return }
        do {
            let sent = try await CloudSignIn.requestReset(url: url, email: email, engine: engine)
            if !sent.configured {
                cloudProblem = words.callIt("mac.cloud_reset_no_mail")
            } else if sent.failed {
                cloudProblem = words.callIt("mac.cloud_reset_send_failed")
            } else {
                moveNotices = [words.callIt("mac.cloud_reset_sent", ["email": .string(email)])]
            }
        } catch {
            cloudProblem = words.callIt("mac.cloud_signin_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? self.said(error))
        }
    }

    /// Set a new account password with the emailed code.
    ///
    /// THE ACCOUNT PASSWORD ONLY. The shop's data stays encrypted under the key
    /// the sync passphrase wraps, which this cannot read and does not touch —
    /// so a shop that has lost its PASSPHRASE is not helped by this, and needs
    /// its recovery key. The sheet says so where it can be read before typing.
    ///
    /// No sign-in follows automatically: the new password is a thing the person
    /// just chose and may have mistyped into a password manager, and signing in
    /// with it is the proof that it is what they think it is.
    func resetCloudPassword(url: String, email: String, code: String,
                            newPassword: String) async {
        cloudProblem = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let engine else { cloudProblem = words.callIt("mac.move_no_engine"); return }
        do {
            try await CloudSignIn.resetPassword(url: url, email: email, code: code,
                                                newPassword: newPassword, engine: engine)
            moveNotices = [words.callIt("mac.cloud_reset_done")]
        } catch {
            cloudProblem = words.callIt("mac.cloud_reset_failed") + " "
                + ((error as? LocalizedError)?.errorDescription ?? self.said(error))
        }
    }

    func checkCloud(passphrase: String) async {
        guard permitted("cloud", "edit") else { cloudProblem = moveProblem; return }
        cloudProblem = nil
        cloudCheck = nil
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }

            let reply = try await CloudReader.pull(connection, token: token,
                                                   memory: cloudRevisions) { request in
                try await CloudReader.session.data(for: request)
            }
            guard case .object(let keyset)? = cloudKeyset() else {
                throw CloudReader.Failure.malformed("this book has no keyset to unlock")
            }
            guard case .object(let wrappedFields)? = keyset["wrappedByPassphrase"],
                  let wrapped = try? JSONDecoder().decode(
                      SyncCrypto.Blob.self, from: JSONEncoder().encode(JSONValue.object(wrappedFields)))
            else {
                throw CloudReader.Failure.malformed("the keyset has no passphrase-wrapped key")
            }
            // The keyset says how its key was stretched — `lib/sync-crypto.js`
            // writes `kdf` when it creates one and reads it back to unlock.
            // Built-in defaults would refuse a keyset made with anything else,
            // with a decryption error that says nothing about why.
            let dek = try SyncCrypto.unwrapDek(secret: passphrase, wrapped: wrapped,
                                               kdf: SyncCrypto.Kdf.from(keyset["kdf"]))
            cloudDek = dek
            cloudLockedByShop = false
            await keepCloudKey(dek, keyset: keyset, shopId: connection.shopId)
            // Unlocked. From here on this app pushes on its own, and the first
            // push carries whatever was changed while it was locked.
            if case .locked = syncStatus { syncStatus = .idle }
            let folded = try await CloudReader.store(reply, dek: dek, engine: engine)

            // Read from disk rather than from what this app is holding: the
            // screens decode two collections out of thirty-three, and a
            // comparison built from those would report thirty-one as missing.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONValue.decode([String: JSONValue].self, from: $0) } ?? [:]
            let collections = (try? await engine.storeCollections()) ?? []
            cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                              collections: collections, cloudRev: reply.rev,
                                              chain: folded.chain, applied: folded.applied)
            // Asked here rather than on the send, so a shop is told about a
            // setting this app cannot carry BEFORE it presses a button that
            // will not carry it.
            cloudSettingsStay = (try? await engine.changesToSend(local: mine, server: folded.store))?
                .settingsDiffer ?? false
        } catch let failure as CloudReader.Failure {
            cloudProblem = words.cloudFailure(failure)
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = self.said(error)
        }
    }

    /// Send the half of the difference that is only on this Mac.
    ///
    /// It **pulls again first**, and that is not politeness — it is the whole
    /// safety property. The payload has to be measured against the store the
    /// cloud holds at the moment of sending, and `baseRev` has to be that same
    /// pull's revision, or the service's optimistic guard is guarding nothing.
    /// Anything that arrived between the check and the button then shows up as
    /// a 409 and this refuses, instead of appending a change computed against
    /// a store that no longer exists.
    ///
    /// It appends and never replaces. See `CloudWriter` for why that line is
    /// where the danger lives.
    /// `byPerson: false` is auto-sync, which runs whoever is signed in — the
    /// owner switched it on, and a lock must not stop a shop's book reaching
    /// its own cloud. A person pressing Send asks the lock (`cloud`).
    func sendToCloud(byPerson: Bool = true) async {
        if byPerson { guard permitted("cloud", "edit") else { cloudProblem = moveProblem; return } }
        cloudProblem = nil
        cloudSent = nil
        guard !restoreInProgress else { cloudProblem = words.callIt("mac.restore_wait_sync"); return }
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine, let dek = cloudDek else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }
            // ── A VIEWER IS TOLD ONCE, BEFORE ANYTHING IS SENT ────────────
            //
            // The service answers 403 to every write from a viewer's account,
            // and this app said "the token may have been reset" and retried —
            // forever, on a backoff, about a sign-in that is working exactly
            // as intended. Sign-in already saves the role; reading it here
            // means the shop is told the truth without a request at all.
            guard cloudRoleCanWrite else { throw CloudWriter.Failure.readOnly }

            let session = CloudReader.session
            // ASKS ONLY FOR WHAT IT HAS NOT SEEN. This runs before every push,
            // and every push used to re-download the base and the whole chain.
            let (reply, folded) = try await pullCloudStore(
                connection, token: token, dek: dek, engine: engine) { request in
                try await session.data(for: request)
            }
            // A restore wins before anything is measured. See `RestoreGuard`.
            let restorePending = try await holdRestore(build: build, cloud: folded.store)
            // From disk, for the same reason the comparison reads from disk:
            // the screens hold two collections out of thirty-three, and a
            // payload built from those would claim the other thirty-one are
            // gone.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONValue.decode([String: JSONValue].self, from: $0) } ?? [:]
            // MASKED FIRST, like the whole-book push. `machines` is an array
            // collection, so deltas carry it, and its printer access codes and
            // smart-plug passwords are sealed on disk with THIS Mac's key. Sent
            // as they were, another computer took the higher-rev copy, replaced
            // its own sealed value with one it cannot open, and lost its
            // printer — and the ciphertext sat in the cloud. A mask is what
            // `keepSecrets` knows to leave alone on the other side.
            let outbox = try await engine.changesToSend(local: try await engine.storeForCloud(mine),
                                                        server: folded.store)
            cloudSettingsStay = outbox.settingsDiffer

            let collections = (try? await engine.storeCollections()) ?? []
            guard !outbox.isEmpty else {
                await cloudAgrees(build: build, shopId: connection.shopId, engine: engine,
                                  book: mine, cloud: folded.store, restored: restorePending)
                // Nothing to do is not a failure. Show the fresh comparison so
                // the screen stops offering a button that would do nothing.
                cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                                  collections: collections, cloudRev: reply.rev,
                                                  chain: folded.chain, applied: folded.applied)
                return
            }

            do {
                cloudSent = try await CloudWriter.send(connection, token: token, payload: outbox,
                                                       dek: dek, baseRev: reply.rev,
                                                       memory: cloudRevisions) { request in
                    try await session.data(for: request)
                }
            } catch CloudWriter.Failure.notAccepted {
                // THE SHOP'S CHAIN IS CLOSED, and this is not rare: khayt-cloud
                // shuts it for a shop with any device it believes cannot fold a
                // chain, or any live token nobody has been seen using. This
                // shop's is shut, which is how the case was found — a live
                // POST /deltas answers 404 today.
                //
                // Both causes end by opening Khayt on the machine. A device on
                // a build older than v3.6.0 sends no `x-delta-capable` header
                // and is recorded as unable; its next sync after an update
                // overwrites that with a yes. A token that has been issued and
                // never used has no capability row at all, and unknown fails
                // closed — one sync gives it one. (An abandoned login also ages
                // out on its own: tokens carry a 90-day sliding expiry, and the
                // migration that added the column backfilled the rows that
                // predated it, so none of them is immortal. An earlier note
                // here said they never expire. They do.)
                //
                // The desktop falls back to sending the whole store. That is
                // only safe from a book that already holds everything the cloud
                // has, so the merge below is not a courtesy — it is the thing
                // that makes the push legal. Anything arriving in between comes
                // back as a 409 from `baseRev`.
                cloudSent = try await sendWholeBookAfterMerging(
                    connection: connection, token: token, dek: dek, engine: engine,
                    build: build, server: folded.store, baseRev: reply.rev, session: session)
            } catch CloudWriter.Failure.chainFull(let head) {
                // ── THE CHAIN IS FULL, WHICH IS NOT A RACE ────────────────
                //
                // Over 1,000 deltas, or four times the base, or the plan's
                // size. The `rev` in that 409 is this device's OWN baseRev —
                // nobody moved — so read as a race it produced a pull, the
                // same 409, and a retry on a five-minute backoff FOREVER,
                // while the shop's cloud copy quietly stopped updating.
                //
                // A whole `PUT /store` is the only thing that compacts the
                // chain, and it is the same path a closed chain already takes:
                // merge the cloud into this book first, then push, guarded by
                // the rev the merge was folded from.
                _ = head
                cloudSent = try await sendWholeBookAfterMerging(
                    connection: connection, token: token, dek: dek, engine: engine,
                    build: build, server: folded.store, baseRev: reply.rev, session: session)
            }
            // Say what is true NOW, not what was true before the send: fold the
            // payload onto the store that was just pulled, which is exactly
            // what every other device will do when it next pulls the chain.
            let after = try await engine.foldDeltas(base: folded.store, deltas: [outbox.wire])
            // And that IS what the cloud holds now, at the revision it just
            // gave back — so the next pull can ask for nothing but what
            // arrives after it. A whole-book push is not worth reasoning
            // about: it replaced the base and compacted the chain, so the
            // memory is dropped and the next pull is cold.
            if let sent = cloudSent, sent.wholeStore {
                forgetCloud()
            } else if let sent = cloudSent {
                rememberCloud(shopId: connection.shopId, rev: sent.rev, store: after.store)
                await noteSyncAgreement(build: build, shopId: connection.shopId, engine: engine,
                                        book: mine, cloud: after.store)
            }
            // Carried up: the restored book is the cloud's now, and from here
            // the ordinary rule applies to it again.
            if restorePending, cloudSent != nil { RestoreGuard.clear(for: build.storeURL) }
            cloudCheck = CloudCompare.compare(here: mine, there: after.store,
                                              collections: collections,
                                              cloudRev: cloudSent?.rev ?? reply.rev,
                                              chain: folded.chain + 1,
                                              applied: folded.applied + after.applied)
        } catch let failure as CloudWriter.Failure {
            cloudProblem = failure.description
            // A 409 means the comparison on screen is stale. Take it away
            // rather than leave a table that no longer describes anything.
            if case .moved = failure { cloudCheck = nil }
        } catch let failure as CloudReader.Failure {
            cloudProblem = words.cloudFailure(failure)
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = self.said(error)
        }
    }

    /// Is there anything in the cloud this Mac does not have, and may we write?
    var canPullFromCloud: Bool {
        cloudDek != nil && !cloudBusy && canMoveJobs
            && ((cloudCheck?.lines.reduce(0) { $0 + $1.onlyThere + $1.newerThere } ?? 0) > 0)
    }

    /// Bring the cloud's copy down and merge it into this Mac's book.
    ///
    /// THE MOST DANGEROUS THING THIS APP DOES, and the arrangement is what makes
    /// it safe rather than the intention:
    ///
    /// * **A backup first.** Not because the merge is expected to go wrong, but
    ///   because this is the one operation that changes records a shop did not
    ///   touch, and the app already knows how to take one.
    /// * **The read is inside the write.** `StoreWriter.update` reads the book,
    ///   hands it to the merge, re-checks ownership and swaps — so a merge
    ///   computed from a copy that went stale cannot put the stale copy back.
    ///   The engine is an actor, so this is the async form of that chain, and
    ///   the window is a JavaScript call wide.
    /// * **Nothing is stamped.** A merged record keeps the cloud's `rev`.
    ///   Bumping it would make this Mac look like it had edited every record it
    ///   received, and it would push them all straight back.
    /// * **`settings.cloud` is left exactly as it is.** The desktop's own
    ///   `viewSafeForLocal` decides whether its cached server view still holds,
    ///   and after a merge the book has only moved FORWARD — so the view stays
    ///   valid and nothing here has to reach into another app's bookkeeping.
    func pullFromCloud() async {
        guard permitted("cloud", "edit") else { return }
        cloudProblem = nil
        cloudSent = nil
        cloudPulled = nil
        guard !restoreInProgress else { cloudProblem = words.callIt("mac.restore_wait_sync"); return }
        cloudBusy = true
        defer { cloudBusy = false }
        guard let build = source.build, let engine, let dek = cloudDek else {
            cloudProblem = words.callIt("mac.move_sample"); return
        }
        guard canMoveJobs else {
            cloudProblem = words.callIt("mac.read_only"); return
        }
        do {
            let connection = try CloudReader.connection(settingsDict)
            let token = try await Secrets.open(connection.storedToken, for: build)
            guard !token.isEmpty else { throw CloudReader.Failure.unauthorised }

            let session = CloudReader.session
            let (reply, folded) = try await pullCloudStore(
                connection, token: token, dek: dek, engine: engine) { request in
                try await session.data(for: request)
            }

            // Before anything is written. A shop that does not like what came
            // down has this morning's book to go back to, and no copy means no
            // merge.
            try await safetyBackup(build)

            // A restore not yet carried up wins over the cloud's copy, and the
            // shared rule is told what this Mac last agreed on, so an edit
            // made here and overwritten is reported rather than lost quietly.
            var marker = liveRestoreMarker(build)
            await installSyncBaseline(build: build, shopId: connection.shopId, engine: engine)
            let keepAt = SyncLosses.fileURL(for: build.storeURL)
            var report: KhaytEngine.Merged?
            var losses: [SyncLoss] = []
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
                recordingDeletes: false
            ) { root in
                // What the hold overrides is a loss like any other: before,
                // `before` was taken AFTER it, so the cloud copies it replaced
                // never reached sync-conflicts/.
                var overridden: [SyncLoss] = []
                if var held = marker {
                    let out = RestoreGuard.hold(root, over: folded.store, pending: &held)
                    root = out.book
                    overridden = out.overridden
                    marker = held
                }
                let before = root
                let merged = try await engine.mergeFromCloud(local: root, server: folded.store)
                let taken = SyncLosses.compute(before: before, after: merged.store, conflicts: merged.conflicts)
                losses = overridden + taken
                try SyncLosses.keep(losses, at: keepAt)
                root = merged.store
                report = merged
            }
            if let marker { try? RestoreGuard.save(marker, for: build.storeURL) }
            // A viewer can never push, so it can never carry the restore up:
            // held once, and then the ordinary rule.
            if marker != nil, RestoreGuard.afterPull(canWrite: cloudRoleCanWrite, storeURL: build.storeURL) {
                restoreHoldNote = words.callIt("mac.restore_hold_read_only")
            }
            cloudPulled = report
            announceSyncLosses(losses, file: keepAt)
            await load(source)

            // Say what is true now rather than what was true before: compare
            // the book as it stands against the store that was just folded in.
            let mine = (try? Data(contentsOf: build.storeURL))
                .flatMap { try? JSONValue.decode([String: JSONValue].self, from: $0) } ?? [:]
            let collections = (try? await engine.storeCollections()) ?? []
            await noteSyncAgreement(build: build, shopId: connection.shopId, engine: engine,
                                    book: mine, cloud: folded.store)
            cloudCheck = CloudCompare.compare(here: mine, there: folded.store,
                                              collections: collections, cloudRev: reply.rev,
                                              chain: folded.chain, applied: folded.applied)
        } catch let refusal as StoreWriter.Refusal {
            cloudProblem = refusal.description
        } catch let failure as CloudReader.Failure {
            cloudProblem = words.cloudFailure(failure)
        } catch let failure as SyncCrypto.Failure {
            cloudProblem = failure.description
        } catch let locked as Secrets.Failure {
            cloudProblem = locked.description
        } catch {
            cloudProblem = self.said(error)
        }
    }

    /// Merge the cloud into this book, then replace the cloud with this book.
    ///
    /// Only for a shop whose delta chain the service refuses. The order is the
    /// whole safety argument and it is written as one function so the two
    /// halves cannot drift apart: after the merge this book is a superset of
    /// what the cloud held at `baseRev`, so replacing the cloud with it loses
    /// nothing — and if the cloud moved while we were doing it, `baseRev` earns
    /// a 409 and nothing is written at all.
    private func sendWholeBookAfterMerging(
        connection: CloudReader.Connection, token: String, dek: Data, engine: KhaytEngine,
        build: StoreReader.Build, server: [String: JSONValue], baseRev: Int,
        session: URLSession
    ) async throws -> CloudWriter.Sent {
        // A backup first, exactly as a pull takes one: this writes to the book.
        try await safetyBackup(build)

        // ── NOTHING THIS MERGE TAKES GOES IN SILENCE ──────────────────────
        //
        // This runs on its own every quarter of an hour, and it used to apply
        // the cloud's deletes and overwrites with nothing on screen: the
        // conflicts reached `cloudPulled`, which only a sheet nobody had open
        // read, and an overwritten local edit was never even detected because
        // the shared rule was never told what this Mac last agreed on. Now the
        // baseline is installed first, a copy of everything taken is written
        // to `sync-conflicts/` before the book is replaced, and the window
        // says so. (A pending restore was already made to win by `sendToCloud`.)
        await installSyncBaseline(build: build, shopId: connection.shopId, engine: engine)
        let keepAt = SyncLosses.fileURL(for: build.storeURL)
        var merged: KhaytEngine.Merged?
        var losses: [SyncLoss] = []
        var book: [String: JSONValue] = [:]
        // lock: system — cloud sync, after a merge the person (or auto-sync) started; the push sends what is already in the book.
        try await StoreWriter.update(
            storeURL: build.storeURL,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            recordingDeletes: false
        ) { root in
            let before = root
            let out = try await engine.mergeFromCloud(local: root, server: server)
            losses = try Self.keepLosses(before: before, merged: out, at: keepAt)
            root = out.store
            merged = out
            book = out.store
        }
        guard let report = merged else {
            throw CloudWriter.Failure.malformed("the merge produced nothing to send")
        }
        cloudPulled = report
        announceSyncLosses(losses, file: keepAt)
        await load(source)

        // MASKED, and this is the last thing before it is sealed. The desktop's
        // renderer is handed a store whose secrets are already masks; this app
        // reads the book from disk and holds the real ones, so it has to take
        // them out itself or the shop's API key, sync token and S3 secret go up
        // with everything else.
        let forCloud = try await engine.storeForCloud(book)
        let sent = try await CloudWriter.sendWholeStore(
            connection, token: token, store: forCloud, dek: dek, baseRev: baseRev,
            mergedFrom: report, memory: cloudRevisions) { request in
            try await session.data(for: request)
        }
        // The cloud now holds this book, record for record.
        await noteSyncAgreement(build: build, shopId: connection.shopId, engine: engine,
                                book: book, cloud: book)
        return sent
    }

    private func cloudKeyset() -> JSONValue? {
        guard case .object(let cloud)? = settingsDict["cloud"] else { return nil }
        return cloud["keyset"]
    }

    // MARK: - Syncing without being asked

    /// Stop automatic sync for a restore, and wait for one already running to
    /// finish. False when it did not finish in time — the restore must not go
    /// ahead under a merge.
    func pauseSyncForRestore() async -> Bool {
        restoreInProgress = true
        cancelPendingSync()
        for _ in 0..<600 where syncInFlight || cloudBusy {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if syncInFlight || cloudBusy {
            restoreInProgress = false
            return false
        }
        return true
    }

    /// The restore is in place (or refused). Sync again, soon: a restored book
    /// is held against the cloud on the next push, and sooner is better than
    /// another device editing what was just put back.
    func resumeSyncAfterRestore() {
        restoreInProgress = false
        bookChanged()
    }

    /// Start listening for this app's own writes.
    ///
    /// Called once, from the app's entry point. Every path that changes the
    /// book lands in `StoreWriter.atomicWrite`, so this hears about all of them
    /// — including the ones written after this comment.
    func listenForOwnWrites() {
        StoreWriter.didWrite = { [weak self] url in
            guard let self, self.source.build?.storeURL == url else { return }
            self.bookChanged()
        }
    }

    /// This app just changed the book. Push it, shortly.
    func bookChanged() {
        if restoreInProgress { return }
        guard AutoSync.shouldSyncOnWrite(unlocked: cloudUnlocked,
                                         connected: Self.cloudConnected(settingsDict),
                                         canWrite: canMoveJobs) else {
            noteSync("a change was not sent — "
                   + (!Self.cloudConnected(settingsDict) ? "no cloud on this book"
                      : !cloudUnlocked ? "the cloud is locked"
                      : "another app owns this book"))
            return
        }
        if syncInFlight { syncAgainAfter = true; return }
        // A fresh edit supersedes a pending backoff and resets it — the same
        // rule `scheduleSync` applies, and for the same reason: the shop has
        // just told us the situation changed.
        syncFailures = 0
        scheduleSync(after: AutoSync.debounce)
    }

    private func scheduleSync(after delay: Duration) {
        syncTask?.cancel()
        syncStatus = .waiting
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.autoSyncNow()
        }
    }

    private func cancelPendingSync() {
        syncTask?.cancel()
        syncTask = nil
        syncAgainAfter = false
    }

    /// One automatic push.
    ///
    /// It reuses `sendToCloud()` rather than having its own opinion about how
    /// to send. That matters more than the duplication it saves: `sendToCloud`
    /// is where the whole-book fallback is made legal by merging the cloud in
    /// first, and a second, quieter path to `PUT /store` is precisely the thing
    /// `CloudWriter`'s own comment says must not exist.
    ///
    /// A 409 needs no special handling here. `sendToCloud` begins with a fresh
    /// pull, so the retry below measures against the head the cloud actually
    /// has — which is what Khayt's pull-merge-repush achieves by a longer road.
    ///
    /// ── IT PUSHES A BOOK IT IS ABOUT TO WRITE TO, AND THAT TERMINATES ─────
    ///
    /// The whole-book path merges the cloud into this book before it uploads,
    /// which is a write, which the listener hears — so a push schedules a push.
    /// It settles rather than spinning: `bookChanged` sees the sync in flight
    /// and only sets `syncAgainAfter`, and the one follow-up finds an empty
    /// outbox and returns before sending anything. A gated shop pays one extra
    /// GET a quarter of an hour later, which is the floor doing its job.
    func autoSyncNow() async {
        guard cloudDek != nil, Self.cloudConnected(settingsDict), canMoveJobs else {
            syncStatus = Self.cloudConnected(settingsDict) ? .locked : .off
            return
        }
        guard !syncInFlight, !cloudBusy else { syncAgainAfter = true; return }
        guard !restoreInProgress else { return }

        // The expensive path has a floor. Checked BEFORE the pull, so a gated
        // shop inside its floor costs nothing at all rather than a request.
        if chainIsClosed, !AutoSync.mayPushWholeBook(lastAt: lastWholeBookPush) {
            let wait = AutoSync.wholeBookFloor
                - Date().timeIntervalSince(lastWholeBookPush ?? .distantPast)
            scheduleSync(after: .seconds(Int(max(1, wait.rounded(.up)))))
            return
        }

        syncInFlight = true
        syncStatus = .syncing
        await sendToCloud(byPerson: false)
        syncInFlight = false

        // The gate's state is what the LAST send found, not what any send ever
        // found. Set on a whole-book push and never cleared, this outlived the
        // gate reopening: Khayt Cloud reported the shop's deltas open and every
        // append accepted since 25 Sep, while this Mac kept waiting out the
        // whole-book floor between syncs until it was relaunched.
        if cloudSent?.wholeStore == true {
            chainIsClosed = true
            lastWholeBookPush = Date()
        } else if cloudSent != nil {
            chainIsClosed = false
        }

        if let problem = cloudProblem {
            syncStatus = .failing(problem)
            noteSync("failed — \(problem)")
            let delay = AutoSync.retryDelay(attempt: syncFailures)
            syncFailures += 1
            scheduleSync(after: delay)
            return
        }

        syncFailures = 0
        syncStatus = .synced(Date())
        noteSync(cloudSent.map { $0.wholeStore ? "sent the whole book" : "sent \($0.count)" }
                 ?? "nothing to send")
        if syncAgainAfter {
            syncAgainAfter = false
            scheduleSync(after: AutoSync.debounce)
        }
    }

    /// The only trace this leaves, for the same reason `note` exists beside the
    /// lead-time publisher: it runs on a timer with nothing on screen, and when
    /// it silently does nothing there is otherwise no way to tell whether it
    /// never ran, declined, or was refused.
    private func noteSync(_ what: String) {
        FileHandle.standardError.write(Data("khayt: sync — \(what)\n".utf8))
    }

    /// Say where sync stands, without pushing anything.
    ///
    /// Called when the book is loaded: a shop that has not unlocked the cloud
    /// this session should read "Locked", not "Not synced automatically", and
    /// certainly not silence.
    func refreshSyncStatus() {
        // A push reloads the book when it merges, and this runs on every load.
        // Without this line a whole-book push would overwrite its own
        // "Sending…" with "Syncing automatically" halfway through.
        guard !syncInFlight else { return }
        guard Self.cloudConnected(settingsDict) else { syncStatus = .off; return }
        if cloudDek == nil { syncStatus = .locked; return }
        if case .synced = syncStatus { return }
        if case .failing = syncStatus { return }
        syncStatus = .idle
    }

    // MARK: - The shop's published delivery dates

    /// Electron's cadence, and for its reasons: once shortly after launch so a
    /// shop that has just opened the app is answering, then every six hours —
    /// comfortably inside the 24-hour default staleness window, so a storefront
    /// keeps quoting even if one publish fails.
    static let leadTimeFirst: Duration = .seconds(90)
    static let leadTimeEvery: Duration = .seconds(6 * 60 * 60)

    /// ALREADY RUNNING IS LEFT ALONE, and that is the whole point.
    ///
    /// `load` runs again every time the book changes on disk — a backup, a sync,
    /// the shop typing into a sheet — and the first version of this restarted
    /// the task each time. The task opens with a ninety-second wait, so a book
    /// touched more often than that reset the clock before it ever expired and
    /// this published NOTHING, for ever, on a machine where everything else
    /// worked. It was watched doing exactly that for two minutes with a trace
    /// attached and not one line came out.
    ///
    /// The task holds no snapshot of the shop; it reads the current state on
    /// each tick. So the right lifetime is the book's, not the load's.

    // MARK: - Putting a backup back

    /// Every backup on the shelf, newest first — empty for the sample shop.
    var restorable: [Restore.Candidate] {
        guard let build = source.build else { return [] }
        return Restore.list(in: Backups.directory(for: build))
    }

    /// Replace the book with a backup.
    ///
    /// Destructive, and the only write in this app that is. Everything that
    /// makes it safe is in `Restore`: it refuses a file that is not a Khayt
    /// store, refuses a damaged one, copies the book before replacing it, and
    /// carries forward the credentials and the completion history a backup
    /// cannot contain. What is left here is saying which of those happened.
    func restore(_ candidate: Restore.Candidate) async {
        guard permitted("destructive", "create") else { return }
        spendProblem = nil
        spendNote = nil
        guard let build = source.build else {
            spendProblem = words.callIt("mac.move_sample"); return
        }
        guard await pauseSyncForRestore() else {
            spendProblem = words.callIt("mac.restore_wait_sync"); return
        }
        defer { resumeSyncAfterRestore() }
        do {
            try await Restore.restore(candidate.filename, for: build, engine: engine)
            lastBackup = Backups.lastBackupDay(in: Backups.directory(for: build))
            spendNote = words.callIt("mac.restored") + " " + candidate.filename
            await load(source)
        } catch {
            spendProblem = words.callIt("mac.restore_failed") + " " + self.said(error)
        }
    }
}
