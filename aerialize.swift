// aerialize.swift — make any video playable as a macOS Sequoia Aerial wallpaper (custom 4KSDR240FPS slot).
//
//   swiftc -O aerialize.swift -o aerialize
//   ./aerialize encode <in> <out.mov> [--seconds N] [--mbps 30]
//   ./aerialize verify <file.mov>
//   ./aerialize thumb  <in> <out.jpg>
//
// Why: WallpaperVideoExtension (WallpaperVideoCore.VideoSampleReader) needs, on every sample, the
// HEVC temporal-layer attachment (HEVCTemporalLevelInfo) and Apple's timing (239.76 fps, 1/239760 timebase,
// first PTS 0). Without them the player fails on lock->unlock (VideoSampleReadingErrors.noTemporalInfo, code 4).
import AVFoundation; import VideoToolbox; import CoreMedia; import CoreVideo; import CoreGraphics; import ImageIO; import Foundation

let TS: Int32 = 239760          // Apple's timescale
let TICKS: Int64 = 1000         // ticks per frame => 239.76 fps
let FPS = 239.76

func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
func opt(_ name: String, _ a: [String]) -> String? { if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }; return nil }

// MARK: verify
func verify(_ path: String) -> Bool {
    let a = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = a.tracks(withMediaType: .video).first else { print("FAIL no video track"); return false }
    guard let r = try? AVAssetReader(asset: a) else { print("FAIL cannot read"); return false }
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); r.add(o); r.startReading()
    var n = 0, first = Double.nan, last = 0.0, missing = 0, levels = [Int: Int]()
    while let s = o.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(s) > 0 else { continue }          // skip parameter-set-only buffers
        n += 1
        let p = CMSampleBufferGetPresentationTimeStamp(s).seconds
        if first.isNaN { first = p }; first = min(first, p); last = max(last, p)
        if let at = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]],
           let li = at.first?["HEVCTemporalLevelInfo" as CFString] as? [String: Any], let l = li["TemporalLevel"] as? Int { levels[l, default: 0] += 1 } else { missing += 1 }
    }
    let fmt = t.formatDescriptions.first as! CMFormatDescription
    let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
    let bits = ext["BitsPerComponent"] as? Int ?? 0
    let fpsOK = abs(t.nominalFrameRate - Float(FPS)) < 0.05
    var ok = true
    func check(_ c: Bool, _ m: String) { print((c ? "  ok   " : "  FAIL ") + m); if !c { ok = false } }
    print("\(path)\n  frames=\(n) duration=\(a.duration.seconds)s first PTS=\(first) size=\(t.naturalSize) fps=\(t.nominalFrameRate) timescale=\(t.naturalTimeScale)\n  temporal levels: \(levels.sorted { $0.key < $1.key }.map { "L\($0.key)=\($0.value)" }.joined(separator: " "))")
    check(CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC, "codec is HEVC")
    check(bits == 10, "10-bit (Main10)")
    check(fpsOK, "239.76 fps")
    check(t.naturalTimeScale == TS, "timescale 239760")
    check(first == 0, "first PTS is 0")
    check(missing == 0 && levels.count >= 2, "every sample has HEVCTemporalLevelInfo (>=2 layers)")
    check(Int(t.naturalSize.width) == 3840 && Int(t.naturalSize.height) == 2160, "3840x2160")
    print(ok ? "PASS" : "FAIL"); return ok
}

// MARK: thumb
func thumb(_ inp: String, _ out: String) {
    let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: inp)))
    g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 1920, height: 1080)
    g.requestedTimeToleranceBefore = .positiveInfinity; g.requestedTimeToleranceAfter = .positiveInfinity
    guard let img = try? g.copyCGImage(at: CMTime(seconds: 5, preferredTimescale: 600), actualTime: nil) ?? g.copyCGImage(at: .zero, actualTime: nil),
          let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.jpeg" as CFString, 1, nil) else { die("thumbnail failed") }
    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(d) else { die("thumbnail write failed") }
}

