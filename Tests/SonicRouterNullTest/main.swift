// SonicRouterNullTest — CAM-001 T4 (acceptance A03, A04, A05).
//
// Measures whether SonicRouter re-emits an app's audio unaltered:
//   1. Starts a child process (this same binary, `emit`) that writes
//      deterministic noise straight to the default output device.
//   2. Waits until SonicRouter controls it (the user sets it to 99 % in the app).
//   3. Captures, in one private aggregate and the same IOProc, a tap on the
//      emitter (reference) and a tap of everything else on the device
//      (the re-emission), so both share one clock.
//   4. Aligns them and reports the residual in dBFS per channel, the channel
//      map, and the device's nominal sample rate before, during and after.
//
// Needs the system-audio-capture permission for the app that runs it
// (Terminal). `--selftest` checks the analysis with synthetic data and needs
// neither hardware nor permission.

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Arguments

struct Options {
    var seconds = 5.0
    var waitSeconds = 120.0
    var gainHint: Float?
    var captureSonicRouterOnly = false
}

func usage() -> Never {
    print("""
    Uso: SonicRouterNullTest [--seconds N] [--wait N] [--gain G] [--capture device|process]
         SonicRouterNullTest --selftest

      --seconds N   segundos de captura (5)
      --wait N      segundos esperando a que SonicRouter controle la app de prueba (120)
      --gain G      ganancia esperada exacta en Float, p. ej. 0.99 (si no, se mide)
      --capture     device: todo lo que llega al dispositivo menos la app de prueba (por defecto)
                    process: solo el proceso de SonicRouter
    """)
    exit(2)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        func value() -> String { iterator.next() ?? { usage() }() }
        switch argument {
        case "--seconds": options.seconds = Double(value()) ?? { usage() }()
        case "--wait": options.waitSeconds = Double(value()) ?? { usage() }()
        case "--gain": options.gainHint = Float(value()) ?? { usage() }()
        case "--capture":
            switch value() {
            case "device": options.captureSonicRouterOnly = false
            case "process": options.captureSonicRouterOnly = true
            default: usage()
            }
        default: usage()
        }
    }
    return options
}

// MARK: - Core Audio helpers

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T: BitwiseCopyable>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
    var propertyAddress = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var propertyAddress = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func getObjectList(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
                   _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var propertyAddress = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func defaultOutputDevice() -> AudioObjectID? {
    getValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
}

func nominalRate(_ device: AudioObjectID) -> Double? {
    getValue(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
}

func processObject(pid: pid_t) -> AudioObjectID? {
    var propertyAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pidValue = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(systemObject, &propertyAddress,
                                            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID)
    return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
}

func isRunningOutput(_ process: AudioObjectID) -> Bool {
    (getValue(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
}

/// SonicRouter's HAL process object while it is rendering output.
func sonicRouterProcess() -> AudioObjectID? {
    getObjectList(systemObject, kAudioHardwarePropertyProcessObjectList).first { process in
        getString(process, kAudioProcessPropertyBundleID) == "local.sonicrouter.app" && isRunningOutput(process)
    }
}

func outputChannelCount(_ device: AudioObjectID) -> Int {
    var propertyAddress = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &propertyAddress, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &propertyAddress, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.first.map { Int($0.mNumberChannels) } ?? 0 // stream 0, the one the taps read
}

func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
    getValue(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
}

func check(_ status: OSStatus, _ what: String) {
    guard status != noErr else { return }
    print("Error \(status) en \(what).")
    exit(3)
}

// MARK: - Emitter (child process)

final class EmitterState: @unchecked Sendable {
    var generators: [NoiseGenerator] = (0..<64).map { NoiseGenerator(channel: $0) }
}

func runEmitter() -> Never {
    guard let device = defaultOutputDevice() else { exit(4) }
    let state = EmitterState()
    var procID: AudioDeviceIOProcID?
    let queue = DispatchQueue(label: "nulltest.emit", qos: .userInteractive)
    check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, _, _, output, _ in
        var channel = 0
        for buffer in UnsafeMutableAudioBufferListPointer(output) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * max(1, channels))
            for frame in 0..<frames {
                for c in 0..<channels where channel + c < state.generators.count {
                    data[frame * channels + c] = state.generators[channel + c].next()
                }
            }
            channel += channels
        }
    }, "crear el IOProc de la app de prueba")
    check(AudioDeviceStart(device, procID), "arrancar la app de prueba")
    signal(SIGTERM) { _ in exit(0) }
    while true { sleep(60) }
}

// MARK: - Capture (two taps, one aggregate, one IOProc)

