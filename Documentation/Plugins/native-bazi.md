# 八字 / 四柱 · `bazi`

版本：1.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：出生日期和有效出生时区必需，时辰和排盘性别可未知。时区明确标未知时不使用旧值，返回unavailable。

输出：四柱、十神、藏干、五行表层计数、纳音、旬空、起运与8步大运。

能力边界：出生时间未知时不生成时柱或大运；不以五行缺项推定喜用神；不自动判断格局/合化/根气；支持1900–2100年。

依赖与来源：6tail/lunar-swift MIT，本地Swift源码。

所有方法统一保留 `rows` 原始表、`evidence` 命中规则、`limitations`、`status`、版本与来源。只有已实现的规则可以生成 evidence，不能将未计算内容交给模型补造。`polarity` 是传统符号方向，不是现实概率。对具体占问的适用性由规划器判断；同一输入和seed须得到同样结果。无HTTP、在线字典、云历法或模型调用。

测试覆盖与限制详见 `Tests/NativePluginTests.swift` 和 `Documentation/Plugins/native-implementation.md`。

边界审查：时辰未知时先比较当日0:00与23:59的年/月柱；如当日交节，则列出前后候选并停止单值五行/起运分析，不展示保存的默认时刻。尚未实现扩展八字神煞、格局、喜用神、全套合化根气。
