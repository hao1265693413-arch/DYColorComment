# DYColorComment —— 抖音评论「黄字」探针

TrollFools / TrollStore 注入用的 .dylib，**不依赖 CydiaSubstrate、不需要越狱**。
本版是**探针**：不改任何请求，只把抖音评论发送时用到的数据结构记录下来，用来定位「伪造彩色评论」的落点。

## 为什么先做探针

抖音评论的彩色不是客户端能随便设的，它由评论数据里的富文本区间决定（`text_extra` 里的 `start` / `end` / `type`）。
安卓上流传的「@好友 → 全选 → 直接打字覆盖」之所以能变黄，就是因为那段文字被套上了 @ 的黄色区间。iOS 输入框在替换选中文字时会丢掉属性，所以这个方法在 iPhone 上无效（多个教程也写明只有安卓有效）。
要在 iPhone 上做出来，只能拦截评论提交的数据、把整段文字塞进一条 @ 区间里。但 iOS 抖音的请求格式未知（可能是 TTNet + protobuf，也可能是 form-urlencoded），猜着写必是废包，所以先探一次。

## 装法

1. TrollFools → 选择「抖音」→ 添加 dylib → 选 `DYColorComment.dylib` → 注入
2. 打开抖音，右上角会出现一个黄色小圆点「黄」

## 要做的操作（很重要，只做一次）

1. 随便打开一个视频，进评论区
2. 正常打一条评论，内容里带这段标记：`ZQ7X9K黄字测试`
3. 点发送，等评论出现在列表里
4. 再点一下黄色小圆点 → 弹出「已复制日志」→ 把剪贴板内容整段发给我

（圆点可以用手指拖走，不挡视线）

## 会记录什么

- 抖音版本、iOS 版本
- 所有类名/方法名里带 `comment` / `textinput` / `textedit` / `mention` 的类，以及它们的发送类方法
- 评论提交时经过 `NSJSONSerialization` 或 `-[NSMutableURLRequest setHTTPBody:]` 的、含 `text_extra` / `comment` 的 payload 原文
- 评论输入框 `attributedText` 的属性名和值（看 @ 用的是什么 attribute）

日志同时写到 App 容器 `Documents/dycolor.log`。

## 风险

下一步的正式版需要伪造 mention 区间。理论上服务端信任客户端给的 `text_extra`（不然安卓那招不可能生效），但存在被风控识别、评论被吞/限流的可能。测试请用小号。