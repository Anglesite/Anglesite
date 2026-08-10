import Foundation
import AnglesiteRemote

// Anywhere runtime (#1208 P1) helper entry point. Task 7 wires the full session loop; this
// placeholder proves the target builds and embeds correctly.
#if canImport(ServiceManagement)
let loginItem = SMAppServiceLoginItem()
try? loginItem.register()
#endif
print("anglesite-remote-helper started")
RunLoop.main.run()
