//
//  UserDefaults+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


extension UserDefaults {
    private enum Key: String {
        case legacyPumpManagerState = "com.loopkit.Loop.PumpManagerState"
        case legacyCGMManagerState = "com.loopkit.Loop.CGMManagerState"
        case legacyServicesState = "com.loopkit.Loop.ServicesState"
        case loopNotRunningNotifications = "com.loopkit.Loop.loopNotRunningNotifications"
        case inFlightAutomaticDose = "com.loopkit.Loop.inFlightAutomaticDose"
        case favoriteFoods = "com.loopkit.Loop.favoriteFoods"
        case glyWatchPeripheralID = "com.loopkit.Loop.GlyWatch.peripheralID"
        case glyWatchDeviceName = "com.loopkit.Loop.GlyWatch.deviceName"
        case glyWatchPresets = "com.loopkit.Loop.GlyWatch.presets"
        case glyWatchTransmissionsEnabled = "com.loopkit.Loop.GlyWatch.transmissionsEnabled"
        case glyWatchLastSentTs = "com.loopkit.Loop.GlyWatch.lastSentTs"
    }

    var legacyPumpManagerRawValue: PumpManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyPumpManagerState.rawValue)
        }
    }
    func clearLegacyPumpManagerRawValue() {
        set(nil, forKey: Key.legacyPumpManagerState.rawValue)
    }


    var legacyCGMManagerRawValue: CGMManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyCGMManagerState.rawValue)
        }
    }

    func clearLegacyCGMManagerRawValue() {
        set(nil, forKey: Key.legacyCGMManagerState.rawValue)
    }

    var legacyServicesState: [Service.RawStateValue] {
        get {
            return array(forKey: Key.legacyServicesState.rawValue) as? [[String: Any]] ?? []
        }
    }

    func clearLegacyServicesState() {
        set(nil, forKey: Key.legacyServicesState.rawValue)
    }

    var inFlightAutomaticDose: AutomaticDoseRecommendation? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.inFlightAutomaticDose.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(AutomaticDoseRecommendation.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.inFlightAutomaticDose.rawValue)
                } else {
                    set(nil, forKey: Key.inFlightAutomaticDose.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode AutomaticDoseRecommendation")
            }
        }
    }

    var loopNotRunningNotifications: [StoredLoopNotRunningNotification] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.loopNotRunningNotifications.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredLoopNotRunningNotification].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.loopNotRunningNotifications.rawValue)
            } catch {
                assertionFailure("Unable to encode Loop not running notification")
            }
        }
    }
    
    var glyWatchPeripheralID: UUID? {
        get {
            guard let str = string(forKey: Key.glyWatchPeripheralID.rawValue) else { return nil }
            return UUID(uuidString: str)
        }
        set { set(newValue?.uuidString, forKey: Key.glyWatchPeripheralID.rawValue) }
    }

    var glyWatchDeviceName: String? {
        get { string(forKey: Key.glyWatchDeviceName.rawValue) }
        set { set(newValue, forKey: Key.glyWatchDeviceName.rawValue) }
    }

    var glyWatchTransmissionsEnabled: Bool {
        get {
            // Default true if never set, matching the previous in-memory default.
            object(forKey: Key.glyWatchTransmissionsEnabled.rawValue) as? Bool ?? true
        }
        set { set(newValue, forKey: Key.glyWatchTransmissionsEnabled.rawValue) }
    }

    var glyWatchLastSentTs: Int {
        get { integer(forKey: Key.glyWatchLastSentTs.rawValue) }
        set { set(newValue, forKey: Key.glyWatchLastSentTs.rawValue) }
    }

    var glyWatchPresets: [GlyWatchManager.Preset] {
        get {
            guard let data = data(forKey: Key.glyWatchPresets.rawValue),
                  let presets = try? JSONDecoder().decode([GlyWatchManager.Preset].self, from: data)
            else { return [GlyWatchManager.Preset.defaultPreset] }
            return presets
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data, forKey: Key.glyWatchPresets.rawValue)
        }
    }

    var favoriteFoods: [StoredFavoriteFood] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.favoriteFoods.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredFavoriteFood].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.favoriteFoods.rawValue)
            } catch {
                assertionFailure("Unable to encode stored favorite foods")
            }
        }
    }
}
