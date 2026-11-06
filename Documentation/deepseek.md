# AI 调度与对话

本地插件负责排盘、抽牌、起卦与确定性规则。账号网关调用服务器配置的 AI，负责选择适用插件、说明需要的资料与交互，以及整合本地结果和回答追问。产品设置不提供供应商或模型选择。

## 调用接口

- `DeepSeekClient.plan(question:profile:plugins:history:profiles:pendingPlan:existingRun:)` 返回 `OraclePlan`。已有问事以 `reply / supplement / intake` 分流：`reply` 用于已有结果足以支持的解释或普通对话；`supplement` 用于确需尚未覆盖的能力，或相关资料、人员、条件变化后的局部更新；`intake` 用于具体新问题或明确重新起卦、重新抽牌。另有 `clarify`（先澄清事项/对象）与 `collect`（明确提供或更正人员资料）。缺少或非法 action 按 intake 兼容；reply/clarify/collect 不执行方法，不能触发四方法兜底。无已有记录时不接受 supplement。模型只能提议目录中现有方法；客户端过滤未知 ID、去重并补上插件真实必需字段。本人档案不能自动套用于他人，对话中的他人对象应连续保持。
- `synthesize(run:history:onDelta:)` 使用真实 SSE 流，实时提取 JSON 中的 `text` 字段；元数据不会作为原始 JSON 出现在聊天中；实际分歧直接写进正文。模型的 `reasoning_content` 不解码、不保存、不展示。
- `followUp(question:run:profile:history:onDelta:)` 对已有资料与结果补充解释，不假装执行新算法。
- `summarize(transcript:previous:)` 专用于压缩过长的出站上下文。

规划时传入已有记录的完整输入、已调用方法及人员归属、全部可用结果与限制，避免把普通追问当作新一轮推演。supplement只提议本条确需新增或更新的方法，最终是否计算由客户端按方法、人员UUID、实际相关输入和插件版本判断。complete/partial可复用，failed/unavailable可重试；资料未变时，partial、方法名称被提到或用户要求展开都不会自行触发重算。

出生资料、坐标、时区等可定位的输入修正适合局部补算。事件的目标、所问时段、交易对象或关键约束发生实质变化，使原起卦所问不再成立时，规划为intake并确认新的问事；不能只在说明里宣称条件变化、却用相同输入要求重算。补充背景、情绪变化与自然过了一段时间本身不触发新起卦。

补算缺必要资料时进入统一表单；已有输入有效时直接执行新增或变化部分。`interactions`只允许已选方法对应的塔罗、数字或六爻操作。同一问事保留原起问时刻、seed、已完成报数、牌面、爻值和交互响应，仅为新增方法缺少的必要操作建立新步骤；必要交互完成后再计算并汇总。明确重新抽取或换问题走intake，生成独立的新输入。

补算生成新的`OracleRun`，完整复制仍有效的旧结果并合并新计算，保留原记录不变。`OraclePlan.baseRunID/followUpQuestion`记录来源及本条细化诉求，`OracleRun.reusedResultIDs`标记复用结果；综合上下文同时提供原问题和补充问题。删除源记录会取消尚未完成资料或交互的补算，已经完成的新记录因持有独立输入与完整结果仍可解读。

API 统一使用 wellecho.cn 的账号网关，客户端兼容模型标识为 `deepseek-v4-pro`，实际模型由服务器配置。`DeepSeekConfiguration` 清理旧 provider、模型和离线模式偏好，不再读取 `deepseek.model` 或保留设置中的模型选择入口。

连接检查仅供开发验证使用，不出现在产品设置中。测试可读取请求与返回模型、thinking、推理强度和输出预算元数据；这些请求同样经过账号网关并受服务器策略约束。未完成真实设备授权和请求验证时，不将模拟器或 mock 结果当作 iPhone 的诊断结论。

3.0.15 起所有 AI 调用统一走 `https://wellecho.cn/xiazi-api/v1/ai/chat/completions/`，使用自有账号 access token，不读取或携带供应商 key。请求包含 plan / synthesize / follow_up / summarize / geocoding / diagnostic purpose；服务器执行真实模型与预算策略并记录用量。客户端保留兼容模型配置、thinking 参数与 65,536 请求预算，服务器上限优先。`URLSession` 请求超时为 300 秒，资源总超时为 900 秒。仅最终 `content` 进入聊天，隐藏推理不会写入聊天或后续请求。

