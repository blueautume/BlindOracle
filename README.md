# 盲眼先知 · BlindOracle

一个以水墨宣纸为视觉语言的原生 SwiftUI iOS 应用。只有「对话」「数据」两个标签。十种方法在设备本地执行，DeepSeek 负责选择适用插件、提出资料与交互需求、整合中文解读和回答追问。

当前版本：**0.1.1（Build 2）**。

## 打开与运行

1. 用 Xcode 27.1 打开 `BlindOracle.xcodeproj`，选择 `BlindOracle` scheme。
2. 选择 iOS 17 或更高版本的模拟器运行。真机需在 Signing & Capabilities 选择自己的开发团队；bundle identifier 为 `com.lihao.BlindOracle`，可自行修改。
3. 将 `Configuration/Secrets.example.json` 复制为 `Configuration/Secrets.local.json`，填写 `deepseek_api_key`。本地密钥文件已被 Git 忽略，仓库只保留空白模板。Debug 构建读取文件，启动时同步到设备钥匙串；修改后重新编译即可更新。Release 不复制开发凭据。原工程上一级 `key` 目录仍保留兼容读取。
4. 也可以在「数据 → 设置」填写自己的密钥。联网部分仅调用 `https://api.deepseek.com`。默认模型为 DeepSeek Pro（`deepseek-v4-pro`），开启 thinking，推理强度为 `max`；可在设置修改模型。旧版 Flash 默认值首次升级为 Pro，之后用户主动选定的模型会保留。

没有 XcodeGen、CocoaPods 或 npm 安装步骤。全部运行依赖已随源码或资源提供；`iztro` 在构建前已打成 JavaScriptCore 可执行的本地 bundle，应用运行时不带 Node/Python。

首次克隆后可运行 `git config core.hooksPath .githooks` 启用提交检查；也可手动执行 `python3 Scripts/check_secrets.py --staged`。检查读取暂存区，阻止密钥文件或凭据值被提交，错误信息只显示文件名。构建产物、Python 缓存及图标探索的重复 ZIP 导出包不纳入 Git。

## 使用流程

在对话里问一个具体问题 → AI 选择适用插件及交互 → 确认「问事笺」中已有和未知的资料 → 在统一交互会话里完成抽牌、报数或六爻起卦 → 本地逐项计算 → 流式生成约四百字中文解读。仅选择塔罗且没有资料要求时直接进入抽牌；无需交互时在确认问事笺后直接计算；需要交互时，全部完成后才把本地结果送给 DeepSeek。解读出现明显分歧时只提供两个选项；选择只会小幅改变个人解读偏好，不代表方法被证实或预测准确率。

塔罗作为独立本地方法，使用完整 78 张牌、正逆位与固定牌阵。牌名和牌义保留英文，DeepSeek 依据本次实际抽牌结果生成中文解读。抽牌和六爻结果连同输入快照保存在本机；继续未完成的交互、重新打开历史或再次请求解读不会重新抽取。

DeepSeek 请求统一提供 65,536 token 输出预算，包含推理与最终回答；请求超时为 300 秒，资源总超时为 900 秒。聊天仅显示最终回答，模型返回的 `reasoning_content` 不解码、不保存、不展示。

「数据」独立保存每种方法的盘面、规则线索、限制、版本与计算耗时。基础资料单独保存，修改资料不会改写旧记录的输入快照。为他人问事会使用独立资料，不会自动套用本人的生辰。定位只补当前所在地，不自动填写出生地。

处理进度默认折叠，只显示当前步骤；展开后可查看这次任务的完整步骤、执行状态与耗时，包括准备计划、逐项本地计算、综合解读和输出整理。步骤由实际开始与完成事件推进，不展示模型的隐藏推理。聊天记录在独立区域内滚动，底部输入区使用不透明背景。

对话左上角的两横按钮打开历史侧栏，点击任意会话可以继续之前的对话，长按可删除该聊天；基础资料和独立推演记录仍保留。旧版本保存的对话归档会自动导入历史。先知回复下方的「翻看数据」直接打开该条回复所对应的各方法原始结果，无需在全部推演记录中查找。

## 计算范围

