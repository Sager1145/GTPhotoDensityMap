# 热点选项合并说明

此独立分支基于 getangar 原始版本。请按功能合并 `ContentView.swift`，保留主 chat 已完成的投影、缓存与后台计算修复。

- 可直接合并：`Models/HeatmapAppearance.swift`、`Views/HeatmapOptionsView.swift`、Tests、Xcode 两个新文件引用、工具栏 popover 与图例。新增模型均为 `Sendable` 值类型。
- `HeatmapAppearance` 由 ContentView 的 State 持有。`HeatmapOptionsView` 使用 Binding；`PhotoLocationManager.heatmapRadius` 保留原接口、默认 50。只有扩散和恢复默认会写入该属性，扩散拖动结束才写入。
- 主 chat 新 `HeatmapRasterizer.makeImage(grid:maxDensity:)` 请增加 appearance 参数；用 `appearance.palette.color(at: appearance.normalizedDensity(density / max(maxDensity, .leastNonzeroMagnitude)))` 取代旧固定配色；原 blur 系数 1.5 换成 appearance.smoothing，0 时跳过 blur。此工作应继续在后台进行，不要恢复本分支原版 renderer 内的图像生成。
- intensity / smoothing / palette 变更应从现有 grid 重新 rasterize 并发布新的 image/id；无需重读 Photos、无需重新累计密度。将这三项加入图像缓存 key，或明确走外观重绘路径。不要让 viewport/radius 相同的 reuse 路径吞掉这些修改。
- opacity 仅用于 renderer 最后绘制的 alpha（默认 0.7）；仅改 opacity 不必 rasterize。renderer/overlay 更新判定需包含 opacity，不能只比较 HeatmapData.id。遵守 MapKit renderer 的线程约束，用不可变绘制快照或安全同步。
- 热点颜色图例与渲染共用 palette.stops；底部图例仍是“低→高”相对密度，没有伪造地理单位。

本分支不修改 PhotoLocationManager、授权代码或 MapViewModel，不触碰主目录或 /Applications。
