import AFMKernel
import Foundation

/// The questions asked by connections.
extension NetworkCommands {
    /// Asks the user on the main thread, from the thread that connects.
    ///
    /// The questions are kept by the environment, which the kernel keeps through the plugin:
    /// they must keep neither. A connection may still ask when the kernel has gone (a test
    /// that ended): weak, and the question is refused then.
    internal struct Asker: Sendable {
        /// The kernel that asks; nil once it has gone.
        internal weak let kernel: Kernel?

        /// `question` asked on the main thread; `refused` once the kernel has gone.
        ///
        /// The questions are marked `@Sendable`: they hold only values that are safe on any
        /// thread, and without the mark the compiler cannot check them.
        internal func ask<Answer: Sendable>(
            _ refused: Answer,
            _ question: @escaping @MainActor @Sendable (any UserInteraction) -> Answer
        ) -> Answer {
            kernel?.askUser(question) ?? refused
        }
    }

    /// Asks for the user name and password of the server of `profile`; nil when the user gives up.
    ///
    /// `message` is what the server answered to the last attempt, empty the first time.
    nonisolated private static func askCredentials(
        for profile: ConnectionProfile,
        message: String,
        asker: Asker
    ) -> Credentials? {
        asker.ask(nil) { @Sendable asked -> Credentials? in
            // The title names the connection, so password managers can fill the dialog in.
            var fields: [FormField] = [
                .text("user", "User name:", profile.user ?? ""), .password("password", "Password:")
            ]
            if profile.savedID != nil {
                fields.append(.checkbox("save", "Remember the password in the Keychain", true))
            }
            let detail =
                message.isEmpty
                ? "User name and password for \(profile.key.description)" : "The server answered: \(message)"
            guard let answer = asked.form(profile.title, detail: detail, fields: fields, buttons: ["OK"]),
                !answer.text("user").isEmpty
            else { return nil }
            // Stored only once the server has accepted it (`rememberPassword`).
            return Credentials(
                user: answer.text("user"),
                password: answer.text("password"),
                remember: profile.savedID != nil && answer.flag("save")
            )
        }
    }

    /// Keeps the password the server accepted for a saved connection, on the main thread later.
    ///
    /// Under the name of the connection as it is saved: a user name typed at the login fills an
    /// empty one in, and a password for another user is not stored for this one.
    nonisolated private static func remember(
        _ password: String,
        of profile: ConnectionProfile,
        in store: ConnectionStore
    ) {
        guard let id = profile.savedID, let user = profile.user else {
            return
        }
        DispatchQueue.main.async {
            guard var saved = store.connections.first(where: { $0.id == id }),
                !saved.anonymous || saved.user.isEmpty
            else { return }
            if saved.user.isEmpty {
                (saved.user, saved.anonymous) = (user, false)
                store.save(saved)
            }
            guard saved.user == user, saved.key == profile.key else {
                return
            }
            store.vault.setPassword(password, for: saved)
        }
    }

    /// Asks whether to log in to a server the user did not choose; Return is Cancel.
    nonisolated private static func askToConnect(to profile: ConnectionProfile, asker: Asker) -> Bool {
        asker.ask(false) { @Sendable asked -> Bool in
            let how =
                profile.key.scheme == "sftp"
                ? "A secure shell login as \(profile.user ?? NSUserName()) would be made, with the keys and the "
                    + "configuration of your account."
                : profile.user.map { "A login as \($0) would be made." } ?? "An anonymous login would be made."
            let detail = """
                A location on this server was opened, but you did not choose to connect to it: \
                the address may come from a tab, a list or a link.

                \(how)
                """
            // Return is Cancel: nobody asked for this connection.
            return asked.choose(
                "Connect to \(profile.key.description)?",
                detail: detail,
                buttons: ["Connect", "Cancel"],
                style: .warning,
                defaultButton: 1
            ) == 0
        }
    }

    /// Asks whether to send a password over plain FTP, unless the user agreed for good for this host.
    nonisolated private static func askToSendPasswordUnprotected(
        to profile: ConnectionProfile,
        settings: any SettingsStore,
        asker: Asker
    ) -> Bool {
        let host = profile.key.host
        if settings.value([String].self, forKey: NetworkSettings.unprotectedHosts)?.contains(host) == true {
            return true
        }
        return asker.ask(false) { @Sendable asked -> Bool in
            let detail = """
                \(profile.key.description) is a plain FTP connection. The password travels unencrypted, \
                and anyone on the way can read it, and the files.

                If the server offers it, use FTP over TLS or SFTP instead.
                """
            guard
                let answer = asked.form(
                    "Send the password unencrypted?",
                    detail: detail,
                    fields: [.checkbox("always", "Do not ask again for this server", false)],
                    buttons: ["Send Unencrypted"]
                )
            else { return false }
            if answer.flag("always") {
                let known = settings.value([String].self, forKey: NetworkSettings.unprotectedHosts) ?? []
                settings.set(
                    Array((known.filter { $0 != host } + [host]).suffix(200)),
                    forKey: NetworkSettings.unprotectedHosts
                )
            }
            return true
        }
    }

