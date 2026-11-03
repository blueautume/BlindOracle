# 塔罗牌 · `tarot`

版本：1.0.0。完全设备本地抽牌、读取牌义与展示牌面；最终结合问题的自然语言解读沿用现有AI服务。

输入 `OracleInput.tarotDraws` 保存首轮三张不同的已翻牌，固定顺序为 `Current situation`、`Influences`、`Advice`（现状、影响、建议）。每张保存 `cardID`、`isReversed` 与 `position`。可选的 `tarotClarificationRounds` 保存最多两轮补牌，每轮包含追问、澄清焦点、可选的关联原牌位及一张已翻牌。输入无效时返回 `unavailable`。

牌库：78张经典韦特牌（22张大阿尔卡纳及权杖、圣杯、宝剑、星币各14张），位于 `Resources/Tarot/tarot-cards.json`。英文正逆位关键词来自 LindseyB/tarot-api 的固定提交 `319ce18f1b583035e00c63854a2a405a0088bc73`，保留MIT许可证与来源。UI仅本地显示中文牌名；牌义保持英文供现有AI按问题解读。

UI 调用 `TarotDeck.shuffled(seed:)` 得到不重复的牌序，补牌沿用该牌序并排除已抽牌。该洗牌采用固定的 Fisher–Yates 算法、SplitMix64 随机源及拒绝抽样，`TarotDeck.isReversed(seed:cardID:)` 独立派生朝向。恢复交互时读取保存的选牌和翻牌进度，重试解读使用已确认的牌面。

输出包含原牌阵及各轮补牌的牌名、牌位、正逆位和英文牌义关键词。`OracleResult.tarotDraws` 和 `tarotClarificationRounds` 供历史卡面展示。每轮补牌的解读综合首阵和全部已确认的补牌。

牌面：78张离线经典 Rider–Waite–Smith 扫描牌面，来自同一固定仓库，其README可追溯至luciellaes整理的原始扫描包。保留原300×527像素，转成JPEG控制体积。未使用现代商业牌组或生成式图片。资源说明、MIT全文、每文件来源和SHA256见 `Resources/Tarot/ThirdParty-Tarot-Sources.txt`、`ThirdParty-Tarot-MIT.txt`、`source-manifest.json`。维护时用 `Scripts/fetch_tarot_resources.py`重建资源，运行时无资源网络依赖。

本版支持现状、影响、建议三张牌阵及同一副牌的澄清牌。塔罗牌义作为象征文本与自我反思材料，不表示经验证的事件概率。
