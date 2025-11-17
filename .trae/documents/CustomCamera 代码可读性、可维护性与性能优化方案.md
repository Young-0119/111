## 阶段 1：行为正确性与资源管理
- 修复权限请求外抛与返回值：让调用方可感知失败并决定退出（`entry/src/main/ets/utils/PermissionManager.ets:25–40`）
- 拍照旋转映射：基于加速度角度映射到 `ImageRotation`（`camera/src/main/ets/cameramanagers/PhotoManager.ets:935–944`, `963–1014`）
- 视图计时器清理：`WatermarkOverlay` 在销毁时清除 `setInterval`（`entry/src/main/ets/views/WatermarkOverlay.ets:79–89`, `104–109`）
- 显示信息缓存：封装并缓存 `display.getDefaultDisplaySync()`（`camera/src/main/ets/cameramanagers/PhotoManager.ets:195–201, 1128–1134`）
- 日志降噪：以 `debug` 开关控制详细日志（`camera/src/main/ets/cameramanagers/PhotoManager.ets:127, 188–190, 1589–1593`）
- 验收：权限失败用例触发退出；不同姿态拍照角度正确；切页或销毁后无定时器输出；预览与拍照路径日志仅在 `debug` 下详尽

## 阶段 2：水印合成性能与内存优化
- 引入画布合成路径：创建与原图同尺寸的 `OffscreenCanvas`，一次 `getPixelMap` 合成替代逐像素读写（`camera/src/main/ets/cameramanagers/PhotoManager.ets:1126–1154, 1403–1421, 1424–1533`）
- 就地混合作为回退：仅当画布不可用或失败时走现有 `readPixels/writePixels`；简化循环并保留透明跳过
- 统一释放：保存后释放原图与水印 `PixelMap`，避免峰值内存（`camera/src/main/ets/cameramanagers/PhotoManager.ets:786–798, 1042–1083`）
- 验收：在 12MP/48MP 等不同分辨率下合成耗时下降、内存峰值下降；水印位置与清晰度一致；前后台切换后首次拍摄无明显卡顿

## 阶段 3：配置与可维护性增强
- 水印参数集中：比例、TTL、质量等抽为配置对象并支持注入（`camera/src/main/ets/cameramanagers/PhotoManager.ets:118–131, 152–175`）
- 组织值一致性：底图缓存键与底部文案值统一来源（`camera/src/main/ets/cameramanagers/PhotoManager.ets:1185–1190, 1379–1384`）
- 第三方密钥管理：`AmapService` 通过偏好或环境注入密钥，并继续遮蔽日志（`camera/src/main/ets/dataservices/AmapService.ets:59–65, 82–90, 133–151`）
- 构建与签名：确保签名材料仅用于本地调试，不随仓库分发（`build-profile.json5:3–16`）
- 验收：参数可配置且生效；组织变更触发缓存刷新与预热；密钥不出现在日志；构建产物不包含敏感材料

## 交付与回归
- 每阶段提交：变更说明、关键代码位置、性能对比数据（耗时/内存）、回归测试清单
- 影响面：水印、拍照、权限、预览；保持接口与用户体验不变

## 后续优化候选
- 视频流水线的帧率与稳定性策略统一（`PreviewManager`/`VideoManager`）
- 将水印处理抽象为独立模块以便单元测试与复用
- 在 `Index.ets` 的首帧链路中加入预热状态提示以优化体感