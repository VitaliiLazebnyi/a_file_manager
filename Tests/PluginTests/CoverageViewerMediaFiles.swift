import AVFoundation
import CoreMedia
import Foundation

/// Sound and film files made for the tests.
internal enum CoverageViewerMediaFiles {
    /// The errors of making a file.
    internal enum Failure: Error {
        /// The file could not be made.
        case notMade
    }

    private static let sampleRate = 8_000

    /// A WAV file of a quiet tone, `seconds` long.
    internal static func wav(seconds: Double) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        var data = Data()
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func half(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        word(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        word(16)
        half(1)
        half(1)
        word(UInt32(sampleRate))
        word(UInt32(sampleRate * 2))
        half(2)
        half(16)
        data.append(contentsOf: Array("data".utf8))
        word(UInt32(samples * 2))
        for index in 0..<samples {
            half(UInt16(bitPattern: Int16(sin(Double(index) / 10) * 2_000)))
        }
        return data
    }

    /// A QuickTime file of a short sound whose tags hold `title`, `artist` and a picture.
    internal static func taggedSound(at url: URL, title: String?, artist: String?) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writer.add(input)
        var items: [AVMetadataItem] = []
        for (identifier, value) in [
            (AVMetadataIdentifier.commonIdentifierTitle, title), (.commonIdentifierArtist, artist)
        ] {
            guard let value else {
                continue
            }
            items.append(item(identifier, value as AnyObject))
        }
        // A picture is no text: it is passed over.
        items.append(item(.commonIdentifierArtwork, Data([0x89, 0x50, 0x4E, 0x47]) as AnyObject))
        writer.metadata = items
        guard writer.startWriting() else {
            throw Failure.notMade
        }
        writer.startSession(atSourceTime: .zero)
        guard input.append(try silence(count: 2_400)) else {
            throw Failure.notMade
        }
        input.markAsFinished()
        try finish(writer)
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: AnyObject) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? any NSCopying & NSObjectProtocol
        return item
    }

    private static func format() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard let format else {
            throw Failure.notMade
        }
        return format
    }

    private static func silence(count: Int) throws -> CMSampleBuffer {
        let format = try format()
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: count * 2,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count * 2,
            flags: 0,
            blockBufferOut: &block
        )
        guard let block else {
            throw Failure.notMade
        }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: count,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard let sample else {
            throw Failure.notMade
        }
        return sample
    }

    private static func finish(_ writer: AVAssetWriter) throws {
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.notMade
        }
    }
}
