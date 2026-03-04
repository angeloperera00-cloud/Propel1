//
//  PropelWalkShortcuts.swift
//  PropelWalk
//

#if canImport(PlaygroundSupport)
import PlaygroundSupport


import AppIntents

// Swift Playgrounds workaround:
// Playgrounds often fails on AppShortcut phrases/macros.
// So: in Playgrounds we return an EMPTY ARRAY without using the builder.
// In Xcode we keep the full shortcuts.




struct PropelWalkShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }
    
    //  NO @AppShortcutsBuilder here (empty builder crashes / “missing return”)
    static var appShortcuts: [AppShortcut] { [] }
}




struct PropelWalkShortcuts: AppShortcutsProvider {
    
    static var shortcutTileColor: ShortcutTileColor { .blue }
    
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        
        AppShortcut(
            intent: ScanSpaceIntent(),
            phrases: [
                AppShortcutPhrase("Scan Space in ${applicationName}"),
                AppShortcutPhrase("Start Scan Space in ${applicationName}")
            ],
            shortTitle: "Scan Space",
            systemImageName: "viewfinder"
        )
        
        AppShortcut(
            intent: ReadLabelIntent(),
            phrases: [
                AppShortcutPhrase("Read Label in ${applicationName}"),
                AppShortcutPhrase("Start Read Label in ${applicationName}")
            ],
            shortTitle: "Read Label",
            systemImageName: "text.viewfinder"
        )
        
        AppShortcut(
            intent: OpenTutorialIntent(),
            phrases: [
                AppShortcutPhrase("Open Tutorial in ${applicationName}"),
                AppShortcutPhrase("Show Tutorial in ${applicationName}")
            ],
            shortTitle: "Tutorial",
            systemImageName: "questionmark.circle"
        )
        
        AppShortcut(
            intent: OpenSettingsIntent(),
            phrases: [
                AppShortcutPhrase("Open Settings in ${applicationName}"),
                AppShortcutPhrase("Show Settings in ${applicationName}")
            ],
            shortTitle: "Settings",
            systemImageName: "gearshape"
        )
        
        AppShortcut(
            intent: OpenShortcutsIntent(),
            phrases: [
                AppShortcutPhrase("Open Shortcuts in ${applicationName}"),
                AppShortcutPhrase("Show Shortcuts in ${applicationName}")
            ],
            shortTitle: "Shortcuts",
            systemImageName: "wave.3.right"
        )
    }
}


#endif
