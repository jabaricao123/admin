# 系统管理 · 字典管理

| 项 | 值 |
|---|---|
| 路由 | /system/dictionaries |
| 状态 | P1，待立项（admin 专用） |
| 模块 | [system](../README.md#9-系统管理-systemp1) |

## 目的

跨模块共享码表：状态值、类别等公共枚举的集中维护（如通用状态、是/否语义），替代散落硬编码。

## 功能需求

1. 字典列表：按 dict_key 分组；每项含 value、label、排序、配色类名、状态。
2. 编辑：label/排序/配色可改；value 建后不可改（被引用）；停用项前端下拉过滤但存量数据展示不破。
3. 新增字典：登记 dict_key + 用途说明；与 `lib/dictionaries.ts` 的映射约定：前端代码引用 dict_key，运行时取数（编译期兜底默认值）。
4. 模块私有枚举不进本表（INDEX 边界：随各模块迁移走）。

## 数据模型

`system_dictionaries`：dict_key、value、label、sort_order、color_class、status、updated_by、时间戳，主键 (dict_key, value)。
读取口：`get_dict(dict_key)` RPC（全模块可读，带缓存 TTL 60s）；前端 `lib/dictionaries.ts` 保留编译期兜底默认值——**新增字典项必须同步 seed/代码生成默认值**（CI 校验 dict_key 集合一致）。

## RLS

- 全员可读；仅 admin 可写。

## 界面规格

- 左侧字典分组导航 + 右侧项列表（Table）+ Sheet 编辑；配色预览 Badge。

## 依赖与契约

- 消费方：所有需要共享码表的模块；前端 `dictionaries.ts` 改造为优先 RPC、本地默认兜底。

## 验收标准

- 改 label 后全站展示即时更新；停用项不再出现在新表单下拉、旧数据展示不受影响。