| 插件 | 已实现 | 当前边界 |
|---|---|---|
| 八字 | 四柱、十神、藏干、纳音、五行计数、起运与大运 | 不把五行计数等同于旺衰、格局或喜用神；未知时辰/交节日保留候选 |
| 紫微 | 本地 iztro 2.6.3，十二宫、星曜、四化、大限、流年 | 需要已知生辰时区；未知时辰不安唯一命盘 |
| 六爻 | 铜钱/蓍草概率、可复现爻值、变卦、八宫、纳甲、世应、六亲六神、本地卦辞爻辞 | 基础纳甲盘；未实现完整伏神、取用与应期，标为部分结果 |
| 梅花 | 时间/报数、本互变卦、动爻、体用生克、本地卦辞爻辞 | 固定已声明取法，不覆盖所有外应/字占 |
| 奇门 | 按实际交节的时家拆补转盘、九宫天地干、九星八门八神 | 固定排法与已实现盘面；未实现完整格局断语，标为部分结果 |
| 小六壬 | 农历月日时六宫推算、逐步记录 | 固定六宫取法 |
| 称骨 | 本地年/月/日/时骨重、总重及历史评诗 | 固定资料版本；不是精密命理预测 |
| 姓名 | 本地63,696字康熙部首笔画、五格/三才、繁体候选、现代笔画备选表 | 简体转换有一对多歧义；变字形时标为部分结果；未全量古籍校勘，缺字拒绝猜测 |
| 占星 | 本地 Astronomy Engine C，星位、主要相位、行运、上升点与等宫制 | 1900–2100；等宫制，不宣称 Placidus；高纬度或未知资料时不伪造宫位 |
| 塔罗 | 本地 78 张牌、正逆位、固定牌阵、英文牌义和可复查抽牌输入 | 随机抽牌用于象征性解读，不代表观测到现实信息；AI 不补抽或改牌 |

详见 `Documentation/Plugins/`。中国历法对非东八区的交节/月历边界尚未逐地校准，插件会给出限制。算法测试验证代码与声明的取法，不验证术数预测现实的有效性。

## 工程结构

```text
App/             SwiftUI 入口、对话状态机
Core/            模型、插件协议、注册表、本地持久化、偏好学习
Plugins/Native/  八个原生方法插件
Plugins/Sky/     紫微及占星插件
Services/        DeepSeek SSE、钥匙串、定位、宽松上下文压缩
Views/           两个标签、问事笺、统一交互、档案、原始数据和设置
Resources/       本地数据、JS bundle、许可证、图标与水墨头像
Vendor/          固定版本的 MIT 历法与天文 C 源码
Tests/           算法、交互与旧档案兼容、流式解析、档案/权重及可选真实 API 集成
UITests/         两标签与完整本地问事流程
```

新增文件后运行 `python3 Scripts/generate_project.py` 更新工程；脚本不依赖第三方库。新增插件的方式见架构文档。

## 测试

```sh
xcodebuild -project BlindOracle.xcodeproj -scheme BlindOracle \
  -destination 'platform=iOS Simulator,name=BlindOracle QA' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -parallel-testing-enabled NO test
```

进度 UI 测试使用 Debug 专用的 `--ui-testing-progress` 自动阶段夹具或 `--ui-testing-progress-paused` 固定阶段夹具，直接驱动与真实任务相同的步骤模型，无需联网即可验证折叠、完整步骤、阶段切换和底部输入区布局。

普通测试不发 API 请求。真实 API 测试需显式启用，使用合成档案，不使用个人资料：

```sh
BLINDORACLE_LIVE_SMOKE=1 python3 Scripts/generate_project.py
xcodebuild -project BlindOracle.xcodeproj -scheme BlindOracle \
  -destination 'platform=iOS Simulator,name=BlindOracle QA' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -only-testing:BlindOracleTests/LiveIntegrationTests test
python3 Scripts/generate_project.py
```

开发凭据在 Debug `.app` 内仅用于本机调试；不要分发 Debug 包。发布时使用 Release，并让用户在设置中保存自己的密钥。Release 验证应检查 App 内没有 `dev-key.txt`。

模拟器测试应保留 ad-hoc 签名，否则钥匙串可能因缺少签名身份拒绝读写；这不要求付费开发者团队。真机仍需选择自己的签名团队。

## 数据与资源

- 永久档案、推演记录、偏好和版本化会话历史独立保存。`conversation-history.json` 保存各聊天的原文、摘要、待填问事笺与当前会话 ID，旧单会话文件保留兼容快照。原子写入，启用 iOS 文件保护并排除自动云备份；无法解码的文件先复制为 recovery 备份。
- 原始聊天不删除；达到约 32k 估算 token、并积累至少 24 条新消息后，才生成延续摘要，保留最近 16 条。网络摘要失败时可以使用本地检索摘要。档案与原始推演永不参与压缩。
- 系统定位权限按需申请。内置少量常用城市坐标，其他地点可手填；没有在线地理查询依赖。
- 本地试算开关可验证本地链路，规则摘要不会冒充模型回答。AI 解读请求失败时保留选择与结果，重试不会重新抽牌或投掷。
- 头像和图标由内置 imagegen 生成，最终文件保存在 Assets.xcassets；提示词记录见 `Documentation/asset-prompt.txt`。其余纸纹与视觉效果用 SwiftUI 原生绘制。

第三方许可证和上游版本随资源保存；未使用未确认许可的 tt-qimen 源码或 Python meihua 应用代码。应用自己的发布许可由项目所有者决定。
