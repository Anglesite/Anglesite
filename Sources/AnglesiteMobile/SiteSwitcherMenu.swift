// Sources/AnglesiteMobile/SiteSwitcherMenu.swift
import SwiftUI
import AnglesiteIOS

/// A compact site switcher for a toolbar (#71 "multi-site UX"): shows the current site's name with
/// a chevron, and a `Menu` listing every discovered site with a checkmark on the current one.
/// `SiteSplitScreen` attaches this to both its content and detail panes so the current site stays
/// visible even when the sidebar column isn't (iPhone's collapsed `NavigationStack`).
struct SiteSwitcherMenu: View {
    let sites: [SitePickerModel.DiscoveredSite]
    let selected: SitePickerModel.DiscoveredSite?
    var onSelect: (SitePickerModel.DiscoveredSite) -> Void

    var body: some View {
        Menu {
            ForEach(sites) { site in
                Button {
                    onSelect(site)
                } label: {
                    if site == selected {
                        Label(site.displayName, systemImage: "checkmark")
                    } else {
                        Text(verbatim: site.displayName)
                    }
                }
            }
        } label: {
            Label(selected?.displayName ?? "", systemImage: "chevron.down")
                .labelStyle(.titleAndIcon)
        }
    }
}
