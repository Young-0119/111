# 照片叠加水印功能开发指南

## 概述
本文档介绍如何在当前相机项目中实现照片叠加水印功能。项目中已固定水印UI为 `WatermarkOverlay.ets` 中的设计，包括应急消防主题的水印内容和旋转90度的特殊布局。

## 当前工程结构分析

### 水印相关组件
```
entry/src/main/ets/views/WatermarkOverlay.ets          # 水印覆盖层组件（UI已固定）
entry/src/main/ets/pages/Index.ets                     # 主页面（已集成水印）
entry/src/main/ets/viewmodels/PreviewViewModel.ets     # 预览视图模型
```

### 相机管理模块
```
camera/src/main/ets/cameramanagers/
├── PhotoManager.ets          # 照片管理器
├── ImageReceiverManager.ets    # 图像接收管理器
├── CameraManager.ets           # 相机管理器
└── PreviewManager.ets          # 预览管理器
```

### 工具模块
```
entry/src/main/ets/utils/
├── CommonUtil.ets             # 通用工具
├── PermissionManager.ets        # 权限管理
└── WindowUtil.ets              # 窗口工具
```

## 固定水印UI结构分析

### 1. 水印信息结构（已固定）

项目中定义的 `WatermarkInfo` 接口包含8个固定字段：

```typescript
export interface WatermarkInfo {
  timestamp: string;      // 拍摄时间（实时更新）
  weather?: string;      // 天气信息（默认：晴朗）
  location?: string;      // 位置信息（默认：北京市朝阳区）
  altitude?: string;     // 海拔高度（默认：50米）
  direction?: string;    // 方向信息（默认：北偏东30度）
  longitude?: string;    // 经度（默认：116.4074°）
  latitude?: string;     // 纬度（默认：39.9042°）
  organization?: string; // 制作单位（支持编辑，可持久化保存）
}
```

### 2. 固定UI布局特征

根据 `WatermarkOverlay.ets` 的实现，水印UI具有以下固定特征：

- **主题风格**：应急消防主题，蓝色调设计
- **旋转布局**：整个水印区域旋转90度，以左下角为轴心
- **缩放比例**：整体缩放到80%大小
- **背景样式**：白色背景，70%透明度，带阴影效果
- **位置固定**：左上角对齐，通过transform实现特殊旋转效果
- **Logo显示**：包含应急消防logo（60x46.48px）

### 3. 固定内容结构

水印内容分为8行固定格式：
1. **标题行**：应急消防logo + 标题文字
2. **拍摄时间**：实时更新的时间戳
3. **天气信息**：天气状况
4. **位置信息**：地理位置
5. **海拔信息**：海拔高度
6. **方位信息**：方向角度
7. **经度信息**：经度坐标
8. **纬度信息**：纬度坐标
9. **制作单位**：可编辑的单位名称（双击编辑）

### 4. 交互功能（已固定）

- **时间更新**：每秒自动更新时间戳
- **单位编辑**：双击制作单位行弹出编辑对话框
- **数据持久化**：制作单位信息通过preferences保存
- **对话框样式**：居中显示的模态对话框

## 照片叠加水印实现方案

### 1. 核心思路

由于水印UI已完全固定，实现照片叠加需要：
1. 在 `PhotoManager.ets` 中创建与UI完全一致的水印绘制逻辑
2. 保持相同的旋转角度（90度）、缩放比例（80%）和透明度
3. 使用相同的颜色方案和字体样式
4. 确保叠加后的水印与预览时视觉效果一致

### 2. 照片处理流程

当前照片拍摄流程：
1. `Index.ets` 中的拍照按钮触发拍照
2. `PhotoManager.ets` 处理照片拍摄
3. `ImageReceiverManager.ets` 接收图像数据
4. **新增**：将固定样式的水印叠加到照片上
5. 保存带水印的最终照片

## 关键实现步骤

### 步骤1：分析固定水印样式参数

根据 `WatermarkOverlay.ets` 提取关键样式参数：

```typescript
// 固定样式参数
const WATERMARK_ROTATION = 90;           // 旋转角度
const WATERMARK_SCALE = 0.8;             // 缩放比例
const WATERMARK_OPACITY = 0.7;           // 背景透明度
const WATERMARK_BACKGROUND = 'rgba(255, 255, 255, 0.7)'; // 背景色
const WATERMARK_TITLE_BG = 'rgba(0, 87, 217, 0.5)';      // 标题背景色
const WATERMARK_ORG_BG = 'rgba(0, 87, 217, 0.5)';      // 单位背景色
const WATERMARK_SHADOW = {
  radius: 6,
  color: 'rgba(0, 0, 0, 0.3)',
  offsetX: 0,
  offsetY: 3
};
```