final class Capture: @unchecked Sendable {
    let channels: [Int]          // per tap
    let interleaved: [Bool]      // per tap
    let capacity: Int
    let warmupFrames: Int
    var storage: [[UnsafeMutablePointer<Float>]]
    var seen = 0
    var written = 0
    var rateChangesWhileCapturing = 0

    init(channels: [Int], interleaved: [Bool], capacity: Int, warmupFrames: Int) {
        self.channels = channels
        self.interleaved = interleaved
        self.capacity = capacity
        self.warmupFrames = warmupFrames
        storage = channels.map { count in
            (0..<count).map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                pointer.initialize(repeating: 0, count: capacity)
                return pointer
            }
        }
    }

    var buffersPerTap: [Int] { zip(channels, interleaved).map { $1 ? 1 : $0 } }

    func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let needed = buffersPerTap.reduce(0, +)
        guard list.count >= needed else { return }
        var index = list.count - needed // taps come after any device input streams
        guard list[index].mData != nil else { return }
        let frames = Int(list[index].mDataByteSize) / (MemoryLayout<Float>.size * Int(max(1, list[index].mNumberChannels)))
        let skip = max(0, min(frames, warmupFrames - seen))
        seen += frames
        let count = min(frames - skip, capacity - written)
        guard count > 0 else { return }
        for tap in channels.indices {
            for b in 0..<buffersPerTap[tap] {
                let buffer = list[index + b]
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(buffer.mNumberChannels)
                for c in 0..<stride {
                    let channel = interleaved[tap] ? c : b
                    guard channel < channels[tap] else { continue }
                    let destination = storage[tap][channel] + written
                    for f in 0..<count { destination[f] = data[(skip + f) * stride + c] }
                }
            }
            index += buffersPerTap[tap]
        }
        written += count
    }

    func arrays(tap: Int) -> [[Float]] {
        storage[tap].map { Array(UnsafeBufferPointer(start: $0, count: written)) }
    }
}

func makeTap(_ description: CATapDescription, name: String) -> (AudioObjectID, String) {
    description.name = name
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateProcessTap(description, &tap), "crear el tap «\(name)» (¿permiso de captura de audio?)")
    let uid = getString(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString
    return (tap, uid)
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "emit" { runEmitter() }
if arguments.first == "--selftest" {
    let failures = NullTestSelfTest.run()
    print(failures == 0 ? "Autoprueba: todo pasa." : "Autoprueba: \(failures) fallos.")
    exit(failures == 0 ? 0 : 1)
}
let options = parseOptions(arguments)

guard let device = defaultOutputDevice(), let deviceUID = getString(device, kAudioDevicePropertyDeviceUID) else {
    print("No hay salida predeterminada."); exit(4)
}
let deviceName = getString(device, kAudioObjectPropertyName) ?? deviceUID
let rateBefore = nominalRate(device) ?? 0
print("Dispositivo: \(deviceName), \(outputChannelCount(device)) canales en el flujo 0, \(rateBefore) Hz.")

final class Counter: @unchecked Sendable { var value = 0 }
let rateChanges = Counter()
var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
let rateQueue = DispatchQueue(label: "nulltest.rate")
let rateListener: AudioObjectPropertyListenerBlock = { _, _ in rateQueue.async { rateChanges.value += 1 } }
AudioObjectAddPropertyListenerBlock(device, &rateAddress, rateQueue, rateListener)

let emitter = Process()
emitter.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
emitter.arguments = ["emit"]
do { try emitter.run() } catch { print("No se pudo lanzar la app de prueba: \(error)"); exit(4) }
defer { if emitter.isRunning { emitter.terminate() } }
let emitterPID = emitter.processIdentifier

func finish(_ code: Int32) -> Never {
    if emitter.isRunning { emitter.terminate(); emitter.waitUntilExit() }
    exit(code)
}

print("""
La app de prueba suena (ruido a −12 dBFS, PID \(emitterPID)). Baja el volumen del Mac si molesta.
En SonicRouter, pon «SonicRouterNullTest» al 99 % (o al valor que quieras medir).
Silencia las demás apps. Esperando hasta \(Int(options.waitSeconds)) s…
""")

var emitterObject: AudioObjectID?
var routerObject: AudioObjectID?
let deadline = Date().addingTimeInterval(options.waitSeconds)
while Date() < deadline {
    emitterObject = emitterObject ?? processObject(pid: emitterPID)
    routerObject = sonicRouterProcess()
    if emitterObject != nil, routerObject != nil { break }
    Thread.sleep(forTimeInterval: 0.5)
}
guard let emitterObject, let routerObject else {
    print("SonicRouter no está re-emitiendo la app de prueba (no se ve su salida). ¿Está al 99 %?")
    finish(5)
}
print("SonicRouter re-emite. Captura de \(options.seconds) s tras 1 s de margen…")
Thread.sleep(forTimeInterval: 1)

let (referenceTap, referenceUID) = makeTap(
    CATapDescription(processes: [emitterObject], deviceUID: deviceUID, stream: 0), name: "NullTest reference")
let capturedDescription = options.captureSonicRouterOnly
    ? CATapDescription(processes: [routerObject], deviceUID: deviceUID, stream: 0)
    : CATapDescription(excludingProcesses: [emitterObject], deviceUID: deviceUID, stream: 0)
let (capturedTap, capturedUID) = makeTap(capturedDescription, name: "NullTest re-emission")

let formats = [tapFormat(referenceTap), tapFormat(capturedTap)]
for (name, format) in zip(["referencia", "re-emisión"], formats) {
    guard let format, format.mFormatID == kAudioFormatLinearPCM,
          format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
        print("Formato de tap de \(name) no admitido: \(String(describing: format))"); finish(6)
    }
}
let tapChannels = formats.map { Int($0!.mChannelsPerFrame) }
let tapInterleaved = formats.map { $0!.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 }
let captureRate = formats[0]!.mSampleRate
print("Taps: \(tapChannels[0]) y \(tapChannels[1]) canales, \(captureRate) Hz.")

