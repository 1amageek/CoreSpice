import CoreSpiceIR

/// Canonical numeric admission shared by independent voltage/current sources.
enum IndependentSourceWaveformParser {
    static func real(_ key: String, instance: Instance, defaultValue: Double? = nil) throws -> Double {
        guard let parameter = instance.parameters[key] else {
            if let defaultValue { return defaultValue }
            throw DeviceBindingError.missingParameter(device: instance.name, parameter: key)
        }
        guard case .real(let value) = parameter else {
            throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: key, expected: "real")
        }
        guard value.isFinite else {
            throw invalid(instance, key, "Value must be finite")
        }
        return value
    }

    static func parse(_ instance: Instance, current: Bool) throws -> Waveform {
        let dc = current ? "i" : "v"
        let first = current ? "i1" : "v1"
        let second = current ? "i2" : "v2"
        let offset = current ? "io" : "vo"
        let amplitude = current ? "ia" : "va"
        let pulseKeys = [first, second, "tr", "tf", "pw", "per"]
        let sineKeys = [offset, amplitude, "freq", "phase"]
        let known = Set([dc, "ac", "td", "pwl"] + pulseKeys + sineKeys)
        for key in instance.parameters.keys where !known.contains(key) {
            throw invalid(instance, key, "Unsupported independent source parameter")
        }
        let pulse = pulseKeys.contains { instance.parameters[$0] != nil }
        let sine = sineKeys.contains { instance.parameters[$0] != nil }
        let pwl = instance.parameters["pwl"] != nil
        let families = [pulse, sine, pwl].filter { $0 }.count
        guard families <= 1, !(families > 0 && instance.parameters[dc] != nil) else {
            throw invalid(instance, "waveform", "Source waveform families must be exclusive")
        }
        _ = try real("ac", instance: instance, defaultValue: 0)
        if pwl {
            guard case .realVector(let values) = instance.parameters["pwl"] else {
                throw DeviceBindingError.invalidParameterType(device: instance.name, parameter: "pwl", expected: "realVector")
            }
            guard values.count >= 4, values.count.isMultiple(of: 2) else {
                throw invalid(instance, "pwl", "PWL requires at least two time/value pairs")
            }
            guard instance.parameters["td"] == nil else {
                throw invalid(instance, "td", "PWL time values include their explicit delay")
            }
            var points: [PWLPoint] = []
            points.reserveCapacity(values.count / 2)
            for index in stride(from: 0, to: values.count, by: 2) {
                let time = values[index]
                let value = values[index + 1]
                guard time.isFinite, time >= 0, value.isFinite else {
                    throw invalid(instance, "pwl", "PWL times must be finite/nonnegative and values finite")
                }
                if let previous = points.last {
                    guard time > previous.time, ((value - previous.value) / (time - previous.time)).isFinite else {
                        throw invalid(instance, "pwl", "PWL times must increase strictly with finite segment slopes")
                    }
                }
                points.append(PWLPoint(time: time, value: value))
            }
            return .pwl(points: points)
        }
        if pulse {
            let v1 = try real(first, instance: instance)
            let v2 = try real(second, instance: instance)
            let delay = try real("td", instance: instance, defaultValue: 0)
            let rise = try real("tr", instance: instance, defaultValue: 0)
            let fall = try real("tf", instance: instance, defaultValue: 0)
            let width = try real("pw", instance: instance, defaultValue: 0)
            let period = try real("per", instance: instance)
            guard delay >= 0, rise >= 0, fall >= 0, width >= 0, period > 0,
                  (rise + width + fall).isFinite, rise + width + fall <= period,
                  (v2 - v1).isFinite else {
                throw invalid(instance, "pulse", "Pulse timing/values must have a finite valid domain")
            }
            return .pulse(v1: v1, v2: v2, delay: delay, rise: rise, fall: fall, width: width, period: period)
        }
        if sine {
            let vo = try real(offset, instance: instance)
            let va = try real(amplitude, instance: instance)
            let frequency = try real("freq", instance: instance)
            let delay = try real("td", instance: instance, defaultValue: 0)
            let phase = try real("phase", instance: instance, defaultValue: 0)
            guard frequency > 0, delay >= 0, (frequency * 2 * .pi).isFinite,
                  (phase * .pi / 180).isFinite, (vo + abs(va)).isFinite, (vo - abs(va)).isFinite else {
                throw invalid(instance, "sine", "Sine parameters must have a finite valid domain")
            }
            return .sine(offset: vo, amplitude: va, frequency: frequency, delay: delay, phase: phase)
        }
        guard instance.parameters["td"] == nil else {
            throw invalid(instance, "td", "Delay requires a pulse or sine waveform")
        }
        return .dc(try real(dc, instance: instance, defaultValue: 0))
    }

    private static func invalid(_ instance: Instance, _ key: String, _ message: String) -> DeviceBindingError {
        .invalidParameterValue(device: instance.name, parameter: key, message: message)
    }
}