### 步骤2：在PhotoManager中实现固定水印绘制

```typescript
// PhotoManager.ets 添加固定水印绘制方法
import { image } from '@kit.ImageKit';
import drawing from '@ohos.drawing';

async addFixedWatermarkToPhoto(
  pixelMap: PixelMap, 
  watermarkInfo: WatermarkInfo
): Promise<PixelMap> {
  try {
    // 获取原图信息
    const imageInfo = await pixelMap.getImageInfo();
    const width = imageInfo.size.width;
    const height = imageInfo.size.height;
    
    // 创建画布（与原图相同尺寸）
    const canvas = new drawing.Canvas();
    const bitmap = drawing.Bitmap.createBitmap(width, height, drawing.ColorType.RGBA_8888);
    canvas.drawBitmap(bitmap, 0, 0);
    
    // 1. 先绘制原图
    canvas.drawPixelMap(pixelMap, 0, 0);
    
    // 2. 创建旋转后的水印区域
    canvas.save();
    
    // 应用变换：旋转90度 + 缩放80% + 移动到左上角
    canvas.rotate(WATERMARK_ROTATION, 0, height); // 左下角为旋转中心
    canvas.scale(WATERMARK_SCALE, WATERMARK_SCALE, 0, height);
    
    // 3. 绘制固定水印内容（8行结构）
    this.drawFixedWatermarkContent(canvas, watermarkInfo);
    
    canvas.restore();
    
    // 4. 生成新的PixelMap
    return this.canvasToPixelMap(canvas, width, height);
    
  } catch (error) {
    Logger.error('PhotoManager', `Fixed watermark failed: ${error}`);
    return pixelMap; // 失败时返回原图
  }
}

private drawFixedWatermarkContent(
  canvas: drawing.Canvas, 
  info: WatermarkInfo
): void {
  const paint = new drawing.Paint();
  
  // 设置字体
  const font = new drawing.Font();
  font.setSize(12);
  paint.setFont(font);
  
  // 1. 绘制标题行背景
  paint.setColor(WATERMARK_TITLE_BG);
  canvas.drawRect(0, 0, 200, 30, paint);
  
  // 2. 绘制标题文字
  paint.setColor('#FFFFFF');
  canvas.drawText('应急消防', 70, 20, paint);
  
  // 3. 绘制白色背景区域（70%透明）
  paint.setColor(WATERMARK_BACKGROUND);
  canvas.drawRect(0, 30, 200, 250, paint);
  
  // 4. 绘制8行信息（黑色文字）
  paint.setColor('#000000');
  const lineHeight = 15;
  const startY = 45;
  
  const lines = [
    `拍摄时间：${info.timestamp}`,
    `天气：${info.weather || '晴朗'}`,
    `位置：${info.location || '北京市朝阳区'}`,
    `海拔：${info.altitude || '50米'}`,
    `方向：${info.direction || '北偏东30度'}`,
    `经度：${info.longitude || '116.4074°'}`,
    `纬度：${info.latitude || '39.9042°'}`,
    `制作单位：${info.organization || '消防救援支队'}`
  ];
  
  lines.forEach((line, index) => {
    canvas.drawText(line, 10, startY + index * lineHeight, paint);
  });
  
  // 5. 绘制阴影效果
  this.drawShadowEffect(canvas);
}
```

### 步骤3：集成到Index.ets拍照流程

```typescript
// 在 Index.ets 中添加水印开关状态
@State private isWatermarkVisible: boolean = true;
@State private watermarkInfo: WatermarkInfo = {
  timestamp: this.getCurrentTimestamp(),
  weather: '晴朗',
  location: '北京市朝阳区', 
  altitude: '50米',
  direction: '北偏东30度',
  longitude: '116.4074°',
  latitude: '39.9042°',
  organization: '消防救援支队'
};

// 修改拍照处理逻辑
async onPhotoCapture(pixelMap: PixelMap) {
  try {
    let finalPixelMap = pixelMap;
    
    // 如果启用水印，添加固定样式水印
    if (this.isWatermarkVisible) {
      finalPixelMap = await this.photoManager.addFixedWatermarkToPhoto(
        pixelMap,
        this.watermarkInfo
      );
    }
    
    // 保存最终照片（带或不带水印）
    await this.photoManager.savePhoto(finalPixelMap);
    
    // 显示预览
    this.previewImage = finalPixelMap;
    this.isPreviewImageVisible = true;
    
  } catch (error) {
    Logger.error('Index', `Photo capture failed: ${error}`);
  }
}

// 更新时间戳（每秒更新，与WatermarkOverlay同步）
private updateWatermarkTimestamp() {
  setInterval(() => {
    this.watermarkInfo.timestamp = this.getCurrentTimestamp();
  }, 1000);
}
```

