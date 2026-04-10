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
        case diaWatchPeripheralID = "com.loopkit.Loop.DiaWatch.peripheralID"
        case diaWatchDeviceName = "com.loopkit.Loop.DiaWatch.deviceName"
        case diaWatchHapticSlots = "com.loopkit.Loop.DiaWatch.hapticSlots"
        case diaWatchHapOnReading = "com.loopkit.Loop.DiaWatch.hapOnReading"
        case diaWatchWakeOnReading = "com.loopkit.Loop.DiaWatch.wakeOnReading"
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
    
    var diaWatchPeripheralID: UUID? {
        get {
            guard let str = string(forKey: Key.diaWatchPeripheralID.rawValue) else { return nil }
            return UUID(uuidString: str)
        }
        set { set(newValue?.uuidString, forKey: Key.diaWatchPeripheralID.rawValue) }
    }

    var diaWatchDeviceName: String? {
        get { string(forKey: Key.diaWatchDeviceName.rawValue) }
        set { set(newValue, forKey: Key.diaWatchDeviceName.rawValue) }
    }

    var diaWatchHapticSlots: [DiaWatchManager.HapticSlot] {
        get {
            guard let data = data(forKey: Key.diaWatchHapticSlots.rawValue),
                  let slots = try? JSONDecoder().decode([DiaWatchManager.HapticSlot].self, from: data)
            else { return DiaWatchManager.HapticSlot.defaults }
            return slots
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data, forKey: Key.diaWatchHapticSlots.rawValue)
        }
    }

    var diaWatchHapOnReading: Bool {
        get { bool(forKey: Key.diaWatchHapOnReading.rawValue) }
        set { set(newValue, forKey: Key.diaWatchHapOnReading.rawValue) }
    }

    var diaWatchWakeOnReading: Bool {
        get { bool(forKey: Key.diaWatchWakeOnReading.rawValue) }
        set { set(newValue, forKey: Key.diaWatchWakeOnReading.rawValue) }
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
