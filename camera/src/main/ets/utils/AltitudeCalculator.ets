/**
 * 海拔计算工具类
 * 提供基于气压传感器数据的海拔计算功能和统一的海拔原始数据服务
 */
import sensor from '@ohos.sensor';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'AltitudeCalculator';

// 海拔数据源类型
export enum AltitudeDataSource {
  PRESSURE_SENSOR = 'pressure_sensor',  // 气压传感器
  GPS_LOCATION = 'gps_location',        // GPS定位
  MANUAL_INPUT = 'manual_input'         // 手动输入
}

// 海拔数据接口
export interface AltitudeData {
  value: number;                        // 海拔值（米）
  source: AltitudeDataSource;          // 数据源
  accuracy?: number;                   // 精度（米）
  timestamp: number;                   // 时间戳
  rawPressure?: number;                // 原始气压值（如果来源于气压传感器）
}

export class AltitudeCalculator {
  private static instance: AltitudeCalculator;
  
  // 标准大气压（hPa）
  private static readonly STANDARD_PRESSURE = 1013.25;
  
  // 海拔计算常数
  private static readonly ALTITUDE_CONSTANT = 44330;
  private static readonly PRESSURE_EXPONENT = 0.1903;
  
  // 传感器数据
  private currentPressure: number = 0;
  private pressureSensorSubscribed: boolean = false;
  private pressureCallback: (data: sensor.BarometerResponse) => void = () => {};
  
  // 海拔数据缓存
  private cachedAltitudeData: AltitudeData | null = null;
  private cacheTimeout: number = 5000; // 5秒缓存
  
  private constructor() {
    // 私有构造函数，确保单例模式
  }

  /**
   * 获取AltitudeCalculator实例
   */
  public static getInstance(): AltitudeCalculator {
    if (!AltitudeCalculator.instance) {
      AltitudeCalculator.instance = new AltitudeCalculator();
    }
    return AltitudeCalculator.instance;
  }

