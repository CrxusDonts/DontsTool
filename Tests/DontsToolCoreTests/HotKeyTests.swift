import Testing
@testable import DontsToolCore

@Suite("HotKey")
struct HotKeyTests {
    @Test func carbonModifiersUseCarbonMasks() {
        #expect(SettingsStore.HotKeyConfiguration.carbonModifiers(
            command: false, shift: false, option: true, control: false
        ) == 2048)
        #expect(SettingsStore.HotKeyConfiguration.carbonModifiers(
            command: true, shift: true, option: false, control: false
        ) == 768)
        #expect(SettingsStore.HotKeyConfiguration.carbonModifiers(
            command: true, shift: true, option: true, control: true
        ) == 6912)
        #expect(SettingsStore.HotKeyConfiguration.carbonModifiers(
            command: false, shift: false, option: false, control: false
        ) == 0)
    }

    @Test func displayStringUsesReadableSeparators() {
        #expect(HotKeyFormatter.displayString(for: .optionSpace) == "⌥ Space")
        #expect(HotKeyFormatter.displayString(
            for: .init(keyCode: 40, modifiers: 256 | 512)
        ) == "⇧⌘K")
        #expect(HotKeyFormatter.displayString(
            for: .init(keyCode: 122, modifiers: 2048)
        ) == "⌥F1")
    }

    @Test func doubleTapConfigurationFormatsAndResolvesModifier() {
        let configuration = SettingsStore.HotKeyConfiguration.doubleTap(.option)
        #expect(configuration.kind == .doubleTap)
        #expect(configuration.doubleTapModifier == .option)
        #expect(HotKeyFormatter.displayString(for: configuration) == "⌥⌥")
    }
}
