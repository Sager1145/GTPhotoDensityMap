# 热点图设置研究

核实日期：2026-10-25。只参考第一方文档与公开源码；下方产品建议属于本项目的设计判断。

## 官方实现对照

| 实现 | 大小 / 扩散语义 | 不透明度与颜色 |
| --- | --- | --- |
| Leaflet.heat | `radius` 默认 25，`blur` 默认 15，分别控制点半径和模糊；源码先把经纬度转换为地图容器坐标再绘制 Canvas，因此属于屏幕坐标尺度，非米数。 | `minOpacity` 是最低可见不透明度，不能直接当成整个图层的 opacity；`gradient` 将强度映射到颜色。见 [官方 README](https://github.com/Leaflet/Leaflet.heat#reference)、[绘制源码](https://github.com/Leaflet/Leaflet.heat/blob/gh-pages/src/HeatLayer.js)。 |
| MapLibre | `heatmap-radius` 明确以 pixels 表示单点影响半径，默认 30；增大后更平滑、细节减少。`heatmap-intensity` 是全局强度倍率，可随缩放调整。 | `heatmap-opacity` 为整个图层的 0–1 不透明度，默认 1；`heatmap-color` 按 `heatmap-density` 取色。见 [官方样式规范](https://maplibre.org/maplibre-style-spec/layers/#heatmap)。 |
| Kepler.gl | 当前公开源码暴露 `radius`、`intensity`、`threshold`；将半径按 zoom 从 2 插值到设置值后传入 `radiusPixels`，所以设置值不是所有缩放级别下的固定地理半径。 | 配置有 `opacity` 和 `colorRange`；颜色数组转为色带，强度还会随 zoom 插值。见 [官方 HeatmapLayer 源码](https://github.com/keplergl/kepler.gl/blob/master/src/layers/src/heatmap-layer/heatmap-layer.ts)。 |

共同点是把空间平滑程度、图层透明度和密度色带分开。不要用“不透明度”替代强度倍率，也不要把屏幕半径标成地理覆盖距离。

## 本项目建议

| 设置 | 建议控件与初始值 | 实现约束 |
| --- | --- | --- |
| 热点扩散 | 保留现有 10–100 滑块，默认 50；两端文字“集中 / 扩散”，显示整数。 | 当前 `PhotoLocationManager` 用 `Int(radius / 10) + 1` 转成网格单元范围，再用高斯核扩散；这既不是像素也不是米。当前应标“扩散”，不要显示 px。若未来改屏幕半径，需要依地图投影和缩放转换，并统一 macOS point 与 backing pixel。 |
| 不透明度 | 0%–100%，默认 70%，步长 5%。 | 调整最终 overlay 绘制 alpha，保留原色带内部的透明度变化；不触发照片重读或密度网格重算。当前绘制已有固定 `setAlpha(0.7)`，可参数化。 |
| 颜色主题 | 三个预设：“经典”（蓝→青→绿→黄→红）、“暖色”（深紫→红→橙→浅黄）、“海洋”（深蓝→青→浅青）。默认经典以保留当前外观。 | 主题以同一份色标数据驱动渲染与图例；保持低密度透明、零密度不着色。两种新增主题是产品提案，并非上述库的默认主题。 |

建议放进地图工具栏的“热点设置”弹出面板，增加“恢复默认”一次还原所有选项；地图底图选择继续独立。此次无需暴露 weight、threshold 或 aggregation：照片计数已是明确权重。实现额外提供强度倍率（0.5–3×，默认 1×）与渲染平滑（0–2×，默认 1×；内部高斯模糊系数为 0–3，默认 1.5），分别帮助稀疏照片显色和调整网格边缘柔和程度。扩散滑杆松手后才提交，以免拖动时反复重算密度网格。

调整扩散会改变平滑后的峰值与重叠程度；图例宜继续表达“低 → 高”的相对照片密度，避免把颜色承诺为未经校准的每平方公里照片数。上述范围与默认值是适配当前代码的小范围建议，不是行业统一标准。
