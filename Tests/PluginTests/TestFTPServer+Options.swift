import Foundation

/// The settings that make the test server play a particular server.
extension TestFTPServer {
    /// How the test server behaves: which features it offers and which awkward server it plays.
    ///
    /// The defaults make a well-behaved UNIX server that lets anyone in.
    internal struct Options {
        /// FEAT lists MLST and MLSD, and both commands work.
        internal var offersMLSD = true
        /// FEAT is answered; when false it is refused with 502.
        internal var offersFeatures = true
        /// FEAT lists EPSV, and EPSV works.
        internal var offersEPSV = true
        /// FEAT lists SIZE, and SIZE works.
        internal var offersSize = true
        /// LIST sends DOS lines (`MM-dd-yy  hh:mma  <DIR> name`) instead of UNIX ones.
        internal var dosListing = false
        /// Nil: anyone may log in.
        internal var user: String?
        /// The password `user` logs in with.
        internal var password = ""
        /// A pause before every listing, to make listings overlap.
        internal var listDelay: TimeInterval = 0
        /// Lines added to the end of every listing as they are, e.g. names a server must not be believed.
        internal var injectedLines: [String] = []
        /// The first connections are answered with 421 (too many from this address) and closed.
        internal var busyGreetings = 0
        /// This command is carried out, but its reply is never sent: the connection is cut instead.
        internal var dropReplyFor: String?
        /// RETR opens the data connection and then sends nothing at all.
        internal var stallRETR = false
        /// RETR sends this many bytes and then resets the data connection.
        internal var resetRETRAfter: Int?
        /// STOR opens the data connection and then reads nothing at all.
        internal var stallSTOR = false
        /// FEAT does not list REST.
        internal var offersREST = true
        /// RNTO is refused when something has the new name, as on servers whose rename does not replace.
        internal var renameKeepsExisting = false
        /// RNTO is refused for a source whose path ends like this (`*` refuses every rename).
        internal var refusesRenameOf: String?
        /// DELE is refused.
        internal var refusesDelete = false
        /// APPE starts the file anew, as a server does that takes it for STOR.
        internal var appendStartsAnew = false
        /// Of an upload only this many bytes are kept, and the server says 226 all the same.
        internal var keepsOfUploads: Int?
        /// What a listing sends instead of the folder's lines, byte for byte.
        internal var rawListing: Data?
        /// The reply to this command never ends: lines of it are sent for as long as the client listens.
        internal var endlessReplyTo: String?
        /// The reply to this command is one line of this many bytes without a line end.
        internal var longLineReplyTo: (verb: String, bytes: Int)?
        /// A pause before the greeting.
        internal var greetingDelay: TimeInterval = 0
        /// In active mode the data connection is never opened: after the 150 comes a 425, after this long.
        internal var activeNeverConnects: TimeInterval?
        /// A transfer is announced twice (`125`, and `150` once the data is through), as some servers do.
        internal var announcesTwice = false
    }
}