let aggregateUID = "local.sonicrouter.nulltest.\(UUID().uuidString)"
let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "SonicRouter NullTest",
    kAudioAggregateDeviceUIDKey: aggregateUID,
    kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceIsStackedKey: 0,
    kAudioAggregateDeviceTapAutoStartKey: 1,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: referenceUID], [kAudioSubTapUIDKey: capturedUID]]
]
var aggregate = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "crear el agregado")

let capture = Capture(
    channels: tapChannels,
    interleaved: tapInterleaved,
    capacity: Int(captureRate * options.seconds),
    warmupFrames: Int(captureRate * 0.5)
)
var captureProc: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&captureProc, aggregate, DispatchQueue(label: "nulltest.capture")) { _, input, _, _, _ in
    capture.process(input)
}, "crear el IOProc de captura")
check(AudioDeviceStart(aggregate, captureProc), "arrancar la captura")
let captureDeadline = Date().addingTimeInterval(options.seconds + 3)
while capture.written < capture.capacity, Date() < captureDeadline { Thread.sleep(forTimeInterval: 0.1) }
let rateDuring = nominalRate(device) ?? 0
AudioDeviceStop(aggregate, captureProc)
AudioDeviceDestroyIOProcID(aggregate, captureProc!)
AudioHardwareDestroyAggregateDevice(aggregate)
AudioHardwareDestroyProcessTap(capturedTap)
AudioHardwareDestroyProcessTap(referenceTap)

emitter.terminate()
emitter.waitUntilExit()
print("App de prueba cerrada; esperando 3 s a que SonicRouter suelte el motor…")
Thread.sleep(forTimeInterval: 3)
let rateAfter = nominalRate(device) ?? 0
let totalRateChanges = rateQueue.sync { rateChanges.value }

// MARK: - Report

let report = NullTestAnalysis.analyze(
    reference: capture.arrays(tap: 0),
    captured: capture.arrays(tap: 1),
    gainHint: options.gainHint
)
print("")
print(String(format: "Capturado: %d tramas (%.2f s). Referencia: %.1f dBFS RMS.",
             capture.written, Double(capture.written) / captureRate, report.referenceRMSDBFS))
for channel in report.channels {
    print(String(
        format: "Canal %d ← %d  retardo %d  ganancia %.9g  exactas %d/%d  residuo pico %.1f dBFS, RMS %.1f dBFS  clics %d%@",
        channel.channel + 1, channel.sourceChannel + 1, channel.lag, Double(channel.gain),
        channel.exactFrames, channel.comparedFrames, channel.peakResidualDBFS, channel.rmsResidualDBFS,
        channel.glitchFrames, channel.firstGlitchFrame.map { " (primero en \($0))" } ?? ""
    ))
}
var problems = report.problems
print("Frecuencia nominal: antes \(rateBefore), durante \(rateDuring), después \(rateAfter); cambios: \(totalRateChanges).")
if rateBefore != rateDuring || rateBefore != rateAfter || totalRateChanges > 0 {
    problems.append("La frecuencia del dispositivo cambió (A05).")
}
print("")
if problems.isEmpty && report.passed {
    print("RESULTADO: PASA (A03\(tapChannels[0] > 2 ? ", A04" : "") y A05).")
    finish(0)
}
print("RESULTADO: FALLA")
problems.forEach { print("  - \($0)") }
finish(1)