3.0.19 起显式沙盒构建使用 `ServiceEnvironment.current` 切换整套账号与 AI base 至 `https://wellecho.cn/xiazi-sandbox-api/v1/`。默认工程仍为生产，运行期没有环境开关。沙盒会话、失效标记、请求快照及结束队列独立；同一本机历史任务在沙盒映射为另一个稳定服务器 UUID，不能沿用生产票据。任务记录也校验环境标记，旧无标记记录仅允许生产迁移。

SSE 帧按每条完整 `data:` JSON 即时消费，不依赖 `AsyncBytes.lines` 是否保留空行；只有真正尚未闭合的 JSON 才跨行累积，避免把连续 JSON 对象拼接成无效响应。

计划与综合响应使用 JSON Output，并在 system 提示中给出 json 示例。若响应为空、截断或无效 JSON，应用返回可恢复错误并保留本地结果；429/5xx 不自动重发。结构化解析可进行一次即时格式修复，用户也可稍后重试。重试复用同一 task、stage 与本机保存的原始请求 bytes；解析修复额外携带 `X-Stage-Repair: 1`，受服务器最多两次显式修复策略约束。已完成步骤优先由服务器重放临时响应缓存，避免将同一步骤当成新任务重复计费。

塔罗原始数据保留本地英文牌名、牌位与对应正逆位牌义，按本次保存的抽牌结果送入综合和追问。服务器配置的模型结合问题生成所选语言的解读，重新请求解读时复用已有本地结果。

## 解读口吻

首次综合与后续追问共用 `interpretationStyle`：首句直接回答问题，有依据区分选项时明确表态，再用一至两条具体结果解释原因。建议只写与问题相关的对象、动作和推进或停止条件；主要解读通常250至400字，简单问题短答，不为了凑篇幅堆建议。

“各有利弊”“顺其自然”“保持开放心态”等不能替代判断。真实分歧直接在正文说清分歧点、各自依据和区分条件；资料不足则直接指出哪项问题无法判断、缺什么依据，其他已有依据的结论照常说明。保留 partial、缺项与未采用方法的真实限制，不为显得直接而编造具体日期、他人内心、概率或未来事实。追问先回答新问题，不重复整份旧解读，不模仿历史回复中的空泛措辞。

## 密钥

`AccountSessionVault` 用独立命名空间保存自有 access/refresh token 与 Apple 用户标识，采用 `AfterFirstUnlockThisDeviceOnly`。`AccountSessionManager` actor 供账号 UI 与 AI transport 共用，刷新 single-flight，防止过期 refresh 重放。供应商 key 只配置在服务端，历史 KeychainStore 保留供兼容测试，生产调用不再读取。

Debug 与 Release 均不读取、生成或打包 `dev-key.txt`、`qwen-key.txt` 等供应商凭据；构建阶段清理可能残留的旧资源。供应商 key 只由服务器保管和轮换，不下发给 App。历史配置脚本仅用于回归测试，合成测试凭据不能用于真实服务。详见[配置说明](../Configuration/README.md)。

启动从独立 Keychain 恢复账号会话，必要时刷新并检查 Apple 授权状态。Apple 原生登录使用服务器挑战及 SHA-256 nonce。退出先确保可用 access，再撤销当前 refresh；无法联网仍清理本机会话并明确提示。账号更换的 generation 会使旧刷新、账号响应与网关请求失效。401 只在同一账号代次内刷新并重发，复用 Idempotency-Key；最终 401 使会话失效并关闭主界面。主动重试复用逻辑任务及步骤，新问题申请新任务；请求是否重放缓存、重新调用上游及其实际用量均由服务器确认。

## 冲突说明

综合响应只要求正文 `text`，保留按能力验证的可选塔罗澄清字段。实际分歧直接在正文说明依据和条件，不生成偏好选项、不限定两组，不记录或发送方法权重。旧服务响应中的选项仅兼容为正文文字；旧档案中的说明保留为静态历史内容。用户历史选项选择不再影响判断。

## 上下文策略

档案 `OracleProfile` 与原始 `OracleRun` 永久独立保存，不参与压缩。对话原文也不删除。仅在待发送历史估算超过 32,000 token，且自上次压缩新增至少 24 条消息时考虑压缩；保留最近 16 条消息完整发送。压缩成功后记录已覆盖消息 ID，失败保持原状态。摘要用于连续对话，不得覆盖出生资料。

## 官方依据

- [Chat Completions 与 SSE](https://api-docs.deepseek.com/api/create-chat-completion/)
- [JSON Output](https://api-docs.deepseek.com/guides/json_mode/)
- [Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/)

本版本采用“结构化计划＋客户端白名单执行”模式：语言模型不能直接运行任意代码或访问未登记的插件。