    /// Asks whether to accept a certificate the system does not trust; a yes is remembered for the
    /// session, and with the box ticked for good.
    private static func askToTrust(
        _ certificate: CertificateInfo,
        of profile: ConnectionProfile,
        asked: any UserInteraction,
        trust: CertificateTrust,
        vault: PasswordVault
    ) -> Bool {
        let detail = """
            The certificate was not signed by a trusted party!
            Continue anyway?

            Connected to: \(profile.key.host):\(profile.key.port)
            SHA-256 fingerprint: \(certificate.fingerprint)
            Cert subject: \(certificate.subject)
            \(certificate.problem)
            """
        guard
            let answer = asked.form(
                "SSL",
                detail: detail,
                fields: [.checkbox("always", "Always trust this server", false)],
                buttons: ["Yes"]
            )
        else { return false }
        trust.accept(certificate.fingerprint, for: profile.key.host)
        if answer.flag("always") {
            vault.setTrusted([certificate.fingerprint], for: profile.key.host, adding: true)
        }
        return true
    }

    /// Asks whether to accept a certificate in place of the ones accepted before (`known`, their
    /// fingerprints); true only with the box ticked that says the new fingerprint was checked.
    private static func askToTrustChanged(
        _ certificate: CertificateInfo,
        of profile: ConnectionProfile,
        known: [String],
        asked: any UserInteraction
    ) -> Bool {
        let detail = """
            WARNING: THE CERTIFICATE OF THIS SERVER HAS CHANGED.

            \(profile.key.host):\(profile.key.port) now shows a certificate that is not the one you accepted \
            for it before, and that the system does not trust either. Somebody may be \
            intercepting the connection to read your password and your files. It is also \
            possible that the server's certificate was renewed.

            Do not go on unless you have checked the new fingerprint with whoever runs the server.

            Accepted before (SHA-256):
            \(known.joined(separator: "\n"))

            Shown now (SHA-256):
            \(certificate.fingerprint)
            Cert subject: \(certificate.subject)
            \(certificate.problem)
            """
        let fields: [FormField] = [
            .checkbox(
                "verified",
                "I have checked the new fingerprint. Trust it in place of the old certificate.",
                false
            )
        ]
        // Only the ticked box is consent; the button alone, or Return, is not.
        guard
            let answer = asked.form(
                "The server's certificate has changed!",
                detail: detail,
                fields: fields,
                buttons: ["Replace the Trusted Certificate"]
            ), answer.flag("verified")
        else { return false }
        return true
    }

    /// Asks a question of the secure shell: yes or no about a host key it has not seen, else the
    /// secret it asks for; nil when the user gives up.
    nonisolated private static func askSecret(
        _ question: String,
        isSecret: Bool,
        of profile: ConnectionProfile,
        asker: Asker
    ) -> String? {
        asker.ask(nil) { @Sendable asked -> String? in
            if !isSecret {
                // The secure shell asks to confirm a host key it has not seen.
                // Return is No: a key is accepted on purpose.
                return asked.choose(
                    profile.title,
                    detail: question,
                    buttons: ["Yes", "No"],
                    style: .warning,
                    defaultButton: 1
                )
                    == 0 ? "yes" : "no"
            }
            return asked.form(profile.title, detail: question, fields: [.password("secret", "")], buttons: ["OK"])?
                .text("secret")
        }
    }

    /// Routes the questions of the connections to the user.
    ///
    /// They are asked from the thread that connects and answered on the main thread. Nothing here
    /// touches the Keychain: what is to be stored is handed to the vault, which works on a queue of
    /// its own.
    internal func connectQuestions() {
        let asker = Asker(kernel: kernel)
        let environment = center.environment
        let (settings, store, vault, trust) = (kernel.settings, store, store.vault, environment.trust)
        environment.askCredentials = { profile, message in
            Self.askCredentials(for: profile, message: message, asker: asker)
        }
        environment.rememberPassword = { profile, password in
            Self.remember(password, of: profile, in: store)
        }
        environment.askToConnect = { profile in
            Self.askToConnect(to: profile, asker: asker)
        }
        environment.askToSendPasswordUnprotected = { profile in
            Self.askToSendPasswordUnprotected(to: profile, settings: settings, asker: asker)
        }
        environment.askToTrust = { profile, certificate in
            asker.ask(false) { @Sendable asked -> Bool in
                Self.askToTrust(certificate, of: profile, asked: asked, trust: trust, vault: vault)
            }
        }
        environment.askToTrustChanged = { profile, certificate, known in
            // Whether the old certificate was accepted for good is read here, on the connecting thread.
            let wasStored = vault.hasTrusted(for: profile.key.host)
            return asker.ask(false) { @Sendable asked -> Bool in
                guard Self.askToTrustChanged(certificate, of: profile, known: known, asked: asked) else {
                    return false
                }
                // The old certificate is trusted no longer, here and where it was stored.
                trust.replace(with: certificate.fingerprint, for: profile.key.host)
                if wasStored { vault.setTrusted([certificate.fingerprint], for: profile.key.host, adding: false) }
                return true
            }
        }
        environment.askSecret = { profile, question, isSecret in
            Self.askSecret(question, isSecret: isSecret, of: profile, asker: asker)
        }
    }
}
