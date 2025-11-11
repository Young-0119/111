/**
 * 传感器管理类
 * 用于获取设备的传感器数据和位置信息
 */
import sensor from '@ohos.sensor';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import geoLocationManager from '@ohos.geoLocationManager';

const DOMAIN = 0x0000;
const TAG = 'SensorManager';

export class SensorManager {
  private static instance: SensorManager | null = null;
  private locationService: LocationService;
  private altitudeCalculator: AltitudeCalculator;
  
  // 传感器订阅状态
  private compassSubscribed: boolean = false;
  private orientationSubscribed: boolean = false;
  private barometerSubscribed: boolean = false;
  private compassCallback: (data: sensor.MagneticFieldResponse) => void = () => {};
  private orientationCallback: (data: sensor.OrientationResponse) => void = () => {};
  private barometerCallback: (data: sensor.BarometerResponse) => void = () => {};

  private constructor() {
    // 私有构造函数，确保单例模式
    this.locationService = LocationService.getInstance();
    this.altitudeCalculator = AltitudeCalculator.getInstance();
    hilog.info(DOMAIN, TAG, 'SensorManager initialized with LocationService and AltitudeCalculator');
  }

  /**
   * 获取SensorManager实例
   */
  public static getInstance(): SensorManager {
    if (!SensorManager.instance) {
      SensorManager.instance = new SensorManager();
    }
    return SensorManager.instance;
  }
  
  /**
   * 初始化传感器管理器
   * @param context 应用上下文
   */
  public async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      await this.locationService.initialize(context);
      hilog.info(DOMAIN, TAG, 'SensorManager初始化成功');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `SensorManager初始化失败: ${JSON.stringify(error)}`);
      throw new Error(`SensorManager初始化失败: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 获取当前位置信息
   * @param forceRefresh 是否强制刷新缓存
   * @returns Promise<LocationInfo>
   */
  public async getCurrentLocationInfo(forceRefresh: boolean = false): Promise<LocationInfo> {
    try {
      return await this.locationService.getCurrentLocationInfo(forceRefresh);
    } catch (error) {
      hilog.error(DOMAIN, TAG, `获取位置信息失败: ${JSON.stringify(error)}`);
      throw new Error(`获取位置信息失败: ${JSON.stringify(error)}`);
    }
  }
  
  /**
   * 获取当前位置（兼容旧接口）
   * @returns Promise<geoLocationManager.Location>
   */
  public async getCurrentLocation(): Promise<geoLocationManager.Location> {
    try {
      return await this.locationService.getCurrentLocation();
    } catch (error) {
      hilog.error(DOMAIN, TAG, `获取位置失败: ${JSON.stringify(error)}`);
      throw new Error(`获取位置失败: ${JSON.stringify(error)}`);
    }
  }
  
  /**
   * 格式化位置信息
   */
  public formatLocation(longitude: number, latitude: number): string {
    return this.locationService.formatLocation(longitude, latitude);
  }
  
  /**
   * 格式化海拔信息（使用AltitudeCalculator统一处理）
   */
  public formatAltitude(altitude: number): string {
    return this.altitudeCalculator.formatAltitude(altitude);
  }

  /**
   * 基于气压计算海拔高度
   */
  public calculateAltitudeFromPressure(pressure: number): number | null {
    return this.altitudeCalculator.calculateAltitudeFromPressure(pressure);
  }

  /**
   * 基于气压计算并格式化海拔数据
   */
  public calculateAndFormatAltitude(pressure: number, precision: number = 1): string {
    return this.altitudeCalculator.calculateAndFormatAltitude(pressure, precision);
  }
  
  /**
   * 清除位置缓存
   */
  public clearLocationCache(): void {
    this.locationService.clearCache();
  }

  /**
   * 订阅指南针传感器数据
   * @param callback 数据回调函数
   */
  public subscribeCompass(callback: (data: sensor.MagneticFieldResponse) => void): void {
    if (this.compassSubscribed) {
      this.unsubscribeCompass();
    }

    this.compassCallback = callback;
    try {
      sensor.on(sensor.SensorId.MAGNETIC_FIELD, (data: sensor.MagneticFieldResponse) => {
        if (this.compassCallback) {
          this.compassCallback(data);
        }
      });
      this.compassSubscribed = true;
      hilog.info(DOMAIN, TAG, 'Compass sensor subscribed successfully');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to subscribe compass sensor: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 取消订阅指南针传感器数据
   */
  public unsubscribeCompass(): void {
    if (this.compassSubscribed) {
      try {
        // 取消磁力计订阅
        sensor.off(sensor.SensorId.MAGNETIC_FIELD, this.compassCallback);
        
        // 取消方向传感器订阅
        sensor.off(sensor.SensorId.ORIENTATION, this.orientationCallback);
        this.compassSubscribed = false;
        this.compassCallback = () => {}; 
        hilog.info(DOMAIN, TAG, 'Compass sensor unsubscribed');
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to unsubscribe compass sensor: ${JSON.stringify(error)}`);
      }
    }
  }

  /**
   * 订阅方向传感器数据
   * @param callback 数据回调函数
   */
  public subscribeOrientation(callback: (data: sensor.OrientationResponse) => void): void {
    if (this.orientationSubscribed) {
      this.unsubscribeOrientation();
    }

    this.orientationCallback = callback;
    try {
      sensor.on(sensor.SensorId.ORIENTATION, (data: sensor.OrientationResponse) => {
        if (this.orientationCallback) {
          this.orientationCallback(data);
        }
      });
      this.orientationSubscribed = true;
      hilog.info(DOMAIN, TAG, 'Orientation sensor subscribed successfully');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to subscribe orientation sensor: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 取消订阅方向传感器数据
   */
  public unsubscribeOrientation(): void {
    if (this.orientationSubscribed) {
      try {
        sensor.off(sensor.SensorId.ORIENTATION, this.orientationCallback);
        this.orientationSubscribed = false;
        this.orientationCallback = () => {};
        hilog.info(DOMAIN, TAG, 'Orientation sensor unsubscribed');
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to unsubscribe orientation sensor: ${JSON.stringify(error)}`);
      }
    }
  }

  /**
   * 订阅气压传感器数据
   * @param callback 数据回调函数
   */
  public subscribeBarometer(callback: (data: sensor.BarometerResponse) => void): void {
    if (this.barometerSubscribed) {
      this.unsubscribeBarometer();
    }

    this.barometerCallback = callback;
    try {
      sensor.on(sensor.SensorId.BAROMETER, (data: sensor.BarometerResponse) => {
        if (this.barometerCallback) {
          this.barometerCallback(data);
        }
      });
      this.barometerSubscribed = true;
      hilog.info(DOMAIN, TAG, 'Barometer sensor subscribed successfully');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to subscribe barometer sensor: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 取消订阅气压传感器数据
   */
  public unsubscribeBarometer(): void {
    if (this.barometerSubscribed) {
      try {
        sensor.off(sensor.SensorId.BAROMETER, this.barometerCallback);
        this.barometerSubscribed = false;
        this.barometerCallback = () => {};
        hilog.info(DOMAIN, TAG, 'Barometer sensor unsubscribed');
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to unsubscribe barometer sensor: ${JSON.stringify(error)}`);
      }
    }
  }

  /**
   * 释放所有传感器资源
   */
  public releaseAllSensors(): void {
    this.unsubscribeCompass();
    this.unsubscribeOrientation();
    this.unsubscribeBarometer();
  }
}