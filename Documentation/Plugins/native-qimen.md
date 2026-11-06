# 奇门遁甲 · `qimen`

版本：2.0.0。执行位置：设备本地。入口：`OraclePlugin.calculate(OracleInput) async throws -> OracleResult`。

输入：真实起盘时刻、当前所在地的确认坐标及当前时区。使用起卦地点，不借出生地点；坐标撤回、缺失、非有限值或越界时返回unavailable，不默认东经120度。

时间口径：`TrueSolarClock.casting(input:)`保留原始instant。日符头和时盘取当地经度与均时差校正后的真太阳钟面；太阳钟面00:00换日，23:00只进入子时。时干继续使用LunarSwift子初换干规则，结果明确记录这一组合。节气、太阳年/月干支、阴阳遁必须从原始真实instant对应的固定UTC+08历表取得；虚拟太阳钟面不得移作天文瞬间。冬夏令时已体现在原始instant与民用偏移中，不能重复扣除。

输出：原始钟表时间、真太阳钟面、计算经度、经度/时制校正、均时差、总校正、纪日/子时规则，以及节气/符头/三元/阴阳遁局、旬首六仪、值符/值使、九宫天地干/九星/八门/八神。

能力边界：固定时家转盘拆补，五日符头定元，中五寄坤，由寄宫加时。无暗干、完整十干克应/用神与应期，返回partial。该时间口径是本项目明示的实现规则，不声称所有奇门流派必须如此。地区坐标为代表点，接近边界应核对实际地点。

依赖与来源：qfdk/qimen MIT公式参考、LunarSwift MIT和共享TrueSolarClock；Swift移植，无Node/Express。真实交节而非整日换节；2026-06-05芒种的东八区分钟边界沿用既有香港天文台年历核验，新增测试同时覆盖真实交节前后1秒与东西不同经度。

新计算结果及unavailable结果均标2.0.0。既有1.0.0保存结果不重算、不改写，也不得作为本版本新盘复用。保留rows、evidence、limitations和来源；不让模型补造未计算内容。无HTTP或模型调用。

验收用例：`Tests/NativeSolarTimeTests.swift`与既有`Tests/NativePluginTests.swift`。本批由主任务统一构建和执行，本文不提前声称通过。
