# 梅花易数 · `meihua`

版本：1.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：默认以当前农历时间起卦；numbers可传2或3个整数。

输出：本卦/互卦/变卦、动爻、体/用卦、体用五行生克及完整取数过程。

能力边界：三数前两数定卦、第三数定动爻；双数两原数加时辰取动爻。互卦统一取本卦2/3/4和3/4/5爻，不作乾坤特殊改取。不含外应与应期。

依赖与来源：BlindOracle独立Swift实现，传统先天卦序与位运算。

所有方法统一保留 `rows` 原始表、`evidence` 命中规则、`limitations`、`status`、版本与来源。只有已实现的规则可以生成 evidence，不能将未计算内容交给模型补造。`polarity` 是传统符号方向，不是现实概率。对具体占问的适用性由规划器判断；同一输入和seed须得到同样结果。无HTTP、在线字典、云历法或模型调用。

测试覆盖与限制详见 `Tests/NativePluginTests.swift` 和 `Documentation/Plugins/native-implementation.md`。

典籍扩展：现从本地iching-texts.json取本卦卦辞、动爻对应爻辞与变卦卦辞，并作为独立中性evidence保留原文；数据覆盖64卦、384爻。文本缺失时降为partial，绝不补造原文。取文不替代梅花体用法，也不冒充完整外应/应期断法。
