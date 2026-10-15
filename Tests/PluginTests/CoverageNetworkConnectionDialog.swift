import AFMContracts
import AFMKernel
import Foundation
import TestSupport
import Testing

@testable import NetworkPlugin

/// The list of saved connections and the dialog of a connection's details, with the answers
/// that send the user back or change nothing.
@MainActor
@Suite
internal struct CoverageNetworkConnectionDialog {
    private let fixture: CoverageNetworkBench

    private var scripted: ScriptedInteraction { fixture.scripted }

    /// A fresh bench.
    internal init() throws {
        fixture = try CoverageNetworkBench()
    }

    /// The details of a connection on the test server.
    private func details(_ name: String) -> [String: FormValues.Value] {
        ["name": .text(name), "host": .text(fixture.address), "anonymous": .flag(true)]
    }

    /// Without saved connections, Connect, Duplicate and Delete have nothing to work on.
    @Test
    internal func anEmptyListHasNothingToConnectCopyOrDelete() {
        scripted.formAnswers = [.values([:], button: 0), .values([:], button: 3), .values([:], button: 5), .cancel]
        fixture.commands.perform(.ftpConnect)
        #expect(scripted.log.filter { $0 == "form: Connect to FTP server" }.count == 4)
        #expect(scripted.log.allSatisfy { $0 == "form: Connect to FTP server" })
    }

    /// New URL in the list is a quick connection.
    @Test
    internal func newURLInTheListIsAQuickConnection() {
        scripted.formAnswers = [
            .values([:], button: 2),
            .values(["address": .text("ftp://\(fixture.address)/pub"), "anonymous": .flag(true)])
        ]
        fixture.commands.perform(.ftpConnect)
        #expect(fixture.left.model.directory == fixture.url("/pub"))
    }

    /// A cancelled detail dialog saves nothing; a deletion the user does not confirm deletes nothing.
    @Test
    internal func cancelledDialogsChangeNothing() {
        scripted.formAnswers = [
            .values([:], button: 1), .cancel, .values([:], button: 1), .values(details("Kept")), .cancel
        ]
        fixture.commands.perform(.ftpConnect)
        #expect(fixture.plugin.connections.map(\.name) == ["Kept"])
        scripted.formAnswers = [.values(["connection": .index(0)], button: 5), .cancel]
        scripted.choiceAnswers = [1]
        fixture.commands.perform(.ftpConnect)
        #expect(fixture.plugin.connections.map(\.name) == ["Kept"])
    }

    /// A host that is none and a name that is taken send the user back to the dialog; an empty
    /// name becomes the host's.
    @Test
    internal func badHostsAndTakenNamesSendTheUserBack() {
        var unnamed = details("")
        unnamed["kind"] = .index(99)
        unnamed["encoding"] = .index(99)
        unnamed["listing"] = .index(99)
        scripted.formAnswers = [
            .values([:], button: 1), .values(details("First")),
            .values([:], button: 1), .values(["name": .text("x"), "host": .text("bad host")]),
            .values(details("first")),
            .values(unnamed), .cancel
        ]
        fixture.commands.perform(.ftpConnect)
        #expect(scripted.log.contains("inform: bad host is not a host name."))
        #expect(scripted.log.contains("inform: A connection named first already exists."))
        let names = fixture.plugin.connections.map(\.name)
        #expect(names == ["First", "127.0.0.1"])
        let unnamedOne = fixture.plugin.connections.last
        #expect(unnamedOne?.kind == .ftp && unnamedOne?.encoding == .automatic && unnamedOne?.listing == .automatic)
    }

    /// A password typed for a connection whose user changed replaces the one stored before.
    @Test
    internal func aPasswordTypedForAChangedUserReplacesTheOldOne() throws {
        var first = details("Work")
        first["anonymous"] = .flag(false)
        first["user"] = .text("anna")
        first["password"] = .text("old")
        scripted.formAnswers = [.values([:], button: 1), .values(first), .cancel]
        fixture.commands.perform(.ftpConnect)
        fixture.plugin.waitForStoredSecrets()
        let before = try #require(fixture.plugin.connections.first)
        scripted.formAnswers = [
            .values(["connection": .index(0)], button: 4),
            .values(["user": .text("bert"), "password": .text("new"), "anonymous": .flag(false)]), .cancel
        ]
        fixture.commands.perform(.ftpConnect)
        fixture.plugin.waitForStoredSecrets()
        let after = try #require(fixture.plugin.connections.first)
        #expect(after.user == "bert")
        #expect(fixture.passwords.password(for: PasswordVault.account(of: after)) == "new")
        #expect(fixture.passwords.password(for: PasswordVault.account(of: before)) == nil)
    }
}
