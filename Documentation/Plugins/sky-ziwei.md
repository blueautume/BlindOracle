# ziwei · 紫微斗数

插件版本 `1.0.0+iztro.2.6.3`。`ZiweiPlugin` 实现 `OraclePlugin`；由 `SkyPlugins.all` 注册。

## 接口与输入

`calculate(OracleInput) async throws -> OracleResult`

必须有确认过的公历出生日期、出生时间、出生地 IANA 时区和排盘性别（男 / 女）。`birthDate` 是已由表单按出生地时区解析的绝对时刻，插件会用该时区恢复民用日期与时辰。当前支持 1900–2100 年。23 点为晚子时（索引 12），0 点为早子时（索引 0），其余按两小时划分。

输入标记为不确定时，返回 `unavailable`，不猜测一个时辰或性别。所在地不可替代出生地。问事时刻只用于运限查询。

## 本地实现

`Resources/Sky/iztro.bundle.js` 内置 iztro 2.6.3 及锁定依赖，通过系统 JavaScriptCore 执行。脚本没有原生网络桥接、fetch、XMLHttpRequest 或远程资源。设备不需要 Node、npm、Python、WebView 或本地 HTTP 服务。

配置固定为 `yearDivide=normal`、`horoscopeDivide=normal`、`dayDivide=forward`、`fixLeap=true`、`zh-CN`。闰月前后半月调整。出生时间未作真太阳时校正。需要其他流派时应增加明确配置并验证，而不是默默改默认行为。

## 输出

十二宫、主辅星与亮度、生年四化、大限区间、问事流年四化、问事虚岁。`evidence` 只对四化做显式符号规则映射：禄偏资源、权偏责任主导、科偏条理与可见度、忌偏牵挂与反复。该映射不构成经验预测概率，不能单星断事件。原始宫位独立保存在 `rows` 中，供数据页查看；AI 应同时读取 limitations。

## 来源与验证

- 上游：<https://github.com/SylarLong/iztro>，版本 2.6.3，MIT。
- 精确依赖版本见 `Resources/Sky/dependencies.json`；许可证见 `Resources/Sky/Licenses`。
- 可复现打包源码、npm lock 与脚本位于 `Plugins/Sky/Build`；这些是开发工具，不是运行依赖。
- 回归样例：1990-05-17T04:00:00Z，即当年上海夏令时下的 13:00（未时），男，土五局、命宫戌、贪狼；固定输入重复运行应逐行一致。不能用今天的 UTC+8 替代历史时区。
