# DeepSeek 调度与对话

本地插件负责所有排盘、抽牌、起卦与确定性规则；DeepSeek 只负责选择适用插件、说明需要的资料与交互，以及整合本地结果与中文追问解读。

## 调用接口

- `DeepSeekClient.plan(question:profile:plugins:history:)` 返回 `OraclePlan`。`action` 白名单为 `intake`（具体新问题）、`reply`（延续解释或普通对话）、`clarify`（先澄清事项/对象）。缺少或非法 action 按 intake 兼容；reply/clarify 强制清空方法、资料和交互要求，不能触发四方法兜底。模型只能提议目录中现有方法；客户端过滤未知 ID、去重并补上插件真实必需字段。`interactions` 只允许已选方法对应的塔罗、数字或六爻操作；全部必要交互完成并生成本地结果后，才调用解读。本人档案不能自动套用于他人，对话中的他人对象应连续保持。
- `synthesize(run:weights:history:onDelta:)` 使用真实 SSE 流，实时提取 JSON 中的 `text` 字段；元数据和替代选项不会作为原始 JSON 出现在聊天中。模型的 `reasoning_content` 不解码、不保存、不展示。
- `followUp(question:run:profile:history:onDelta:)` 对已有资料与结果补充解释，不假装执行新算法。
- `summarize(transcript:previous:)` 专用于压缩过长的出站上下文。

API 使用 `https://api.deepseek.com/chat/completions`，默认模型为 DeepSeek Pro（`deepseek-v4-pro`）。`DeepSeekConfiguration` 在首次升级时，将旧的 `deepseek-flash`、`deepseek-v4-flash`、`deepseek-chat` 默认值迁移为 Pro；迁移完成后，用户在设置中主动选择的模型会保留。模型名存于 `UserDefaults` 的 `deepseek.model`。

所有请求显式设置 `thinking: {"type":"enabled"}` 与 `reasoning_effort: "max"`，统一使用 65,536 token 输出预算，包含推理与最终回答，而非最终正文的目标长度。`URLSession` 的请求超时为 300 秒、资源总超时为 900 秒，以容纳较长推理。模型的隐藏推理仍不解码、不保存、不展示，也不写入聊天历史或后续请求；应用只消费最终 `content`。

SSE 帧按每条完整 `data:` JSON 即时消费，不依赖 `AsyncBytes.lines` 是否保留空行；只有真正尚未闭合的 JSON 才跨行累积，避免把连续 JSON 对象拼接成无效响应。

计划与综合响应使用 JSON Output，并在 system 提示中给出 json 示例。若响应为空、截断或无效 JSON，应用返回可恢复错误，保留本地结果。计划 JSON 有一次格式重试；非流请求遇到 429/5xx 最多重试两次。流式请求开始后不会自动重复发送，以免重复输出或多次计费。

塔罗原始数据保留本地英文牌名、牌位与对应正逆位牌义，按本次保存的抽牌结果送入综合和追问；DeepSeek 结合问题生成中文解读，不重新抽牌、不改变朝向，不声称读取未提供的图片细节。重新请求解读复用已有本地结果。

## 密钥

`KeychainStore.shared.string()` / `save(_:)` / `delete()`。钥匙串使用 `AfterFirstUnlockThisDeviceOnly`，无 iCloud 同步，不进入档案、消息或日志。

开发密钥由已忽略的 `Configuration/Secrets.local.json` 管理，仓库仅提交 `Secrets.example.json` 空白模板。Debug 构建生成私有 `dev-key.txt` 资源，启动时将变更同步到钥匙串；资源及构建目录均被忽略。Release 不生成该资源，也没有此导入路径。正式使用时由用户在设置中录入自己的密钥。

## 冲突与偏好

综合响应仅接受零个或两个选项。支持者只允许来自本轮 complete/partial 结果；同一方法不得同时出现在两组。权重在提示中明确为个人偏好，不是预测准确率。逐次反馈更新与本地持久化由应用 Store 实现，服务层不会自行修改权重。

## 上下文策略

档案 `OracleProfile` 与原始 `OracleRun` 永久独立保存，不参与压缩。对话原文也不删除。仅在待发送历史估算超过 32,000 token，且自上次压缩新增至少 24 条消息时考虑压缩；保留最近 16 条消息完整发送。压缩成功后记录已覆盖消息 ID，失败保持原状态。摘要用于连续对话，不得覆盖出生资料。

## 官方依据

- [Chat Completions 与 SSE](https://api-docs.deepseek.com/api/create-chat-completion/)
- [JSON Output](https://api-docs.deepseek.com/guides/json_mode/)
- [Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)
- [Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/)

本版本采用“结构化计划＋客户端白名单执行”模式：语言模型不能直接运行任意代码或访问未登记的插件。
