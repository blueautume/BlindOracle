# 塔罗牌 · `tarot`

版本：1.0.0。完全设备本地抽牌、读取牌义与展示牌面；最终结合问题的自然语言解读沿用现有AI服务。

输入：`OracleInput.tarotDraws`，必须是已经由用户选取并翻开的三张不同牌，固定顺序为 `Current situation`、`Influences`、`Advice`（现状、影响、建议）。每张保存稳定 `cardID`、`isReversed` 与 `position`。不需要出生日期、时间、地点或数字。记录缺失、张数错误、重复牌、未知牌或牌位顺序错误时返回 `unavailable`，不会在插件中静默重新抽牌。

牌库：78张经典韦特牌（22张大阿尔卡纳及权杖、圣杯、宝剑、星币各14张），位于 `Resources/Tarot/tarot-cards.json`。英文正逆位关键词来自 LindseyB/tarot-api 的固定提交 `319ce18f1b583035e00c63854a2a405a0088bc73`，保留MIT许可证与来源。UI仅本地显示中文牌名；牌义保持英文供现有AI按问题解读。

抽牌：UI调用 `TarotDeck.shuffled(seed:)` 得到不重复的牌序，用户自行点选三张后翻牌。该洗牌采用固定 Fisher–Yates 算法、SplitMix64随机源及拒绝抽样；`TarotDeck.isReversed(seed:cardID:)`独立派生朝向。最终保存具体三张牌与朝向，历史读取不重新生成。种子只用于复现界面洗牌，不是现实信息来源。

输出：固定牌阵、用户原始抽牌方式、三张牌的中英文名称、牌位、正逆位及对应英文牌义关键词；`OracleResult.tarotDraws`保存相同抽牌记录供历史卡面展示。证据文本保留牌位与正逆位，默认无正负方向投票，不把正位一概当作吉、逆位一概当作凶。

牌面：78张离线经典 Rider–Waite–Smith 扫描牌面，来自同一固定仓库，其README可追溯至luciellaes整理的原始扫描包。保留原300×527像素，转成JPEG控制体积。未使用现代商业牌组或生成式图片。资源说明、MIT全文、每文件来源和SHA256见 `Resources/Tarot/ThirdParty-Tarot-Sources.txt`、`ThirdParty-Tarot-MIT.txt`、`source-manifest.json`。维护时用 `Scripts/fetch_tarot_resources.py`重建资源，运行时无资源网络依赖。

限制：本版只支持现状/影响/建议三张牌阵，不包含凯尔特十字、自定义牌阵、实体牌相机识别、每日推送或付费牌组。塔罗牌义作为象征文本与自我反思材料，不表示经验证的事件概率。
