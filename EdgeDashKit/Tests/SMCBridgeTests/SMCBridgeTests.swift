import Foundation
@testable import SMCBridge
import Testing

struct SMCBridgeTests {
    @Test func fourCCEncoding() {
        #expect(SMCConnection.fourCC("FNum") == 0x464E_756D)
        #expect(SMCConnection.fourCC("F0Ac") == 0x4630_4163)
        #expect(SMCConnection.fourCC("toolong") == nil)
        #expect(SMCConnection.fourCC("ab") == nil)
    }

    @Test func floatDecoding() throws {
        // "flt " little-endian: 1500.0f
        let bits = Float(1500).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        #expect(try SMCConnection.decodeFloat(bytes: bytes, type: #require(SMCConnection.fourCC("flt "))) == 1500)
        #expect(try SMCConnection.decodeFloat(bytes: [3], type: #require(SMCConnection.fourCC("ui8 "))) == 3)
        #expect(try SMCConnection.decodeFloat(bytes: [0x0B, 0xB8], type: #require(SMCConnection.fourCC("ui16"))) == 3000)
        #expect(SMCConnection.decodeFloat(bytes: [], type: 0) == nil)
    }

    // Live smoke tests on this machine (M3 Max MacBook Pro: has sensors and fans).
    // VMs (CI runners) expose no SMC temperature sensors, so gate on that.

    private static var isVirtualMachine: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0)
        return value == 1
    }

    @Test(.enabled(if: !isVirtualMachine)) func liveTemperatureSensors() {
        let sensors = HIDTemperatureSensors.readAll()
        #expect(!sensors.isEmpty, "expected AppleVendor temperature sensors on Apple Silicon")
        // Sanity: values in plausible range already filtered; at least one > 10 °C.
        #expect(sensors.values.contains { $0 > 10 })
    }

    @Test func paramStructMatchesKernelLayout() {
        // 76 bytes (Swift's natural packing) makes AppleSMC reject every
        // call with kIOReturnBadArgument. Regression-pin the C layout.
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.keyInfoDataSize) == 28)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.bytes) == 48)
    }

    @Test func livePowerReadout() throws {
        let reader = SMCPowerReader()
        _ = try reader.read() // seed the energy-model delta
        usleep(400_000)
        let samples = try reader.read()
        if case .scalar(let watts)? = samples.first?.value {
            print("power watts = \(watts)")
            #expect(watts > 0.5 && watts < 500)
        } else {
            print("power unavailable on this machine")
        }
    }

    @Test func liveCoreClockSecondReadHasFrequencies() throws {
        let reader = CoreClockReader()
        _ = try reader.read() // seed sample
        usleep(300_000)
        let samples = try reader.read()
        // IOReport is private API — absence is acceptable, garbage is not.
        if case .composite(let values)? = samples.first?.value {
            #expect(values["pMax"] ?? 0 > 1000) // > 1 GHz top state
            #expect(values["e"] ?? -1 >= 0)
            #expect((values["p"] ?? 0) <= (values["pMax"] ?? 0) * 1.01)
        }
    }

    @Test func liveFanReadout() throws {
        let count = SMCBridge.fanCount()
        #expect(count >= 0)
        if count > 0 {
            let samples = try SMCFanReader().read()
            guard case .composite(let fans)? = samples.first?.value else {
                Issue.record("fan reader returned nothing despite FNum > 0"); return
            }
            #expect(fans.count == count)
        }
    }
}