// MARK: encode
func encode(_ inp: String, _ outp: String, limit: Double, mbps: Int) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: inp))
    guard let track = asset.tracks(withMediaType: .video).first else { die("no video track in input") }
    let w = Int32(track.naturalSize.width), h = Int32(track.naturalSize.height)
    if w != 3840 || h != 2160 { print("WARNING: input is \(w)x\(h), not 3840x2160 — Aerial 4K slot expects 3840x2160") }
    try? FileManager.default.removeItem(atPath: outp)
    let reader = try! AVAssetReader(asset: asset)
    let rout = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    reader.add(rout); reader.startReading()

    var sess: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
    guard VTCompressionSessionCreate(allocator: nil, width: w, height: h, codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &sess) == 0, let s = sess else { die("cannot create HEVC encoder") }
    func set(_ k: CFString, _ v: Any) { let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef); if r != 0 { print("note: property \(k) not accepted (\(r))") } }
    set(kVTCompressionPropertyKey_RealTime, false)
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, FPS)
    set(kVTCompressionPropertyKey_AllowFrameReordering, true)
    set(kVTCompressionPropertyKey_AverageBitRate, mbps * 1_000_000)
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0)
    set("NumberOfTemporalLayers" as CFString, 5)          // hardware encoder currently yields 3 layers (60/120/240 fps); that is enough
    set("BaseLayerFrameRate" as CFString, 15.0)
    set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)      // Apple's Aerial tagging
    set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    VTCompressionSessionPrepareToEncodeFrames(s)

    var writer: AVAssetWriter!, winput: AVAssetWriterInput!
    var written = 0, failed = false
    func handle(_ sb: CMSampleBuffer) {
        if writer == nil {   // created lazily: the format description comes from the first encoded sample
            writer = try! AVAssetWriter(url: URL(fileURLWithPath: outp), fileType: .mov)
            winput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
            winput.expectsMediaDataInRealTime = false
            winput.mediaTimeScale = TS                    // otherwise the muxer rescales to 1/600 and frame timing breaks
            writer.add(winput); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        }
        while !winput.isReadyForMoreMediaData { usleep(2000) }
        if !winput.append(sb) { failed = true; print("append failed: \(String(describing: writer.error))") }
        written += 1
        if written % 4000 == 0 { print("encoded \(written) frames"); fflush(stdout) }
    }
    func pull(_ t0: inout Double) -> (CVPixelBuffer, Double)? {
        guard let sb = rout.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds; if t0.isNaN { t0 = p }; return (pb, p - t0)
    }
    var t0 = Double.nan
    var cur = pull(&t0), nxt = pull(&t0)
    var n: Int64 = 0
    // Resample to 239.76 fps by time: output frame n shows the latest source frame with PTS <= n/239.76 (duration is preserved).
    while cur != nil, !failed {
        let t = Double(n) / FPS
        if t >= limit { break }
        while let x = nxt, x.1 <= t + 1e-9 { cur = x; nxt = pull(&t0) }
        if nxt == nil && t > cur!.1 + 1.0 / 20.0 { break }       // past the end of the source
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: cur!.0, presentationTimeStamp: CMTime(value: n * TICKS, timescale: TS),
            duration: CMTime(value: TICKS, timescale: TS), frameProperties: nil, infoFlagsOut: nil) { status, _, sb in
            if let sb = sb { handle(sb) } else { print("encoder error \(status)"); failed = true } }
        if st != 0 { print("encode error \(st)"); failed = true }
        n += 1
    }
    VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
    guard writer != nil else { die("nothing was encoded") }
    winput.markAsFinished()
    let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
    if failed || writer.status != .completed { die("encode failed: \(String(describing: writer.error))") }
    print("wrote \(written) frames -> \(outp)")
}

let a = CommandLine.arguments
guard a.count >= 3 else { die("usage: aerialize encode <in> <out.mov> [--seconds N] [--mbps 30] | verify <file> | thumb <in> <out.jpg>") }
switch a[1] {
case "encode": guard a.count >= 4 else { die("encode needs <in> <out>") }
    encode(a[2], a[3], limit: Double(opt("--seconds", a) ?? "") ?? 1e9, mbps: Int(opt("--mbps", a) ?? "") ?? 30)
case "verify": exit(verify(a[2]) ? 0 : 2)
case "thumb": guard a.count >= 4 else { die("thumb needs <in> <out.jpg>") }; thumb(a[2], a[3])
default: die("unknown command \(a[1])")
}
