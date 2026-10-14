import FuzzCore

// FileTools: checksum files, the decoders (Base64/MIME, UUE, XXE, yEnc), split `.crc` files
// and the discovery of the parts to combine.

fuzzMain([
    ChecksumFuzz.target(), VerifyFuzz.target(), DecodeFuzz.memoryTarget(), DecodeFuzz.filesTarget(),
    CombineFuzz.target(), PartsFuzz.target()
])