  /**
   * 初始化海拔计算器（启动气压传感器）
   */
  public async initialize(): Promise<void> {
    try {
      await this.startPressureSensor();
      hilog.info(DOMAIN, TAG, 'AltitudeCalculator初始化成功');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `AltitudeCalculator初始化失败: ${String(error)}`);
      throw new Error(`AltitudeCalculator初始化失败: ${String(error)}`);
    }
  }

  /**
   * 启动气压传感器
   */
  private async startPressureSensor(): Promise<void> {
    if (this.pressureSensorSubscribed) {
      return;
    }

    try {
      sensor.on(sensor.SensorId.BAROMETER, (data: sensor.BarometerResponse) => {
        this.currentPressure = data.pressure || 0;
        this.updateCachedAltitudeFromPressure();
        if (this.pressureCallback) {
          this.pressureCallback(data);
        }
      });
      this.pressureSensorSubscribed = true;
      hilog.info(DOMAIN, TAG, '气压传感器启动成功');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `气压传感器启动失败: ${String(error)}`);
      throw new Error(`气压传感器启动失败: ${String(error)}`);
    }
  }

  /**
   * 停止气压传感器
   */
  public stopPressureSensor(): void {
    if (this.pressureSensorSubscribed) {
      try {
        sensor.off(sensor.SensorId.BAROMETER, this.pressureCallback);
        this.pressureSensorSubscribed = false;
        this.pressureCallback = () => {};
        hilog.info(DOMAIN, TAG, '气压传感器已停止');
      } catch (error) {
        hilog.error(DOMAIN, TAG, `停止气压传感器失败: ${String(error)}`);
      }
    }
  }

  /**
   * 设置气压传感器数据回调
   */
  public setPressureCallback(callback: (data: sensor.BarometerResponse) => void): void {
    this.pressureCallback = callback;
  }

  /**
   * 获取当前气压值
   */
  public getCurrentPressure(): number {
    return this.currentPressure;
  }

  /**
   * 获取当前海拔数据（优先使用缓存的气压传感器数据）
   */
  public getCurrentAltitudeData(): AltitudeData | null {
    // 检查缓存是否有效
    if (this.cachedAltitudeData && 
        (Date.now() - this.cachedAltitudeData.timestamp) < this.cacheTimeout) {
      return this.cachedAltitudeData;
    }

    // 如果有气压数据，计算海拔
    if (this.currentPressure > 0) {
      const altitude = this.calculateAltitudeFromPressure(this.currentPressure);
      if (altitude !== null) {
        this.cachedAltitudeData = {
          value: altitude,
          source: AltitudeDataSource.PRESSURE_SENSOR,
          accuracy: 10, // 气压传感器精度约10米
          timestamp: Date.now(),
          rawPressure: this.currentPressure
        };
        return this.cachedAltitudeData;
      }
    }

    return null;
  }

  /**
   * 更新缓存的海拔数据（基于气压）
   */
  private updateCachedAltitudeFromPressure(): void {
    if (this.currentPressure > 0) {
      const altitude = this.calculateAltitudeFromPressure(this.currentPressure);
      if (altitude !== null) {
        this.cachedAltitudeData = {
          value: altitude,
          source: AltitudeDataSource.PRESSURE_SENSOR,
          accuracy: 10,
          timestamp: Date.now(),
          rawPressure: this.currentPressure
        };
      }
    }
  }

  /**
   * 设置GPS海拔数据
   */
  public setGpsAltitude(altitude: number, accuracy?: number): AltitudeData {
    const altitudeData: AltitudeData = {
      value: altitude,
      source: AltitudeDataSource.GPS_LOCATION,
      accuracy: accuracy || 20, // GPS海拔精度约20米
      timestamp: Date.now()
    };
    
    // 如果没有气压传感器数据，使用GPS数据作为缓存
    if (!this.cachedAltitudeData || this.cachedAltitudeData.source !== AltitudeDataSource.PRESSURE_SENSOR) {
      this.cachedAltitudeData = altitudeData;
    }
    
    return altitudeData;
  }

  /**
   * 获取最佳海拔数据（优先级：气压传感器 > GPS > 缓存）
   */
  public getBestAltitudeData(gpsAltitude?: number, gpsAccuracy?: number): AltitudeData | null {
    // 优先使用气压传感器数据
    const currentData = this.getCurrentAltitudeData();
    if (currentData && currentData.source === AltitudeDataSource.PRESSURE_SENSOR) {
      return currentData;
    }

    // 其次使用GPS数据
    if (gpsAltitude !== null && gpsAltitude !== undefined && AltitudeCalculator.isValidAltitude(gpsAltitude)) {
      return this.setGpsAltitude(gpsAltitude, gpsAccuracy);
    }

    // 最后使用缓存数据
    return this.cachedAltitudeData;
  }
  
  /**
   * 基于气压计算海拔高度
   * @param pressure 气压值（hPa）
   * @returns 海拔高度（米），如果气压无效则返回null
   */
  public calculateAltitudeFromPressure(pressure: number | null | undefined): number | null {
    // 验证气压数据有效性
    if (!AltitudeCalculator.isValidPressure(pressure)) {
      return null;
    }
    
    try {
      // 使用标准大气压公式计算海拔
      const altitude = AltitudeCalculator.ALTITUDE_CONSTANT * (1 - Math.pow(pressure! / AltitudeCalculator.STANDARD_PRESSURE, AltitudeCalculator.PRESSURE_EXPONENT));
      
      // 验证计算结果的合理性
      if (!AltitudeCalculator.isValidAltitude(altitude)) {
        return null;
      }
      
      return altitude;
    } catch (error) {
      console.error('海拔计算失败:', error);
      return null;
    }
  }
  
  /**
   * 格式化海拔数据为显示字符串
   * @param altitude 海拔值（米）
   * @param precision 小数位数，默认为1位
   * @returns 格式化的海拔字符串
   */
  public formatAltitude(altitude: number | null | undefined, precision: number = 1): string {
    if (!AltitudeCalculator.isValidAltitude(altitude)) {
      return '海拔获取失败';
    }
    
    try {
      return `${altitude!.toFixed(precision)}米`;
    } catch (error) {
      console.error('海拔格式化失败:', error);
      return '海拔获取失败';
    }
  }
  
  /**
   * 基于气压计算并格式化海拔数据
   * @param pressure 气压值（hPa）
   * @param precision 小数位数，默认为1位
   * @returns 格式化的海拔字符串
   */
  public calculateAndFormatAltitude(pressure: number | null | undefined, precision: number = 1): string {
    const altitude = this.calculateAltitudeFromPressure(pressure);
    return this.formatAltitude(altitude, precision);
  }

  /**
   * 静态方法：基于气压计算海拔高度（向后兼容）
   */
  static calculateAltitudeFromPressure(pressure: number | null | undefined): number | null {
    return AltitudeCalculator.getInstance().calculateAltitudeFromPressure(pressure);
  }

  /**
   * 静态方法：格式化海拔数据（向后兼容）
   */
  static formatAltitude(altitude: number | null | undefined, precision: number = 1): string {
    return AltitudeCalculator.getInstance().formatAltitude(altitude, precision);
  }

  /**
   * 静态方法：基于气压计算并格式化海拔数据（向后兼容）
   */
  static calculateAndFormatAltitude(pressure: number | null | undefined, precision: number = 1): string {
    return AltitudeCalculator.getInstance().calculateAndFormatAltitude(pressure, precision);
  }
  
  /**
   * 验证气压数据的有效性
   * @param pressure 气压值
   * @returns 是否为有效气压
   */
  private static isValidPressure(pressure: number | null | undefined): boolean {
    if (pressure === null || pressure === undefined) {
      return false;
    }
    
    if (typeof pressure !== 'number' || isNaN(pressure)) {
      return false;
    }
    
    // 气压合理范围：300-1100 hPa（覆盖地球上所有可能的气压值）
    return pressure > 300 && pressure < 1100;
  }
  
  /**
   * 验证海拔数据的有效性
   * @param altitude 海拔值
   * @returns 是否为有效海拔
   */
  private static isValidAltitude(altitude: number | null | undefined): boolean {
    if (altitude === null || altitude === undefined) {
      return false;
    }
    
    if (typeof altitude !== 'number' || isNaN(altitude)) {
      return false;
    }
    
    // 海拔合理范围：-500米到20000米（覆盖死海到珠峰及高空飞行）
    return altitude > -500 && altitude < 20000;
  }
}