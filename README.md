# GPT Welcome

一个为 macOS ChatGPT 客户端制作的独立开场动画。彩色的手写流线写出 **Welcome Andrew**，回旋至 Codex 风格的轮廓，最终通过真正透明的窗口遮罩转场至正在运行的 ChatGPT 界面。

这是个人制作的非官方项目，不隶属于 OpenAI 或 Apple。

## 预览

在浏览器打开 [Resources/Welcome-Andrew.html](Resources/Welcome-Andrew.html)。它是完全离线的矢量动画预览；预览的底层界面是示意图，安装后的动画使用真实的应用窗口。

## 安装

要求 macOS 14 或更新版本、已安装 ChatGPT 桌面客户端（`com.openai.codex`）、以及用于本次编译的 Apple Command Line Tools。没有 Homebrew、Node.js、Python 包、视频播放器或其他第三方运行依赖。

Apple Silicon 的构建包也可在 [Releases](https://github.com/Andrew-max365/gpt-welcome-animation/releases) 下载。该包没有公证；如果 macOS 拦截，请采用下面的本地构建方式，**不要关闭系统安全保护**。

```sh
git clone https://github.com/Andrew-max365/gpt-welcome-animation.git
cd gpt-welcome-animation
bash Scripts/build.sh
open dist
```

将生成的 `GPT Welcome.app` 拖到“应用程序”文件夹，双击打开，选择“启用”。如果 macOS 要求批准登录项，在“系统设置 → 通用 → 登录项与扩展”中允许 GPT Welcome。用原版 ChatGPT 图标完全退出后重新打开即可看到动画。仅关闭、最小化、隐藏或重新激活已运行的窗口不会重播。

**运行时只需要 `GPT Welcome.app`。** 编译脚本会自动清理创建的编译缓存，安装后可以删除整个克隆目录。应用是本地临时签名的，不需要购买开发者证书；不要为了运行它关闭系统安全机制。

### 使用和卸载

- 双击“应用程序”中的 `GPT Welcome.app`，可打开控制面板、手动预览、停用。
- 选择“停用并退出”，注销登录项后将 `GPT Welcome.app` 移到废纸篓，即可完整移除。
- 也可通过系统设置撤销 GPT Welcome 登录项。当前已运行的程序可从活动监视器退出。

命令行状态检查（无需联网）：

```sh
"/Applications/GPT Welcome.app/Contents/MacOS/GPTWelcome" --status
```

## 实现

- Swift、AppKit、Core Graphics 与 Core Animation；用 macOS 原生窗口与显示刷新时钟实现动画。
- `NSWorkspace` 监听进程启动和激活通知；已有进程 ID 在监控启动时记为已见，普通切换窗口不触发。一次短暂的通知排序宽限期用于处理启动和前台激活先后不同的情况。
- 动画只针对目标应用的前台、可见窗口；运行期间跟随窗口位置和尺寸变化。切换应用、关闭窗口或发生异常时自动停止。
- v1.0.1：在启动过程中窗口被重建时自动重新关联新的窗口；短暂失焦或显示暂停时保留动画进度，避免提前消失或跳到结尾。仅写入少量系统管理的生命周期日志，便于诊断，不创建独立日志文件。
- v1.0.2：手写文字改为在独立、与屏幕像素对齐的位图中绘制，避免原生窗口直接描边时在笔画尖端产生细小伪影。保留原始字形、速度、渐变和粉笔纹理；尺寸仍随窗口自适应。
- 真正的透明遮罩通过 Core Graphics 的奇偶填充规则生成，不截屏，不读取聊天数据，不修改官方客户端。
- 登录项通过系统的 `SMAppService` 注册；空闲时不进行连续轮询、动画渲染或网络请求。

由于这是外部开场动画，系统窗口必须出现后才能准确贴合，无法保证所有机器、应用更新或登录恢复状态下完全没有首帧闪烁。系统公开事件也不能区分每一种启动来源；判断依据是新的进程和紧接着的前台激活，而不是全局鼠标监听。后台启动后再激活的正常场景会被跳过。

## 修改动画

手写字形为 `Resources/Welcome-Andrew.html` 中的单条贝塞尔路径，并非普通字体。可编辑 `letterGeometry` 与 `bridgeGeometry` 路径，然后重新构建。`Sources/Motion.swift` 包含原生分段时序、曲率及重叠笔迹补偿、粉笔纹理和真实转场的绘制逻辑。

构建脚本会自动运行冷启动状态机测试，也可以手动运行：

```sh
"dist/GPT Welcome.app/Contents/MacOS/GPTWelcome" --self-test
```
