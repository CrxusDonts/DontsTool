import Foundation
import Testing
@testable import DontsToolCore

@Suite("CalculatorEngine")
struct CalculatorEngineTests {
    @Test func respectsOperatorPrecedence() {
        #expect(CalculatorEngine.calculate("2 + 3 * 4")?.text == "14")
        #expect(CalculatorEngine.calculate("(2 + 3) * 4")?.text == "20")
        #expect(CalculatorEngine.calculate("10 % 3")?.text == "1")
    }

    @Test func exponentIsRightAssociativeAndBindsTighterThanUnaryMinus() {
        #expect(CalculatorEngine.calculate("2^3^2")?.text == "512")
        #expect(CalculatorEngine.calculate("-2^2")?.text == "-4")
    }

    @Test func supportsFunctionsAndConstants() {
        #expect(CalculatorEngine.calculate("sqrt(16) + 1")?.text == "5")
        #expect(CalculatorEngine.calculate("round(2.6) + floor(2.9)")?.text == "5")
        #expect(CalculatorEngine.calculate("2 * pi")?.text == "6.2831853072")
    }

    @Test func formatsFloatingPointNoise() {
        #expect(CalculatorEngine.calculate("0.1 + 0.2")?.text == "0.3")
        #expect(CalculatorEngine.calculate("1 / 3")?.text == "0.3333333333")
    }

    @Test func rejectsInvalidOrAmbiguousInput() {
        #expect(CalculatorEngine.calculate("1 / 0") == nil)
        #expect(CalculatorEngine.calculate("Safari") == nil)
        #expect(CalculatorEngine.calculate("42") == nil)
        #expect(CalculatorEngine.calculate("2026-10-20") == nil)
        #expect(CalculatorEngine.calculate("sqrt(") == nil)
        #expect(CalculatorEngine.calculate("") == nil)
    }

    @Test func leadingEqualsAlwaysEvaluates() {
        #expect(CalculatorEngine.calculate("= 42")?.text == "42")
        #expect(CalculatorEngine.calculate("=7*8")?.text == "56")
    }

    @Test func convertsLengthAndMass() {
        let miles = CalculatorEngine.calculate("10 km to mi")
        #expect(miles?.isConversion == true)
        #expect(miles?.text.hasSuffix(" mi") == true)
        #expect(abs((miles?.value ?? 0) - 6.2137119224) < 0.000001)

        let pounds = CalculatorEngine.calculate("1 kg to lb")
        #expect(pounds?.text == "2.2046226218 lb")
    }

    @Test func convertsTemperature() {
        #expect(CalculatorEngine.calculate("100 c to f")?.text == "212 °F")
        #expect(CalculatorEngine.calculate("32 f to c")?.text == "0 °C")
        #expect(CalculatorEngine.calculate("0 c to k")?.text == "273.15 K")
    }

    @Test func convertsDataTimeAndSpeed() {
        #expect(CalculatorEngine.calculate("1 gb to mb")?.text == "1024 MB")
        #expect(CalculatorEngine.calculate("2 h to min")?.text == "120 min")
        let speed = CalculatorEngine.calculate("60 km/h to m/s")
        #expect(abs((speed?.value ?? 0) - 16.6666666667) < 0.000001)
        #expect(speed?.text.hasSuffix(" m/s") == true)
    }

    @Test func rejectsUnknownUnitOrCrossCategoryConversion() {
        #expect(CalculatorEngine.calculate("1 kg to mi") == nil)
        #expect(CalculatorEngine.calculate("1 xyz to m") == nil)
    }
}
