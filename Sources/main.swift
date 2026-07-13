import Foundation
import SwiftUI

// 双模式入口：
// 1) 正常 GUI
// 2) --root-helper：root 守护，处理 route 命令（仅首次启动需管理员密码）
if RootHelper.isHelperMode {
    RootHelper.run()
} else {
    ProcessRouteApp.main()
}
