// aerialize.swift — make any video playable as a macOS Aerial wallpaper (custom entry in an idleassetsd slot).
//
//   swiftc -O aerialize.swift -o aerialize
//   ./aerialize encode <in> <out.mov> [--seconds N] [--mbps 30] [--fps 239.76] [--size 3840x2160] [--fit crop|stretch] [--software]
//   ./aerialize verify <file.mov>     [--fps 239.76] [--size 3840x2160]
//   ./aerialize thumb  <in> <out.jpg>
//
// Why: WallpaperVideoExtension (WallpaperVideoCore.VideoSampleReader) needs, on every sample, the HEVC temporal-layer
// attachment (HEVCTemporalLevelInfo) and Apple's timing (1000 ticks per frame, first PTS 0). Without them the player
// fails on lock->unlock (VideoSampleReadingErrors.noTemporalInfo, code 4). See docs/HOW-IT-WORKS.md.
import AVFoundation; import VideoToolbox; import CoreMedia; import CoreVideo; import CoreGraphics; import ImageIO; import Foundation

let TICKS: Int64 = 1000                       // Apple's files use 1000 ticks per frame (239.76 fps -> timescale 239760)
func timescale(_ fps: Double) -> Int32 { Int32((fps * 1000).rounded()) }
func die(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }
func opt(_ name: String, _ a: [String]) -> String? { if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }; return nil }
func parseSize(_ s: String?) -> (Int, Int) {
    guard let s = s else { return (3840, 2160) }
    let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
    guard p.count == 2, p[0] > 0, p[1] > 0 else { die("--size must look like 3840x2160") }
    return (p[0], p[1])
}

