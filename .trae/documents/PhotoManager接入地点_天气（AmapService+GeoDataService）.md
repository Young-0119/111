## 目标
- 在拍照水印信息中：
  - 地点/天气：由 AmapService 获取（REST，高德）
  - 海拔/方位角/经纬度：由 GeoDataService 获取（传感器/定位）
- 保持三态显示：获取中/获取失败/获取到；使用现有缓存 TTL（30s）

## 当前代码位置
- 预热信息：`camera/src/main/ets/cameramanagers/PhotoManager.ets:188` `prewarmWatermarkInfo`
- 现有占位：`getWeatherInfo`:572 返回固定“晴朗”；`getLocationInfo`:580 返回 `lat, lon` 或“定位中...”（需改为高德格式）
- GeoDataService 快照：`PhotoManager.ets:193` 直接读取；启动订阅：`PhotoManager.ets:268`

## 设计与改动
- 避免 camera 直接依赖 entry 模块：新增可选“外部地点/天气提供器”注入机制
  - 新增字段：`private externalLocWeaProvider?: () => Promise<{ location: string; weather: string }>`
  - 新增方法：`setLocationWeatherProvider(provider: () => Promise<{ location: string; weather: string }>): void`
  - 入口调用：由 entry 层（如 WatermarkOverlay 或初始化流程）传入封装了 AmapService 的 provider
- 使用策略：
  - 在 `prewarmWatermarkInfo` 中，若已注入 provider，则优先调用并写入 `this.cachedInfoValues.weather/location`
  - `getWeatherInfo` 与 `getLocationInfo`：
    - 若有缓存则使用缓存
    - 若注入 provider 可用，则拉取并更新缓存
    - 否则：保持现有占位（天气“获取失败”/“获取中”，地点用 GeoDataService 的 `lat, lon` 文本或“获取中”）
- 文本格式：
  - 地点：AmapService 返回“省·市·区·街道号”（若缺街道则到区）；无则显示“获取失败”
  - 天气：`天气 温度℃ 风向风力级 湿度%`；无则“获取失败”

## 代码改动要点（PhotoManager.ets）
1. 字段与方法
- 在类字段区新增 provider 字段（靠近缓存字段）：`PhotoManager.ets:169–171` 下方
- 新增 `setLocationWeatherProvider(...)` 方法（类内部，便于 entry 层调用）
2. 预热流程
- 修改 `prewarmWatermarkInfo`：
  - 若 `externalLocWeaProvider` 存在，`await provider()` 并将结果写入 `weather/location`
  - 其余字段仍从 `GeoDataService.getInstance().getSnapshot()` 填充
3. 拉取函数
- 修改 `getWeatherInfo`（572）与 `getLocationInfo`（580）：
  - 使用注入 provider 与缓存，失败时返回“获取失败/获取中”

## entry 层接入（不改动 camera 与 entry 的依赖方向）
- 在 `WatermarkOverlay.ets` 或初始化处：
  - 构造 provider：`async () => await AmapService.fetchLocationAndWeatherAuto()`
  - 调用 `photoManager.setLocationWeatherProvider(provider)` 完成注入

## 验收标准
- 有网且授权时：地点/天气显示来自高德，其他信息使用 GeoDataService；拍照水印与预览一致
- 无网或失败：地点/天气为“获取失败”，其余信息不受影响
- 缓存 30s 生效，避免频繁请求

我将按照上述方案对 PhotoManager.ets 添加注入接口与使用逻辑，并在 entry 层提供 provider 的调用示例。