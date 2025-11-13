# 数据接口规划（Compass / Index / PhotoManager / WatermarkOverlay）

以下为项目核心数据接口的统一规划与落地路径，以满足 ArkTS 类型约束、避免 any/unknown、并提升跨模块复用性。

## 统一类型文件

- 文件路径：`entry/src/main/ets/types/DataInterfaces.ets`
- 内容包含：`LocationInfo`、`SatelliteParams`、`SatelliteAngles`、`WatermarkInfo`、`CompassSensorReadings`
- 使用准则：所有页面与视图组件使用上述统一接口，不在各自文件重复声明。

## 接口一览与使用映射

| 接口名 | 字段概要 | 归属模块 | 使用位置 | 数据来源 | 更新频率 | 校验规则 | 错误处理 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `LocationInfo` | `directionLon,valueLon,directionLat,valueLat` | Types | Compass、WatermarkOverlay | `geoLocationManager` 坐标格式化 | 坐标变更时 | 数值范围与格式化精度（10位） | 失败时显示默认“定位中…/定位失败” |
| `SatelliteParams` | `longitude,name,description` | Types | Compass | 静态配置（APSTAR/TIANTONG） | 切换卫星时 | 经度范围校验（-180~180） | 无；非法值回退默认 APSTAR |
| `SatelliteAngles` | `azimuth,elevation,polarization` | Types | Compass | 本地三角函数计算 | 气压/位置更新时 | 角度范围校验（0~360/-90~90） | 捕获 `Error` 并回退为上次有效值 |
| `CompassSensorReadings` | `azimuth,pitch,roll,pressure,magneticField` | Types | Compass | `@ohos.sensor` | 100ms/1000ms 间隔 | 合理范围：气压 300~1100hPa、磁场 >0 | 订阅失败日志 + 关闭订阅 |
| `WatermarkInfo` | `timestamp,weather,location,altitude,direction,longitude,latitude,organization` | Types | WatermarkOverlay、Index | 预览状态 & 相机信息 | 1s 时间戳刷新，拍照时冻结 | 字符串格式化与占位文案 | 读取/保存偏好失败捕获日志 |

## 代码落地与改动摘要

- 新增 `types/DataInterfaces.ets` 并在 `Compass.ets`、`Index.ets`、`WatermarkOverlay.ets` 引入统一接口。
- 修复 `Index.ets` 未显式类型的 `catch`（改为 `BusinessError`/`Error`）。
- 移除 `WatermarkOverlay.ets` 内部 `WatermarkInfo` 重复声明，统一从 `types` 导入。
- `Compass.ets` 保留本地计算函数（海拔、卫星角度），统一使用 `SatelliteParams/LocationInfo`。

## 校验与回归建议

- Lint：确认 `arkts-no-any-unknown` 无新告警（主要在 `Index.ets` catch）。
- 构建：编译通过后检查不存在 `LocationService`、`AltitudeCalculator`、`SatelliteCalculator` 的旧引用。
- 功能：在指南针页面切换卫星类型时，角度与说明正常刷新；相机主页水印时间戳每秒更新，组织名称可编辑并持久化。

## 演进与扩展

- 若后续引入外部定位/气象 SDK，可在 `types` 中添加 `WeatherInfo`、`GeoFix` 等接口，并在 `PhotoManager` 集成预热与缓存策略。
- 卫星表可外置为 JSON/Preferences，支持动态维护与远端更新；计算函数保持纯本地。