### 步骤4：同步水印数据

确保 `Index.ets` 和 `WatermarkOverlay.ets` 使用相同的水印数据：

```typescript
// 在 Index.ets 中同步水印信息
@Link @Watch('onWatermarkInfoChange') watermarkInfo: WatermarkInfo;

onWatermarkInfoChange() {
  // 当水印信息变化时更新拍照用的数据
  this.photoManager.updateWatermarkData(this.watermarkInfo);
}

// 在拍照前同步最新的组织单位信息
async syncOrganizationData() {
  try {
    const prefs = await preferences.getPreferences(getContext(this), 'watermark_prefs');
    const orgName = await prefs.get('organization_name', '消防救援支队') as string;
    this.watermarkInfo.organization = orgName;
  } catch (error) {
    Logger.error('Index', `Sync org data failed: ${error}`);
  }
}
```

## 关键代码修改点

### 1. PhotoManager.ets 完整实现

```typescript
import { image } from '@kit.ImageKit';
import drawing from '@ohos.drawing';

export class PhotoManager {
  // ... 现有代码 ...
  
  // 添加固定水印的核心方法
  async addFixedWatermarkToPhoto(
    pixelMap: PixelMap, 
    watermarkInfo: WatermarkInfo
  ): Promise<PixelMap> {
    return new Promise(async (resolve) => {
      try {
        const imageInfo = await pixelMap.getImageInfo();
        const width = imageInfo.size.width;
        const height = imageInfo.size.height;
        
        // 创建绘制环境
        const canvas = new drawing.Canvas();
        const bitmap = drawing.Bitmap.createBitmap(width, height, drawing.ColorType.RGBA_8888);
        canvas.drawBitmap(bitmap, 0, 0);
        
        // 绘制原图
        canvas.drawPixelMap(pixelMap, 0, 0);
        
        // 保存当前状态
        canvas.save();
        
        // 应用固定变换：旋转90度，缩放80%，左下角为原点
        canvas.translate(0, height); // 移动到左下角
        canvas.rotate(-90, 0, 0);      // 顺时针旋转90度
        canvas.scale(0.8, 0.8, 0, 0);  // 缩放到80%
        
        // 绘制固定样式的水印内容
        this.drawEmergencyWatermark(canvas, watermarkInfo);
        
        // 恢复状态
        canvas.restore();
        
        // 转换回PixelMap
        const newPixelMap = await this.canvasToPixelMap(canvas, width, height);
        resolve(newPixelMap);
        
      } catch (error) {
        Logger.error('PhotoManager', `Watermark failed: ${error}`);
        resolve(pixelMap); // 返回原图
      }
    });
  }
  
  private drawEmergencyWatermark(
    canvas: drawing.Canvas, 
    info: WatermarkInfo
  ): void {
    const paint = new drawing.Paint();
    paint.setAntiAlias(true);
    
    // 绘制标题背景（蓝色半透明）
    paint.setColor('rgba(0, 87, 217, 0.5)');
    canvas.drawRect(0, 0, 200, 30, paint);
    
    // 绘制标题文字（白色）
    paint.setColor('#FFFFFF');
    const titleFont = new drawing.Font();
    titleFont.setSize(14);
    titleFont.setWeight(drawing.FontWeight.BOLD);
    paint.setFont(titleFont);
    canvas.drawText('应急消防', 70, 20, paint);
    
    // 绘制主要内容背景（白色70%透明）
    paint.setColor('rgba(255, 255, 255, 0.7)');
    canvas.drawRect(0, 30, 200, 250, paint);
    
    // 绘制内容文字（黑色）
    paint.setColor('#000000');
    const contentFont = new drawing.Font();
    contentFont.setSize(12);
    paint.setFont(contentFont);
    
    const lines = [
      `拍摄时间：${info.timestamp}`,
      `天气：${info.weather || '晴朗'}`,
      `位置：${info.location || '北京市朝阳区'}`,
      `海拔：${info.altitude || '50米'}`,
      `方向：${info.direction || '北偏东30度'}`,
      `经度：${info.longitude || '116.4074°'}`,
      `纬度：${info.latitude || '39.9042°'}`,
      `制作单位：${info.organization || '消防救援支队'}`
    ];
    
    lines.forEach((line, index) => {
      canvas.drawText(line, 10, 45 + index * 15, paint);
    });
    
    // 绘制制作单位背景（蓝色半透明）
    paint.setColor('rgba(0, 87, 217, 0.5)');
    canvas.drawRect(0, 165, 200, 185, paint);
    
    // 制作单位文字（白色）
    paint.setColor('#FFFFFF');
    canvas.drawText(`制作单位：${info.organization || '消防救援支队'}`, 10, 180, paint);
  }
  
  private canvasToPixelMap(
    canvas: drawing.Canvas, 
    width: number, 
    height: number
  ): Promise<PixelMap> {
    return new Promise((resolve) => {
      // 将canvas内容转换为PixelMap的实现
      // 这里需要根据实际的HarmonyOS API进行实现
      resolve(canvas.getPixelMap());
    });
  }
}
```

