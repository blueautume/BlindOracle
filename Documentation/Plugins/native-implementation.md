# Native plugin implementation

七个Swift模块通过 `NativePlugins.all` 注册，模型和接口在 `Core/OracleModels.swift`。统一起盘日期范围1900–2100；公历输入来自显式时区，农历/节气使用vendored LunarSwift（MIT）。目前非东八区的月历及交节边界返回限制说明，不能据此宣称全球历史历法已逐地校准。

依赖全部随App编译或作为资源打包，不带Python、Node、浏览器或网络服务。Resources/Native包含21KB现代笔画表、1946称骨录文和许可证。Bundle查找支持资源根目录、Native与Resources/Native。

## 校验

八字采用上游2005-12-23 08:37东八区黄金用例（乙酉/戊子/辛巳/壬辰）；奇门以香港天文台2026年历的芒种6月5日23:48为交节边界；16:52尚为小满上元阳遁五局、天柱/惊门在兑七宫，23:49切为芒种上元阳遁六局。上游qfdk用wholeDay=true在当日零点提前切节，本版有意改用精确交节；小六壬2024农历新年子时为大安；梅花8/8/6为坤变剥；六爻纯乾世六应三，初甲子水子孙、上壬戌土父母。其余测试覆盖未知时辰、缺字拒绝、非法爻值和seed可复现。

测试验证计算实现及已声明取法，不验证传统预测有效性。姓名主算法为康熙部首笔画，简转繁候选与现代备选降级均标partial；六爻与奇门仍明确基础盘，不能把partial误写成完整专业断法。

## Sources pinned

- LunarSwift a7ec0e9b29f84a5d98b09b9ffd31145f17470d56。仅修改LunarYear共享单年缓存加递归锁，以保护并发调用。
- qfdk/qimen 1d0d1c5b39755e67525a11e68bab9b73baae1937，参考转盘公式后Swift独立移植；保留MIT。
- DHCPSV/zhishi-bazi 4a55e03a2ba7a5b6b63233dfaf59c5dbcb845d1c，只取1946公版称骨录文，保留MIT及源扫描链接。
- npm-chinese-character-strokes cb475605fc8a76b34f959d102471a87cbb6ebd37 / v0.0.3（ISC），把笔顺长度压成UInt8表，不宣称康熙口径。

交节核验主来源：https://www.hko.gov.hk/tc/gts/astron2026/files/HKO_almanac_2026.pdf 。LunarSwift给出时刻与该来源分钟一致。

## 数学与资料边界复审

- 六爻6/9为动爻，只翻转相应bit；爻序始终初爻到上爻。9/7/7/7/7/6为泽天夬，初与上爻变后为天风姤。
- 八宫变爻掩码为0/1/3/7/15/31/23/16，世爻为6/1/2/3/4/5/4/3；应爻相隔三位。
- 梅花动1–3取下卦为用、上卦为体，动4–6相反；互卦取二三四、三四五爻。五行采用木火土金水相生序，隔一位相克。
- 奇门以最近甲/己符头之地支定上中下元，而非直接按当日日支分组；节气按实际时刻交接。拆补、中五寄坤与完整断局限制保持显式。
- 出生日期或出生时区明确未知时，八字/称骨不使用保存的旧值。时辰未知只输出已确定部分与范围；交节日年/月柱列候选。
- 日期非有限数、无效时区、1900–2100以外均拒绝；不会把越界日期传进上游历法。
- 姓名缺字或显式未知姓/名返回unavailable，不猜笔画；康熙主表按码点键保留兼容字，简转繁候选未确认时partial。

## 可审计的第三方许可

- `Vendor/LunarSwift/LICENSE`：MIT，Copyright (c) 2023 6tail；资源副本在ThirdParty-LunarSwift.txt，注明缓存并发补丁和固定commit。
- `Resources/Native/ThirdParty-Qimen.txt`：保留qfdk/qimen源LICENSE的MIT全文；固定上游package.json标ISC的元数据不一致已记录，未随App带Node包。
- `Resources/Native/ThirdParty-Chenggu.txt`：MIT，Copyright (c) 2026 Zhishi contributors；称骨表/诗录自NTU藏1946公版扫描，记录源URL，不含扫描PDF。
- `Resources/Native/ThirdParty-Names.txt`：npm包声明ISC；保留声明、作者和原数据来源。表只含公开笔顺长度，不作为完整康熙资料。
- 未复制tt-qimen或meihua仓库中许可不明确的实现；六爻/梅花/小六壬/五格公式是本项目独立Swift实现。

## 典籍和康熙主表扩展

- iching-texts.json从MIT kentang2017/ichingshifa commit6526fe475b48d5daea99393fb2fa238aff8b9c9e中安全提取64卦辞、384爻辞和64彖传，仅公版古文；源LICENSE原样保留于ThirdParty-Iching.txt，包含上游原有Python Packaging Authority版权头。
- 六爻与梅花都返回本卦、动爻与变卦原文；乾坤全变另列用九/用六，不自动混入多爻变占断法。
- 蓍草实现经典三变归奇概率类，不是均匀4爻值，也不把铜钱概率冒充蓍草。
- 康熙主表新增于Resources/Native/kangxi-strokes.json，MIT、63,696字、精确码点键；详见kangxi-strokes-source.json与LICENSE。原现代笔画数表仅作显式partial备选。
