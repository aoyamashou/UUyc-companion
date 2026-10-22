import Foundation
@main struct ConnectionTests {
 static func main() {
  let t = Date(timeIntervalSince1970: 100)

  // 1) 连入需要持续确认 1.5s：覆盖窗口在本工具改显示拓扑时会短暂重建，
  //    只看到一次就判连入会和断开防抖形成自激振荡。
  var s = UUConnectionState()
  precondition(s.update(overlay: false, controllers: [], now: t) == nil)
  precondition(s.update(overlay: false, controllers: ["OPPO Find N2"], now: t) == nil,
               "首次出现不应立刻连入")
  precondition(s.update(overlay: false, controllers: ["OPPO Find N2"], now: t.addingTimeInterval(1.0)) == nil,
               "未满 1.5s 不应连入")
  precondition(s.update(overlay: false, controllers: ["OPPO Find N2"], now: t.addingTimeInterval(1.5)) == .connected)

  // 2) 已连入后控制端名称变化
  precondition(s.update(overlay: false, controllers: ["iPhone 17"], now: t.addingTimeInterval(2)) == .controllerChanged)

  // 3) 覆盖窗口短暂消失（<1.5s）不算断开
  precondition(s.update(overlay: false, controllers: [], now: t.addingTimeInterval(2.5)) == nil)
  precondition(s.update(overlay: false, controllers: ["iPhone 17"], now: t.addingTimeInterval(3.0)) == nil)

  // 4) 持续缺席 >1.5s 才算断开
  precondition(s.update(overlay: false, controllers: [], now: t.addingTimeInterval(4.0)) == nil)
  precondition(s.update(overlay: false, controllers: [], now: t.addingTimeInterval(4.6)) == .disconnected)

  // 5) 仅覆盖窗口的兜底路径（权限缺失/主窗口关闭）
  var fallback = UUConnectionState()
  precondition(fallback.update(overlay: true, controllers: nil, now: t) == nil)
  precondition(fallback.update(overlay: true, controllers: nil, now: t.addingTimeInterval(1.5)) == .connected)
  precondition(fallback.update(overlay: false, controllers: nil, now: t.addingTimeInterval(2.0)) == nil)
  precondition(fallback.update(overlay: false, controllers: nil, now: t.addingTimeInterval(3.6)) == .disconnected)

  // 6) 明确无人控制的表格不应单独触发
  var idle = UUConnectionState()
  for i in 0..<1000 {
   precondition(idle.update(overlay: false, controllers: [], now: t.addingTimeInterval(Double(i))) == nil)
  }

  // 7) 回归：自激振荡场景。覆盖窗口每次只出现 1 秒就消失 2 秒（本工具改拓扑时的真实形态），
  //    旧实现每次都会 连入→断开 各一次，导致反复建屏、每次生成一个 ICC profile。
  var flapping = UUConnectionState()
  var events = 0
  var now = t
  for _ in 0..<10 {
   if flapping.update(overlay: true, controllers: ["HUAWEI Pura X Max"], now: now) != nil { events += 1 }
   now = now.addingTimeInterval(1.0)
   if flapping.update(overlay: false, controllers: [], now: now) != nil { events += 1 }
   now = now.addingTimeInterval(2.0)
   if flapping.update(overlay: false, controllers: [], now: now) != nil { events += 1 }
  }
  precondition(events == 0, "抖动不应产生任何连入/断开事件")

  print("PASS: connect confirm, controller change, overlay fallback, disconnect debounce, idle, anti-flapping")
 }
}
