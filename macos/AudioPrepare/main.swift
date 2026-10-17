import Foundation
import AudioToolbox

func check(_ status: OSStatus) throws {
    if status != noErr { throw NSError(domain: "AudioPrepare", code: Int(status)) }
}
func convert(_ input: URL, _ output: URL) throws -> Double {
    var source: ExtAudioFileRef?
    try check(ExtAudioFileOpenURL(input as CFURL, &source))
    guard let source else { throw NSError(domain: "AudioPrepare", code: 1) }
    defer { ExtAudioFileDispose(source) }
    var format = AudioStreamBasicDescription(mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
        mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    try check(ExtAudioFileSetProperty(source, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: format)), &format))
    var destination: ExtAudioFileRef?
    try check(ExtAudioFileCreateWithURL(output as CFURL, kAudioFileWAVEType, &format, nil, AudioFileFlags.eraseFile.rawValue, &destination))
    guard let destination else { throw NSError(domain: "AudioPrepare", code: 2) }
    var complete = false
    defer { ExtAudioFileDispose(destination); if !complete { try? FileManager.default.removeItem(at: output) } }
    let capacity: UInt32 = 8192
    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(capacity * 2), alignment: 2)
    defer { data.deallocate() }
    var total: UInt64 = 0
    while true {
        var frames = capacity
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity * 2, mData: data))
        try check(ExtAudioFileRead(source, &frames, &list))
        if frames == 0 { break }
        total += UInt64(frames)
        if total * 2 > 24_900_000 { throw NSError(domain: "AudioPrepare", code: 3) }
        try check(ExtAudioFileWrite(destination, frames, &list))
    }
    if total == 0 { throw NSError(domain: "AudioPrepare", code: 4) }
    complete = true
    return Double(total) / 16000
}
do {
    guard CommandLine.arguments.count == 3 else { throw NSError(domain: "AudioPrepare", code: 5) }
    let duration = try convert(URL(fileURLWithPath: CommandLine.arguments[1]), URL(fileURLWithPath: CommandLine.arguments[2]))
    print("{\"duration\":\(duration)}")
} catch {
    FileHandle.standardError.write(Data("Audio conversion failed\n".utf8)); exit(1)
}
