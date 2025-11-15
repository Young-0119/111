import common from '@ohos.app.ability.common';

/**
 * 罗盘主组件
 * 实现了一个可视化的罗盘界面，包含方向指示、刻度线和角度标记
 * 支持目标指示器和动态颜色变化
 */
@Component
export struct CompassMain {
  @Prop @Watch('onDataChanged') targetAzimuth: number = 0;
  @Prop @Watch('onDataChanged') deviceDirection: number = 0; // 当前设备方向
  @Prop @Watch('onDataChanged') satelliteName: string = '亚太6C/6D'; // 卫星名称

  @State private canvasWidth: number = 0;
  @State private canvasHeight: number = 0;
  @State private compassRadius: number = 0;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private canvasContext: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  
  // 性能优化相关
  private staticContentCached: boolean = false;
  private lastDeviceDirection: number = -999; // 用于检测方向变化
  
  // 常量定义
  private readonly COMPASS_RADIUS_RATIO: number =0.8;
  private readonly TICK_INTERVAL_MINOR: number = 2; // 小刻度间隔
  private readonly TICK_INTERVAL_MAJOR: number = 10; // 大刻度间隔
  private readonly SPECIAL_ANGLES: number[] = [30, 60, 120, 150, 210, 240, 300, 330];
  private readonly CARDINAL_DIRECTIONS: string[] = ['北', '东', '南', '西'];
  
  build() {
    Stack() {
      Canvas(this.canvasContext)
        .width('100%')
        .height('100%')
        .onReady(() => {
          // 设置画布尺寸
          this.canvasWidth = 300;
          this.canvasHeight = 300;
          
          // 计算罗盘半径
          this.compassRadius = Math.min(this.canvasWidth, this.canvasHeight) / 2 * this.COMPASS_RADIUS_RATIO;
          
          // 初始化离屏Canvas
          this.initOffscreenCanvas();
          
          // 绘制罗盘
          this.drawCompass();
        })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 初始化性能优化
   */
  private initOffscreenCanvas(): void {
    this.staticContentCached = false;
    this.lastDeviceDirection = -999;
    console.info('性能优化初始化完成');
  }



  /**
   * 绘制罗盘 - 性能优化版本
   */
  private drawCompass(): void {
    if (!this.canvasContext) {
      return;
    }
    
    const ctx = this.canvasContext;
    const centerX = this.canvasWidth / 2;
    const centerY = this.canvasHeight / 2;
    
    // 检查是否需要重绘（方向变化超过阈值）
    const directionChanged = Math.abs(this.deviceDirection - this.lastDeviceDirection) > 0.5;
    
    if (directionChanged || !this.staticContentCached) {
      // 清空画布
      ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
      
      // 绘制旋转的静态内容
      ctx.save();
      ctx.translate(centerX, centerY);
      ctx.rotate(-this.deviceDirection * Math.PI / 180);
      this.drawColorRing(ctx, 0, 0);
      ctx.restore();
      
      // 绘制动态内容（目标指示器）
      ctx.save();
      ctx.translate(centerX, centerY);
      ctx.rotate(-this.deviceDirection * Math.PI / 180);
      this.drawTargetIndicator(ctx, 0, 0);
      ctx.restore();
      
      // 绘制固定的垂直指示线（不随罗盘旋转）
      this.drawFixedIndicator(ctx, centerX, centerY);
      
      // 更新缓存状态
      this.lastDeviceDirection = this.deviceDirection;
      this.staticContentCached = true;
    }
  }

  /**
   * 绘制彩色圆环和刻度
   */
  private drawColorRing(ctx: CanvasRenderingContext2D, x: number, y: number): void {
    const radius = this.compassRadius;
    const ringWidth = radius * 0.15;
    
    // 不绘制背景圆，保持透明
    // ctx.beginPath();
    // ctx.arc(x, y, radius, 0, 2 * Math.PI);
    // ctx.fillStyle = '#1a1a1a';
    // ctx.fill();
    
    // 绘制外圆轮廓（透明）
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, 2 * Math.PI);
    ctx.strokeStyle = 'transparent';
    ctx.lineWidth = 2;
    ctx.stroke();
    
    // 绘制小刻度线 - 每2度绘制一条
    for (let i = 0; i < 360; i += this.TICK_INTERVAL_MINOR) {
      const angle = (i - 90) * Math.PI / 180;
      let lineLength = radius * -0.07;
      let lineWidth = 1.5;
      
      if (i % this.TICK_INTERVAL_MAJOR === 0) {
        lineLength = radius * -0.1; // 主刻度线更长
      }
      
      const startX = x + (radius + ringWidth/2*3) * Math.cos(angle);
      const startY = y + (radius + ringWidth/2*3) * Math.sin(angle);
      const endX = x + (radius + ringWidth/2*3 + lineLength) * Math.cos(angle);
      const endY = y + (radius + ringWidth/2*3 + lineLength) * Math.sin(angle);
      
      ctx.beginPath();
      ctx.moveTo(startX, startY);
      ctx.lineTo(endX, endY);
      ctx.strokeStyle = '#9E9A9A';
      ctx.lineWidth = lineWidth;
      ctx.stroke();
    }
    
    // 绘制橙红色圆环
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, 2 * Math.PI);
    ctx.lineWidth = ringWidth;
    ctx.strokeStyle = '#FF3B30';
    ctx.stroke();
    
    // 绘制主刻度线和标记
    this.drawMajorTicksAndLabels(ctx, x, y, radius, ringWidth);
  }

