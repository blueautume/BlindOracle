# 小六壬 · `xiaoliuren`

版本：1.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：当前起课时间与时区。

输出：月宫、日宫、时宫及六宫通行象征释义。

能力边界：农历月起宫，日和时逐步减1取余；闰月沿用本月；日界采用本地农历零点。不混用其他起课法，不给事件概率。

依赖与来源：BlindOracle独立Swift实现；历法MIT。

所有方法统一保留 `rows` 原始表、`evidence` 命中规则、`limitations`、`status`、版本与来源。只有已实现的规则可以生成 evidence，不能将未计算内容交给模型补造。`polarity` 是传统符号方向，不是现实概率。对具体占问的适用性由规划器判断；同一输入和seed须得到同样结果。无HTTP、在线字典、云历法或模型调用。

测试覆盖与限制详见 `Tests/NativePluginTests.swift` 和 `Documentation/Plugins/native-implementation.md`。
