# 称骨 · `chenggu`

版本：1.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：出生日期；时辰未知可输出范围；出生时区。

输出：年/月/日/时骨重、合计与匹配的历史原诗。

能力边界：固定1946《大雜字不求人》录文；以农历年换年，闰月沿用本月。原刊2两1缺文，不补造。未知时辰输出所有时辰骨重的最小/最大值，不选择原诗。不得从原诗推定寿命/亲属结局等现实事实。

依赖与来源：NTU藏1946公版扫描，DHCPSV/zhishi-bazi MIT录文；本地JSON。

所有方法统一保留 `rows` 原始表、`evidence` 命中规则、`limitations`、`status`、版本与来源。只有已实现的规则可以生成 evidence，不能将未计算内容交给模型补造。`polarity` 是传统符号方向，不是现实概率。对具体占问的适用性由规划器判断；同一输入和seed须得到同样结果。无HTTP、在线字典、云历法或模型调用。

测试覆盖与限制详见 `Tests/NativePluginTests.swift` 和 `Documentation/Plugins/native-implementation.md`。

边界审查：出生时区明确标未知时无法确定农历日界，返回unavailable；不沿用旧时区。时辰未知时只输出总重范围，不选择时骨重或某首原诗。