  /**
   * 绘制主刻度线和标记
   */
  private drawMajorTicksAndLabels(ctx: CanvasRenderingContext2D, x: number, y: number, radius: number, ringWidth: number): void {
    // 每10度绘制一条刻度线或角度文本
    for (let i = 0; i < 360; i += this.TICK_INTERVAL_MAJOR) {
      const angle = (i - 90) * Math.PI / 180;
      
      // 检查是否为需要显示文本的角度
      if (this.SPECIAL_ANGLES.includes(i)) {
        // 绘制角度文本（在圆环中间）
        const textRadius = radius;
        const textX = x + textRadius * Math.cos(angle);
        const textY = y + textRadius * Math.sin(angle);
        
        ctx.save();
        ctx.translate(textX, textY);
        ctx.rotate(angle + Math.PI/2); // 调整文本方向
        ctx.font = '50px Arial';
        ctx.fillStyle = '#FFFFFF';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        
        // 逐个字符绘制，实现弯曲效果
        const text = `${i}`;
        for (let j = 0; j < text.length; j++) {
          const char = text[j];
          const charOffset = (j - (text.length-1)/2) * 8; // 字符间距
          ctx.fillText(char, charOffset, 0);
        }
        
        ctx.restore();
      } else {
        this.drawMajorTick(ctx, x, y, radius, ringWidth, angle, i);
      }
    }
  }

  /**
   * 绘制固定指示器
   */
  private drawFixedIndicator(ctx: CanvasRenderingContext2D, centerX: number, centerY: number): void {
    const radius = this.compassRadius;
    const ringWidth = radius * 0.15;
    
    ctx.save();
    ctx.translate(centerX, centerY);
    
    // 绘制固定的垂直线段（不随罗盘旋转）
    ctx.beginPath();
    ctx.moveTo(0, -1.1*radius); // 顶部位置
    ctx.lineTo(0, -1.25*radius); // 向上延伸
    ctx.strokeStyle = '#FFFFFF'; // 白色线段
    ctx.lineWidth = 3;
    ctx.lineCap = 'round';
    ctx.stroke();
    
    ctx.restore();
  }