// MARK: verify
func verify(_ path: String, fps: Double, size: (Int, Int)) -> Bool {
    let a = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = a.tracks(withMediaType: .video).first else { print("FAIL no video track"); return false }
    guard let r = try? AVAssetReader(asset: a) else { print("FAIL cannot read"); return false }
    let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); r.add(o); r.startReading()
    var n = 0, first = Double.nan, last = 0.0, missing = 0, levels = [Int: Int]()
    while let s = o.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(s) > 0 else { continue }          // skip parameter-set-only buffers
        n += 1
        let p = CMSampleBufferGetPresentationTimeStamp(s).seconds
        first = first.isNaN ? p : min(first, p); last = max(last, p)
        if let at = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]],
           let li = at.first?["HEVCTemporalLevelInfo" as CFString] as? [String: Any], let l = li["TemporalLevel"] as? Int { levels[l, default: 0] += 1 } else { missing += 1 }
    }
    let fmt = t.formatDescriptions.first as! CMFormatDescription
    let ext = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
    var ok = true
    func check(_ c: Bool, _ m: String) { print((c ? "  ok   " : "  FAIL ") + m); if !c { ok = false } }
    print("\(path)\n  frames=\(n) duration=\(a.duration.seconds)s first PTS=\(first) size=\(t.naturalSize) fps=\(t.nominalFrameRate) timescale=\(t.naturalTimeScale)\n  temporal levels: \(levels.sorted { $0.key < $1.key }.map { "L\($0.key)=\($0.value)" }.joined(separator: " "))")
    check(CMFormatDescriptionGetMediaSubType(fmt) == kCMVideoCodecType_HEVC, "codec is HEVC")
    check((ext["BitsPerComponent"] as? Int ?? 0) == 10, "10-bit (Main10)")
    check(abs(Double(t.nominalFrameRate) - fps) < 0.05, "\(fps) fps")
    check(t.naturalTimeScale == timescale(fps), "timescale \(timescale(fps))")
    check(first == 0, "first PTS is 0")
    check(missing == 0 && levels.count >= 2, "every sample has HEVCTemporalLevelInfo (>=2 layers)")
    check(Int(t.naturalSize.width) == size.0 && Int(t.naturalSize.height) == size.1, "\(size.0)x\(size.1)")
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
func encode(_ inp: String, _ outp: String, limit: Double, mbps: Int, fps: Double, size: (Int, Int), fit: String, software: Bool) {
    let TS = timescale(fps)
    let asset = AVURLAsset(url: URL(fileURLWithPath: inp))
    guard asset.isReadable, let track = asset.tracks(withMediaType: .video).first else {
        die("AVFoundation cannot read a video track from \(inp). Convert it first, e.g. `ffmpeg -i in.mkv -c:v libx265 -tag:v hvc1 out.mov` (or any H.264/HEVC .mp4/.mov).") }
    let sw = Int(track.naturalSize.width), sh = Int(track.naturalSize.height)
    if let f = track.formatDescriptions.first, let ext = CMFormatDescriptionGetExtensions(f as! CMFormatDescription) as? [String: Any],
       let tf = ext["CVImageBufferTransferFunction"] as? String, tf.contains("2084") || tf.contains("HLG") {
        print("WARNING: the source is HDR (\(tf)). The output is tagged SDR and there is no tone mapping, so colours will look washed out. Convert to SDR first.") }
    let pixFmt: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
    try? FileManager.default.removeItem(atPath: outp)
    let reader = try! AVAssetReader(asset: asset)
    let rout: AVAssetReaderOutput
    if sw == size.0 && sh == size.1 {
        rout = AVAssetReaderTrackOutput(track: track, outputSettings: pixFmt)
    } else {                       // scale through a video composition (the only supported way for reader outputs)
        print("note: scaling \(sw)x\(sh) -> \(size.0)x\(size.1) (\(fit))")
        if track.preferredTransform != .identity { print("WARNING: the source has a rotation/flip transform, which is ignored here.") }
        let W = Double(size.0), H = Double(size.1), fw = Double(sw), fh = Double(sh)
        let sx = fit == "stretch" ? W / fw : max(W / fw, H / fh), sy = fit == "stretch" ? H / fh : sx
        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: size.0, height: size.1)
        let md = track.minFrameDuration
        comp.frameDuration = (md.isValid && md.seconds > 0) ? md : CMTime(value: 1, timescale: Int32(max(1, track.nominalFrameRate.rounded())))
        let ins = AVMutableVideoCompositionInstruction(); ins.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        li.setTransform(CGAffineTransform(scaleX: sx, y: sy).concatenating(CGAffineTransform(translationX: (W - fw * sx) / 2, y: (H - fh * sy) / 2)), at: .zero)
        ins.layerInstructions = [li]; comp.instructions = [ins]
        let vo = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: pixFmt)
        vo.videoComposition = comp; rout = vo
    }
    reader.add(rout); reader.startReading()

    var sess: VTCompressionSession?
    let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: !software] as CFDictionary
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(size.0), height: Int32(size.1), codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &sess) == 0, let s = sess else {
        die("cannot create an HEVC encoder at \(size.0)x\(size.1)\(software ? "" : " — retry with --software")") }
    func set(_ k: CFString, _ v: Any) { let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef); if r != 0 { print("note: encoder property \(k) not accepted (\(r))") } }
    set(kVTCompressionPropertyKey_RealTime, false)
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
    set(kVTCompressionPropertyKey_AllowFrameReordering, true)
    set(kVTCompressionPropertyKey_AverageBitRate, mbps * 1_000_000)
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0)
    set("NumberOfTemporalLayers" as CFString, 5)          // undocumented; yields HEVCTemporalLevelInfo on every sample. Apple Silicon HW gives 3 layers.
    set("BaseLayerFrameRate" as CFString, max(1.0, fps / 16.0))
    set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)      // Apple's Aerial tagging
    set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
    set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    VTCompressionSessionPrepareToEncodeFrames(s)

    var writer: AVAssetWriter!, winput: AVAssetWriterInput!
    var written = 0, failed = false, levels = Set<Int>()
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
        if let at = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let li = at.first?["HEVCTemporalLevelInfo" as CFString] as? [String: Any], let l = li["TemporalLevel"] as? Int { levels.insert(l) }
        if written % 4000 == 0 { print("encoded \(written) frames"); fflush(stdout) }
    }
    func pull(_ t0: inout Double) -> (CVPixelBuffer, Double)? {
        guard let sb = rout.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds; if t0.isNaN { t0 = p }; return (pb, p - t0)
    }
    var t0 = Double.nan
    var cur = pull(&t0), nxt = pull(&t0)
    var n: Int64 = 0
    // Resample to `fps` by time: output frame n shows the latest source frame with PTS <= n/fps (duration is preserved).
    while cur != nil, !failed {
        let t = Double(n) / fps
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
    print("wrote \(written) frames -> \(outp) (temporal layers: \(levels.count))")
    if levels.count < 2 { die("this encoder did not produce temporal layers, so the file will not survive lock/unlock. Try --software, or a different Mac/macOS.") }
}

let a = CommandLine.arguments
guard a.count >= 3 else { die("usage: aerialize encode <in> <out.mov> [--seconds N] [--mbps 30] [--fps 239.76] [--size 3840x2160] [--fit crop|stretch] [--software] | verify <file> [--fps F] [--size WxH] | thumb <in> <out.jpg>") }
let fpsArg = Double(opt("--fps", a) ?? "") ?? 239.76
switch a[1] {
case "encode": guard a.count >= 4 else { die("encode needs <in> <out>") }
    encode(a[2], a[3], limit: Double(opt("--seconds", a) ?? "") ?? 1e9, mbps: Int(opt("--mbps", a) ?? "") ?? 30, fps: fpsArg,
           size: parseSize(opt("--size", a)), fit: opt("--fit", a) ?? "crop", software: a.contains("--software"))
case "verify": exit(verify(a[2], fps: fpsArg, size: parseSize(opt("--size", a))) ? 0 : 2)
case "thumb": guard a.count >= 4 else { die("thumb needs <in> <out.jpg>") }; thumb(a[2], a[3])
default: die("unknown command \(a[1])")
}
