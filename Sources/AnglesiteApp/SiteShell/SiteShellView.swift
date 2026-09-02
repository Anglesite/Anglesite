import AppKit
import SwiftUI

/// Bridges SwiftUI chrome state into `SiteShellSplitController` (#1699 slice 1). Column
/// contents are re-pushed as `rootView`s on every update so the hosted columns stay live;
/// visibility bindings converge through `SiteShellState`'s rules, whose no-op answers on
/// KVO echoes are what keeps the bridge from oscillating. The coordinator re-captures the
/// bindings each update so collapse callbacks never write through a stale binding.
struct SiteShellView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var sidebarVisible: Bool
    @Binding var inspectorPresented: Bool
    let sidebar: Sidebar
    let content: Content
    let inspector: Inspector

    init(
        sidebarVisible: Binding<Bool>,
        inspectorPresented: Binding<Bool>,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content,
        @ViewBuilder inspector: () -> Inspector
    ) {
        _sidebarVisible = sidebarVisible
        _inspectorPresented = inspectorPresented
        self.sidebar = sidebar()
        self.content = content()
        self.inspector = inspector()
    }

    @MainActor
    final class Coordinator {
        var sidebarBinding: Binding<Bool>
        var inspectorBinding: Binding<Bool>
        init(sidebar: Binding<Bool>, inspector: Binding<Bool>) {
            sidebarBinding = sidebar
            inspectorBinding = inspector
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebar: $sidebarVisible, inspector: $inspectorPresented)
    }

    func makeNSViewController(context: Context) -> SiteShellSplitController<Sidebar, Content, Inspector> {
        let controller = SiteShellSplitController(
            sidebar: sidebar, content: content, inspector: inspector)
        controller.setSidebarCollapsed(!sidebarVisible, animated: false)
        controller.setInspectorCollapsed(!inspectorPresented, animated: false)
        let coordinator = context.coordinator
        controller.onSidebarCollapseChange = { collapsed in
            if let visible = SiteShellState.visibilityWriteBack(
                isCollapsed: collapsed,
                bindingVisible: coordinator.sidebarBinding.wrappedValue) {
                coordinator.sidebarBinding.wrappedValue = visible
            }
        }
        controller.onInspectorCollapseChange = { collapsed in
            if let visible = SiteShellState.visibilityWriteBack(
                isCollapsed: collapsed,
                bindingVisible: coordinator.inspectorBinding.wrappedValue) {
                coordinator.inspectorBinding.wrappedValue = visible
            }
        }
        return controller
    }

    func updateNSViewController(
        _ controller: SiteShellSplitController<Sidebar, Content, Inspector>, context: Context
    ) {
        context.coordinator.sidebarBinding = $sidebarVisible
        context.coordinator.inspectorBinding = $inspectorPresented
        controller.update(sidebar: sidebar, content: content, inspector: inspector)
        if let target = SiteShellState.collapseMutation(
            visible: sidebarVisible, isCollapsed: controller.sidebarItem.isCollapsed) {
            controller.setSidebarCollapsed(target, animated: true)
        }
        if let target = SiteShellState.collapseMutation(
            visible: inspectorPresented, isCollapsed: controller.inspectorItem.isCollapsed) {
            controller.setInspectorCollapsed(target, animated: true)
        }
    }
}
