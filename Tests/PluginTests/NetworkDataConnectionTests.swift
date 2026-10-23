import Testing

@testable import NetworkPlugin

/// How a profile's choice of data connection meets the preference.
@Suite
internal struct NetworkDataConnectionTests {
    /// A profile that chose passive or active keeps its choice whatever the preference says.
    @Test
    internal func aChoiceOfTheProfileWinsOverThePreference() {
        #expect(ConnectionProfile.DataConnection.passive.isPassive(byDefault: false))
        #expect(!ConnectionProfile.DataConnection.active.isPassive(byDefault: true))
    }

    /// A profile that chose nothing goes by the preference.
    @Test
    internal func aProfileWithoutAChoiceFollowsThePreference() {
        #expect(ConnectionProfile.DataConnection.preferred.isPassive(byDefault: true))
        #expect(!ConnectionProfile.DataConnection.preferred.isPassive(byDefault: false))
    }

    /// A saved connection hands its passive flag to the profile it makes.
    @Test
    internal func aSavedConnectionPassesItsFlagOn() {
        var connection = SavedConnection()
        #expect(connection.profile.dataConnection == .passive)
        connection.passive = false
        #expect(connection.profile.dataConnection == .active)
        #expect(ConnectionProfile(key: connection.key).dataConnection == .preferred)
    }
}
