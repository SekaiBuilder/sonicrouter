import CoreAudio
import Darwin
import Foundation
import SonicRouterCore

// Measures the realtime render path with synthetic buffers: nanoseconds per
// 256-frame block (5.33 ms of audio at 48 kHz). No audio hardware involved.
// Run with `swift run -c release SonicRouterBench`.

let frames = 256
let blocks = 200_000
let rounds = 5

final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    init(layout: [Int], fill: Bool) {
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var state: UInt32 = 7
        for (index, channels) in layout.enumerated() {
            let count = channels * frames
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            for i in 0..<count {
                state = state &* 1_664_525 &+ 1_013_904_223
                pointer[i] = fill ? Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.8 : 0
            }
            list[index] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(count * 4), mData: pointer)
            storage.append(pointer)
        }
    }
}

struct Case {
    let name: String
    let gain: Float
    let makeup: Float
    let equalizer: AudioEqualizerSettings
    let outputLayout: [Int]
    let deviceChannels: [Int]
}

let cases = [
    Case(name: "estéreo, ganancia 1, EQ plano", gain: 1, makeup: 1, equalizer: .flat, outputLayout: [2], deviceChannels: [2]),
    Case(name: "estéreo, ganancia 0,5, EQ plano", gain: 0.5, makeup: 1, equalizer: .flat, outputLayout: [2], deviceChannels: [2]),
    Case(name: "dos salidas [2,2], ganancia 0,5", gain: 0.5, makeup: 1, equalizer: .flat, outputLayout: [2, 2], deviceChannels: [2, 2]),
    Case(name: "estéreo, ganancia 0,5, EQ activo", gain: 0.5, makeup: 1, equalizer: AudioEqualizerSettings(bass: 6, mid: -3, treble: 3), outputLayout: [2], deviceChannels: [2]),
    Case(name: "estéreo, compensación ×2 (limitador)", gain: 1, makeup: 2, equalizer: .flat, outputLayout: [2], deviceChannels: [2]),
]

let input = Buffers(layout: [2], fill: true)
print("SonicRouterBench: \(frames) tramas por bloque, \(blocks) bloques, mediana de \(rounds) rondas")
for item in cases {
    let output = Buffers(layout: item.outputLayout, fill: false)
    var results: [Double] = []
    for _ in 0..<rounds {
        let renderer = BenchRenderer(item)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blocks { renderer.render(input.list, output.list) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        results.append(Double(elapsed) / Double(blocks))
    }
    results.sort()
    print(String(format: "  %-40@ %8.1f ns/bloque", item.name as NSString, results[rounds / 2]))
}