  /**
   * 绘制主刻度线
   */
  private drawMajorTick(ctx: CanvasRenderingContext2D, x: number, y: number, radius: number, ringWidth: number, angle: number, degree: number): void {
    // 绘制普通刻度线
    const innerRadius = radius - ringWidth/4;  // 内环半径
    const outerRadius = radius + ringWidth/4;  // 外环半径
    
    const startX = x + innerRadius * Math.cos(angle);
    const startY = y + innerRadius * Math.sin(angle);
    const endX = x + outerRadius * Math.cos(angle);
    const endY = y + outerRadius * Math.sin(angle);
    
    ctx.beginPath();
    ctx.moveTo(startX, startY);
    ctx.lineTo(endX, endY);
    ctx.lineCap = 'round';
    
    // 特殊角度(0,90,180,270度)使用黑色加粗刻度线&绘制方向文字
    if ([0, 90, 180, 270].includes(degree)) {
      // 黑色加粗刻度线
      ctx.strokeStyle = '#000000';
      ctx.lineWidth = 4;
      
      // 绘制方向文字
      const textX = x + Math.cos(angle) * radius * 0.55;
      const textY = y + Math.sin(angle) * radius * 0.55;
      ctx.font = '50px Arial';
      ctx.fillStyle = '#FFFFFF';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.save();
      ctx.translate(textX, textY);
      ctx.rotate(angle + Math.PI/2); // 旋转文字使其沿圆周方向
      ctx.fillText(this.CARDINAL_DIRECTIONS[degree/90], 0, 0);
      ctx.restore();
      
      // 只在北方向(0度)绘制箭头
      if (degree === 0) {
        ctx.stroke();
        this.drawNorthArrow(ctx, x, y, radius, angle);
      } else {
        ctx.stroke();
      }
    } else {
      // 普通刻度线
      ctx.strokeStyle = '#9E9A9A';
      ctx.lineWidth = 2.5;
      ctx.stroke();
    }
  }

  /**
   * 绘制目标指示器
   */
  private drawTargetIndicator(ctx: CanvasRenderingContext2D, centerX: number, centerY: number): void {
    // 计算目标方位角（相对于当前方向）
    const relativeAngle = this.targetAzimuth;
    const angle = (relativeAngle - 90) * Math.PI / 180;
    
    const radius = this.compassRadius;
    const arrowSize = 8;
    
    // 计算箭头位置
    const arrowRadius = 0.75 * radius;
    const arrowX = centerX + Math.cos(angle) * arrowRadius;
    const arrowY = centerY + Math.sin(angle) * arrowRadius;
    
    ctx.save();
    ctx.translate(arrowX, arrowY);
    ctx.rotate(angle + Math.PI * 2.5);
    const directionDiff = (this.targetAzimuth - this.deviceDirection + 360) % 360;
    const tolerance = 5;
    ctx.font = '60px Arial';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText('🛰', 0, 0);
    ctx.save();
    ctx.rotate(Math.PI/2);
    ctx.font = '40px Arial';
    ctx.fillStyle = '#FFFFFF';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(this.satelliteName, arrowSize * 1.5, 0);
    ctx.restore();
    ctx.restore();
  }

  /**
   * 绘制北方向箭头
   */
  private drawNorthArrow(ctx: CanvasRenderingContext2D, centerX: number, centerY: number, radius: number, angle: number): void {
    const arrowSize = 8;
    const arrowRadius = radius * 0.75;
    const arrowX = centerX + Math.cos(angle) * arrowRadius;
    const arrowY = centerY + Math.sin(angle) * arrowRadius;

    ctx.save();
    ctx.translate(arrowX, arrowY);
    ctx.rotate(angle + Math.PI / 2);

    ctx.beginPath();
    ctx.moveTo(0, -arrowSize * 1.5);
    ctx.lineTo(-arrowSize, arrowSize * 0.5);
    ctx.lineTo(arrowSize, arrowSize * 0.5);
    ctx.closePath();

    ctx.fillStyle = '#FF3B30';
    ctx.fill();
    ctx.restore();
  }
  
  /**
   * 数据变化时的回调
   */
  onDataChanged(): void {
    if (this.canvasContext && this.compassRadius > 0) {
      // 当设备方向或目标方位角变化时，只需重绘动态内容
      // 静态内容（罗盘圆环和刻度）保持缓存状态
      this.drawCompass();
    }
  }


}
