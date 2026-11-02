# 奇门遁甲 · `qimen`

版本：1.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：当前起盘时刻与时区。

输出：节气/符头/三元/阴阳遁局、旬首六仪、值符/值使、九宫天地干/九星/八门/八神。

能力边界：固定时家转盘拆补，五日符头定元，中五寄坤，由寄宫加时。无暗干、完整十干克应/用神与应期，返回partial。

依赖与来源：qfdk/qimen MIT公式参考＋LunarSwift MIT；Swift移植，无Node/Express。

所有方法统一保留 `rows` 原始表、`evidence` 命中规则、`limitations`、`status`、版本与来源。只有已实现的规则可以生成 evidence，不能将未计算内容交给模型补造。`polarity` 是传统符号方向，不是现实概率。对具体占问的适用性由规划器判断；同一输入和seed须得到同样结果。无HTTP、在线字典、云历法或模型调用。

测试覆盖与限制详见 `Tests/NativePluginTests.swift` 和 `Documentation/Plugins/native-implementation.md`。

交节采用实际时刻而非整日：与qfdk/qimen的getPrevJieQi(true)不同。2026-06-05 23:48东八区前仍属小满；此边界以香港天文台年历核验。
