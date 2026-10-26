import Foundation

@main
struct TestChargeCore {
    static func main() {
        let fixture = """
        Charging status:
          Allow charging: ✘ (refreshes can take up to 2 minutes)
          Use power adapter: ✔
        Battery configuration:
          Upper limit: 80%
          Lower limit: 78%
        Hardware compatibility:
          Power adapter control: ✘
        """
        let result = BattStatus.parse(fixture)
        precondition(result.upperLimit == 80)
        precondition(result.adapterEnabled == true)
        precondition(result.supportsAdapterControl == false)
        precondition(result.scheduledRestoreLimit == nil)
        precondition(BattStatus.parse("Upper limit: 100%\n").upperLimit == 100)
        let disabled = BattStatus.parse("""
        Battery configuration:
          Charge limit: 100% (batt disabled)
          Restoring 80% limit: in 9h 55m (2026-10-26 23:00:00)
        """)
        precondition(disabled.upperLimit == 100)
        precondition(disabled.scheduledRestoreLimit == 80)
        let forever = BattStatus.parse("Charge limit: 100% (batt disabled)")
        precondition(forever.upperLimit == 100)
        precondition(forever.scheduledRestoreLimit == nil)
        precondition(BattStatus.parse("error").upperLimit == nil)
        precondition(FullBehavior(rawValue: "once") == .once)
        precondition(ChargeMode(rawValue: "limited") == .limited)
        precondition(BattCommand.allowFullTemporarily.arguments == ["disable", "--for=10h"])
        precondition(BattCommand.allowFullForever.arguments == ["disable"])
        precondition(BattCommand.setLimit(80).arguments == ["limit", "80"])
        precondition(BattCommand.readStatus.arguments == ["status"])
        // Actual AppleSmartBattery text observed while discharging: the
        // unsigned 64-bit value encodes -797 mA at 12447 mV.
        let discharge = #"""
          "InstantAmperage" = 18446744073709550819
          "Amperage" = 18446744073709550819
          "Voltage" = 12447
        """#
        guard let watts = BatteryPower.watts(from: discharge), abs(watts - 9.920259) < 0.000001 else {
            fputs("FAIL: unsigned negative discharge current must produce 9.920259 W\n", stderr)
            exit(1)
        }
        let powerSamples: [(String, Double?)] = [
            ("\"Voltage\" = 12447\n\"InstantAmperage\" = -797", 9.920259),
            ("\"Voltage\" = 12000\n\"InstantAmperage\" = 1500", 18),
            ("\"Voltage\" = 12000\n\"Amperage\" = 18446744073709550616", 12),
            ("\"Voltage\" = 12000\n\"InstantAmperage\" = -500\n\"Amperage\" = -1000", 6),
            ("\"Voltage\" = 12000\n\"InstantAmperage\" = unavailable\n\"Amperage\" = -1000", 12),
            ("\"Voltage\" = 12000", nil),
            ("\"Amperage\" = -1000", nil),
            ("\"Voltage\" = 0\n\"Amperage\" = -1000", nil),
            ("\"Voltage\" = -12000\n\"Amperage\" = -1000", nil),
            ("\"Voltage\" = 12000\n\"InstantAmperage\" = 0", 0),
            ("\"BatteryData\" = {\"Voltage\"=1000}\n\"Voltage\" = 12000\n\"Amperage\" = -1000", 12),
            ("\"Voltage\" = 12000\n\"Amperage\" = 18446744073709551616", nil),
            ("\"Voltage\" = 12000\n\"Amperage\" = 18446744073709551615", 0.012)
        ]
        for (sample, expected) in powerSamples {
            let actual = BatteryPower.watts(from: sample)
            if let expected {
                precondition(actual.map { abs($0 - expected) < 0.000001 } == true)
            } else {
                precondition(actual == nil)
            }
        }
        print("ChargeModeCoreTests: PASS (\(17 + powerSamples.count) assertions)")
    }
}