### 2. Index.ets 集成修改

```typescript
// 在 Index 组件中添加水印相关状态和方法
@Entry
@Component
struct Index {
  // ... 现有代码 ...
  
  // 水印相关状态
  @State watermarkInfo: WatermarkInfo = {
    timestamp: '',
    weather: '晴朗',
    location: '北京市朝阳区',
    altitude: '50米', 
    direction: '北偏东30度',
    longitude: '116.4074°',
    latitude: '39.9042°',
    organization: '消防救援支队'
  };
  @State isWatermarkVisible: boolean = true;
  
  aboutToAppear() {
    // ... 现有代码 ...
    
    // 初始化水印时间戳
    this.updateWatermarkTimestamp();
    this.syncOrganizationData();
  }
  
  // 拍照处理方法（替换现有方法）
  async capturePhoto() {
    try {
      // 同步最新的组织单位信息
      await this.syncOrganizationData();
      
      // 执行拍照
      const originalPixelMap = await this.photoManager.capturePhoto();
      
      if (this.isWatermarkVisible && originalPixelMap) {
        // 添加固定样式水印
        const watermarkedPixelMap = await this.photoManager.addFixedWatermarkToPhoto(
          originalPixelMap,
          this.watermarkInfo
        );
        
        // 保存带水印的照片
        await this.photoManager.savePhoto(watermarkedPixelMap);
        
        // 显示预览
        this.previewImage = watermarkedPixelMap;
      } else {
        // 保存原图
        await this.photoManager.savePhoto(originalPixelMap);
        this.previewImage = originalPixelMap;
      }
      
      this.isPreviewImageVisible = true;
      showToast('拍照成功');
      
    } catch (error) {
      Logger.error('Index', `Photo capture failed: ${error}`);
      showToast('拍照失败');
    }
  }
  
  // 同步组织单位数据
  private async syncOrganizationData() {
    try {
      const prefs = await preferences.getPreferences(getContext(this), 'watermark_prefs');
      const orgName = await prefs.get('organization_name', '消防救援支队') as string;
      this.watermarkInfo.organization = orgName;
    } catch (error) {
      Logger.error('Index', `Sync org data failed: ${error}`);
    }
  }
  
  // 更新时间戳
  private updateWatermarkTimestamp() {
    // 立即更新一次
    this.watermarkInfo.timestamp = this.getCurrentTimestamp();
    
    // 每秒更新（与WatermarkOverlay同步）
    setInterval(() => {
      this.watermarkInfo.timestamp = this.getCurrentTimestamp();
    }, 1000);
  }
  
  private getCurrentTimestamp(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }
}
```

## 测试验证

### 功能测试清单
- [ ] 拍照时正确叠加固定样式水印
- [ ] 水印包含完整的8行信息
- [ ] 旋转90度效果正确实现
- [ ] 80%缩放比例正确应用
- [ ] 时间戳与预览界面同步更新
- [ ] 组织单位信息正确同步
- [ ] 水印开关功能正常
- [ ] 异常情况下返回原图

### 视觉效果验证
- [ ] 水印颜色与预览一致（蓝色标题+白色内容）
- [ ] 透明度效果正确（70%背景透明度）
- [ ] 阴影效果与预览一致
- [ ] 字体大小和样式匹配
- [ ] 整体布局与预览界面一致

### 性能考虑
- 水印绘制应在主线程快速完成
- 避免影响拍照响应速度（<100ms）
- 内存使用优化，及时释放临时对象
- 异常处理确保不会导致拍照失败

## 注意事项

1. **固定样式不可修改**：由于UI已固定，照片叠加必须保持完全一致的视觉效果
2. **时间同步**：确保拍照时的时间戳与预览界面同步
3. **数据一致性**：组织单位信息需要与WatermarkOverlay.ets保持同步
4. **异常处理**：水印处理失败时必须返回原图，不能影响正常拍照
5. **性能要求**：水印处理必须在拍照完成后立即进行，不能有明显延迟
6. **资源管理**：正确管理Canvas和Paint对象，避免内存泄漏

通过以上方案，可以在保持固定水印UI样式的同时，实现照片叠加水印的完整功能。

