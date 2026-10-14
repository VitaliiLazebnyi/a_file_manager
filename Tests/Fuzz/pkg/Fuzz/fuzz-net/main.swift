import FuzzCore

// Network parsers: what a server (or a saved file) sends is parsed the way the sessions do it.

fuzzMain([
    FTPListFuzz.target(), FTPReplyFuzz.target(), AddressFuzz.target(), SavedFuzz.target(), SFTPDecodeFuzz.target(),
    SFTPSessionFuzz.target()
])
