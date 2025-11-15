## 问题
- PhotoManager 使用了内联对象字面量类型 `Promise<{ location: string; weather: string }>`，触发 ArkTS 规则 `arkts-no-obj-literals-as-types`。

## 方案
- 声明显式接口 `LocationWeatherResult`，替换所有内联对象字面量类型：
  - 字段 `externalLocWeaProvider?: () => Promise<LocationWeatherResult>`
  - 方法 `setLocationWeatherProvider(provider: () => Promise<LocationWeatherResult>): void`
- 不改动业务逻辑，只替换类型签名。

## 验收
- 编译通过，无 ArkTS 类型违规
- 现有调用与缓存逻辑保持不变