import Foundation

public struct Calculation: Equatable, Sendable {
    public let value: Double
    public let text: String
    public let isConversion: Bool

    public init(value: Double, text: String, isConversion: Bool) {
        self.value = value
        self.text = text
        self.isConversion = isConversion
    }
}

public enum CalculatorEngine {
    public static func calculate(_ raw: String) -> Calculation? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let conversion = convertUnits(trimmed) { return conversion }

        let hasExplicitPrefix = trimmed.hasPrefix("=")
        let source = hasExplicitPrefix
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        guard !source.isEmpty else { return nil }
        guard hasExplicitPrefix || looksLikeExpression(source) else { return nil }

        guard let tokens = try? tokenize(source) else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = try? parser.parse(), value.isFinite else { return nil }
        return Calculation(value: value, text: format(value), isConversion: false)
    }

    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        guard value != 0 else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        let magnitude = abs(value)
        if magnitude >= 1e12 || magnitude < 1e-6 {
            return String(format: "%.10g", value)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: 输入形态

    private static func looksLikeExpression(_ source: String) -> Bool {
        guard source.count > 1, source.contains(where: \.isNumber) else { return false }
        if source.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
            return false
        }
        return source.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%()")) != nil
    }

    // MARK: 单位换算

    private struct UnitDefinition: Sendable {
        let canonical: String
        let category: Category
        let factor: Double
    }

    private enum Category: Sendable {
        case length
        case mass
        case temperature
        case data
        case time
        case speed
    }

    private static let units: [String: UnitDefinition] = {
        var result: [String: UnitDefinition] = [:]

        func add(
            _ aliases: [String],
            canonical: String,
            category: Category,
            factor: Double
        ) {
            let definition = UnitDefinition(canonical: canonical, category: category, factor: factor)
            for alias in aliases { result[alias] = definition }
        }

        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], canonical: "mm", category: .length, factor: 0.001)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], canonical: "cm", category: .length, factor: 0.01)
        add(["m", "meter", "meters", "metre", "metres"], canonical: "m", category: .length, factor: 1)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], canonical: "km", category: .length, factor: 1000)
        add(["in", "inch", "inches"], canonical: "in", category: .length, factor: 0.0254)
        add(["ft", "foot", "feet"], canonical: "ft", category: .length, factor: 0.3048)
        add(["yd", "yard", "yards"], canonical: "yd", category: .length, factor: 0.9144)
        add(["mi", "mile", "miles"], canonical: "mi", category: .length, factor: 1609.344)

        add(["mg", "milligram", "milligrams"], canonical: "mg", category: .mass, factor: 0.000001)
        add(["g", "gram", "grams"], canonical: "g", category: .mass, factor: 0.001)
        add(["kg", "kilogram", "kilograms"], canonical: "kg", category: .mass, factor: 1)
        add(["t", "tonne", "tonnes"], canonical: "t", category: .mass, factor: 1000)
        add(["oz", "ounce", "ounces"], canonical: "oz", category: .mass, factor: 0.028349523125)
        add(["lb", "lbs", "pound", "pounds"], canonical: "lb", category: .mass, factor: 0.45359237)

        add(["c", "°c", "celsius"], canonical: "°C", category: .temperature, factor: 1)
        add(["f", "°f", "fahrenheit"], canonical: "°F", category: .temperature, factor: 1)
        add(["k", "kelvin"], canonical: "K", category: .temperature, factor: 1)

        add(["b", "byte", "bytes"], canonical: "B", category: .data, factor: 1)
        add(["kb", "kilobyte", "kilobytes"], canonical: "KB", category: .data, factor: 1024)
        add(["mb", "megabyte", "megabytes"], canonical: "MB", category: .data, factor: 1_048_576)
        add(["gb", "gigabyte", "gigabytes"], canonical: "GB", category: .data, factor: 1_073_741_824)
        add(["tb", "terabyte", "terabytes"], canonical: "TB", category: .data, factor: 1_099_511_627_776)

        add(["ms", "millisecond", "milliseconds"], canonical: "ms", category: .time, factor: 0.001)
        add(["s", "sec", "secs", "second", "seconds"], canonical: "s", category: .time, factor: 1)
        add(["min", "mins", "minute", "minutes"], canonical: "min", category: .time, factor: 60)
        add(["h", "hr", "hrs", "hour", "hours"], canonical: "h", category: .time, factor: 3600)
        add(["d", "day", "days"], canonical: "d", category: .time, factor: 86_400)
        add(["wk", "week", "weeks"], canonical: "wk", category: .time, factor: 604_800)

        add(["m/s", "mps"], canonical: "m/s", category: .speed, factor: 1)
        add(["km/h", "kmh", "kph"], canonical: "km/h", category: .speed, factor: 1000.0 / 3600.0)
        add(["mph"], canonical: "mph", category: .speed, factor: 0.44704)

        return result
    }()

    private static let conversionPattern = try! NSRegularExpression(
        pattern: #"^\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([A-Za-z°/]+(?:/[A-Za-z]+)?)\s+(?:to|in)\s+([A-Za-z°/]+(?:/[A-Za-z]+)?)\s*$"#
    )

    private static func convertUnits(_ source: String) -> Calculation? {
        let range = NSRange(source.startIndex..., in: source)
        guard let match = conversionPattern.firstMatch(in: source, range: range),
              let numberRange = Range(match.range(at: 1), in: source),
              let sourceRange = Range(match.range(at: 2), in: source),
              let targetRange = Range(match.range(at: 3), in: source),
              let value = Double(source[numberRange]) else { return nil }

        let sourceUnit = normalizedUnit(String(source[sourceRange]))
        let targetUnit = normalizedUnit(String(source[targetRange]))
        guard let sourceDefinition = units[sourceUnit],
              let targetDefinition = units[targetUnit],
              sourceDefinition.category == targetDefinition.category else { return nil }

        let converted: Double
        if sourceDefinition.category == .temperature {
            let celsius: Double
            switch sourceDefinition.canonical {
            case "°F": celsius = (value - 32) * 5 / 9
            case "K": celsius = value - 273.15
            default: celsius = value
            }
            switch targetDefinition.canonical {
            case "°F": converted = celsius * 9 / 5 + 32
            case "K": converted = celsius + 273.15
            default: converted = celsius
            }
        } else {
            converted = value * sourceDefinition.factor / targetDefinition.factor
        }
        guard converted.isFinite else { return nil }
        return Calculation(
            value: converted,
            text: "\(format(converted)) \(targetDefinition.canonical)",
            isConversion: true
        )
    }

    private static func normalizedUnit(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "º", with: "°")
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: 表达式解析

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus
        case minus
        case star
        case slash
        case percent
        case caret
        case leftParen
        case rightParen
    }

    private enum ParseFailure: Error {
        case invalid
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                index = source.index(after: index)
                continue
            }

            if character.isNumber || character == "." {
                let start = index
                var hasDigit = false
                while index < source.endIndex, source[index].isNumber {
                    hasDigit = true
                    index = source.index(after: index)
                }
                if index < source.endIndex, source[index] == "." {
                    index = source.index(after: index)
                    while index < source.endIndex, source[index].isNumber {
                        hasDigit = true
                        index = source.index(after: index)
                    }
                }
                guard hasDigit else { throw ParseFailure.invalid }
                if index < source.endIndex, source[index] == "e" || source[index] == "E" {
                    let exponentStart = index
                    var cursor = source.index(after: index)
                    if cursor < source.endIndex, source[cursor] == "+" || source[cursor] == "-" {
                        cursor = source.index(after: cursor)
                    }
                    var exponentDigits = 0
                    while cursor < source.endIndex, source[cursor].isNumber {
                        cursor = source.index(after: cursor)
                        exponentDigits += 1
                    }
                    index = exponentDigits > 0 ? cursor : exponentStart
                }
                guard let value = Double(source[start..<index]) else { throw ParseFailure.invalid }
                tokens.append(.number(value))
                continue
            }

            if character.isLetter || character == "π" {
                let start = index
                while index < source.endIndex, source[index].isLetter || source[index] == "π" {
                    index = source.index(after: index)
                }
                tokens.append(.identifier(String(source[start..<index]).lowercased()))
                continue
            }

            switch character {
            case "+": tokens.append(.plus)
            case "-": tokens.append(.minus)
            case "*": tokens.append(.star)
            case "/": tokens.append(.slash)
            case "%": tokens.append(.percent)
            case "^": tokens.append(.caret)
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            default: throw ParseFailure.invalid
            }
            index = source.index(after: index)
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var index = 0

        mutating func parse() throws -> Double {
            let value = try expression()
            guard index == tokens.count else { throw ParseFailure.invalid }
            return value
        }

        private var current: Token? {
            tokens.indices.contains(index) ? tokens[index] : nil
        }

        private mutating func expression() throws -> Double {
            var value = try term()
            while let token = current {
                switch token {
                case .plus:
                    index += 1
                    value += try term()
                case .minus:
                    index += 1
                    value -= try term()
                default:
                    return value
                }
            }
            return value
        }

        private mutating func term() throws -> Double {
            var value = try unary()
            while let token = current {
                switch token {
                case .star:
                    index += 1
                    value *= try unary()
                case .slash:
                    index += 1
                    let divisor = try unary()
                    guard divisor != 0 else { throw ParseFailure.invalid }
                    value /= divisor
                case .percent:
                    index += 1
                    let divisor = try unary()
                    guard divisor != 0 else { throw ParseFailure.invalid }
                    value = value.truncatingRemainder(dividingBy: divisor)
                default:
                    return value
                }
            }
            return value
        }

        private mutating func unary() throws -> Double {
            if current == .plus {
                index += 1
                return try unary()
            }
            if current == .minus {
                index += 1
                return -(try unary())
            }
            return try power()
        }

        private mutating func power() throws -> Double {
            let base = try primary()
            guard current == .caret else { return base }
            index += 1
            let exponent = try unary()
            let result = Foundation.pow(base, exponent)
            guard result.isFinite else { throw ParseFailure.invalid }
            return result
        }

        private mutating func primary() throws -> Double {
            guard let token = current else { throw ParseFailure.invalid }
            switch token {
            case .number(let value):
                index += 1
                return value
            case .identifier(let name):
                index += 1
                if name == "pi" || name == "π" { return .pi }
                if name == "e" { return M_E }
                guard current == .leftParen else { throw ParseFailure.invalid }
                index += 1
                let argument = try expression()
                guard current == .rightParen else { throw ParseFailure.invalid }
                index += 1
                return try apply(name, to: argument)
            case .leftParen:
                index += 1
                let value = try expression()
                guard current == .rightParen else { throw ParseFailure.invalid }
                index += 1
                return value
            default:
                throw ParseFailure.invalid
            }
        }

        private func apply(_ name: String, to argument: Double) throws -> Double {
            let result: Double
            switch name {
            case "sqrt":
                guard argument >= 0 else { throw ParseFailure.invalid }
                result = Foundation.sqrt(argument)
            case "abs":
                result = abs(argument)
            case "round":
                result = argument.rounded()
            case "floor":
                result = argument.rounded(.down)
            case "ceil":
                result = argument.rounded(.up)
            case "ln":
                guard argument > 0 else { throw ParseFailure.invalid }
                result = Foundation.log(argument)
            case "log":
                guard argument > 0 else { throw ParseFailure.invalid }
                result = Foundation.log10(argument)
            case "sin":
                result = Foundation.sin(argument)
            case "cos":
                result = Foundation.cos(argument)
            case "tan":
                result = Foundation.tan(argument)
            default:
                throw ParseFailure.invalid
            }
            guard result.isFinite else { throw ParseFailure.invalid }
            return result
        }
    }
}
