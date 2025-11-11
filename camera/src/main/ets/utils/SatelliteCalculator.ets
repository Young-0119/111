

// 定义角度计算结果接口
interface SatelliteAngles {
  azimuth: number;
  elevation: number;
  polarization: number;
}

/**
 * 卫星角度计算器
 * 用于计算卫星的方位角、俯仰角和极化角
 */
export class SatelliteCalculator {
  private static instance: SatelliteCalculator;
  private locationService: LocationService;
  
  // 亚太6C卫星的经度（东经134度）
  private readonly SATELLITE_LONGITUDE: number = 134.0;
  
  private constructor() {
    // 私有构造函数，确保单例模式
    this.locationService = new LocationService();
  }
  
  /**
   * 获取SatelliteCalculator实例
   */
  public static getInstance(): SatelliteCalculator {
    if (!SatelliteCalculator.instance) {
      SatelliteCalculator.instance = new SatelliteCalculator();
    }
    return SatelliteCalculator.instance;
  }
  
  /**
   * 计算方位角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @returns 方位角（度）
   */
  public calculateAzimuth(userLongitude: number, userLatitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(this.SATELLITE_LONGITUDE);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 计算方位角
    let azimuth = Math.atan2(Math.sin(longDiff), Math.cos(userLatRad) * Math.tan(0) - Math.sin(userLatRad) * Math.cos(longDiff));
    
    // 转换为度数并确保在0-360范围内
    azimuth = this.radToDeg(azimuth);
    if (azimuth < 0) {
      azimuth += 360;
    }
    
    return azimuth;
  }
  
  /**
   * 计算俯仰角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @returns 俯仰角（度）
   */
  public calculateElevation(userLongitude: number, userLatitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(this.SATELLITE_LONGITUDE);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 地球半径（千米）
    const earthRadius = 6378.0;
    // 地球同步轨道高度（千米）
    const geoHeight = 35786.0;
    
    // 计算俯仰角
    const r = (earthRadius + geoHeight) / earthRadius;
    const d = r * Math.cos(userLatRad) * Math.cos(longDiff) - 1;
    const e = r * Math.sin(userLatRad);
    const f = Math.sqrt(d * d + e * e + 1 - 2 * e * Math.sin(userLatRad) - 2 * d * Math.cos(userLatRad) * Math.cos(longDiff));
    
    let elevation = Math.atan2(r * Math.sin(userLatRad) - 1, r * Math.cos(userLatRad) * Math.cos(longDiff));
    elevation = this.radToDeg(elevation);
    
    return elevation;
  }
  
  /**
   * 计算极化角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @returns 极化角（度）
   */
  public calculatePolarization(userLongitude: number, userLatitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(this.SATELLITE_LONGITUDE);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 计算极化角
    let polarization = Math.atan(Math.tan(longDiff) / Math.sin(userLatRad));
    polarization = this.radToDeg(polarization);
    
    // 调整极化角范围
    if (userLatitude < 0) {
      polarization = 180 - polarization;
    }
    
    return polarization;
  }
  
  /**
   * 自动获取当前位置并计算方位角
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<number | null> 方位角（度），如果定位失败返回null
   */
  public async calculateAzimuthFromCurrentLocation(satelliteLongitude?: number): Promise<number | null> {
    const snapshot = this.locationService.getCurrentLocation();
    if (snapshot) {
      const satLong = satelliteLongitude || this.SATELLITE_LONGITUDE;
      return this.calculateAzimuthWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
    }
    return null;
  }
  
  /**
   * 自动获取当前位置并计算俯仰角
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<number | null> 俯仰角（度），如果定位失败返回null
   */
  public async calculateElevationFromCurrentLocation(satelliteLongitude?: number): Promise<number | null> {
    const snapshot = this.locationService.getCurrentLocation();
    if (snapshot) {
      const satLong = satelliteLongitude || this.SATELLITE_LONGITUDE;
      return this.calculateElevationWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
    }
    return null;
  }
  
  /**
   * 自动获取当前位置并计算极化角
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<number | null> 极化角（度），如果定位失败返回null
   */
  public async calculatePolarizationFromCurrentLocation(satelliteLongitude?: number): Promise<number | null> {
    const snapshot = this.locationService.getCurrentLocation();
    if (snapshot) {
      const satLong = satelliteLongitude || this.SATELLITE_LONGITUDE;
      return this.calculatePolarizationWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
    }
    return null;
  }
  
  /**
   * 自动获取当前位置并计算所有卫星角度
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<{azimuth: number, elevation: number, polarization: number} | null>
   */
  public async calculateAllAnglesFromCurrentLocation(satelliteLongitude?: number): Promise<SatelliteAngles | null> {
    const snapshot = this.locationService.getCurrentLocation();
    if (snapshot) {
      const satLong = satelliteLongitude || this.SATELLITE_LONGITUDE;
      const azimuth = this.calculateAzimuthWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
      const elevation = this.calculateElevationWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
      const polarization = this.calculatePolarizationWithSatellite(Number(snapshot.longitude || 0), Number(snapshot.latitude || 0), satLong);
      const result: SatelliteAngles = { azimuth, elevation, polarization };
      return result;
    }
    return null;
  }
  
  /**
   * 计算指定卫星的方位角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @param satelliteLongitude 卫星经度（度）
   * @returns 方位角（度）
   */
  public calculateAzimuthWithSatellite(userLongitude: number, userLatitude: number, satelliteLongitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 计算方位角
    let azimuth = Math.atan2(Math.sin(longDiff), Math.cos(userLatRad) * Math.tan(0) - Math.sin(userLatRad) * Math.cos(longDiff));
    
    // 转换为度数并确保在0-360范围内
    azimuth = this.radToDeg(azimuth);
    if (azimuth < 0) {
      azimuth += 360;
    }
    
    return azimuth;
  }
  
  /**
   * 计算指定卫星的俯仰角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @param satelliteLongitude 卫星经度（度）
   * @returns 俯仰角（度）
   */
  public calculateElevationWithSatellite(userLongitude: number, userLatitude: number, satelliteLongitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 地球半径（千米）
    const earthRadius = 6378.0;
    // 地球同步轨道高度（千米）
    const geoHeight = 35786.0;
    
    // 计算俯仰角
    const r = (earthRadius + geoHeight) / earthRadius;
    const d = r * Math.cos(userLatRad) * Math.cos(longDiff) - 1;
    const e = r * Math.sin(userLatRad);
    const f = Math.sqrt(d * d + e * e + 1 - 2 * e * Math.sin(userLatRad) - 2 * d * Math.cos(userLatRad) * Math.cos(longDiff));
    
    let elevation = Math.atan2(r * Math.sin(userLatRad) - 1, r * Math.cos(userLatRad) * Math.cos(longDiff));
    elevation = this.radToDeg(elevation);
    
    return elevation;
  }
  
  /**
   * 计算指定卫星的极化角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @param satelliteLongitude 卫星经度（度）
   * @returns 极化角（度）
   */
  public calculatePolarizationWithSatellite(userLongitude: number, userLatitude: number, satelliteLongitude: number): number {
    // 将角度转换为弧度
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    
    // 计算经度差
    const longDiff = satLongRad - userLongRad;
    
    // 计算极化角
    let polarization = Math.atan(Math.tan(longDiff) / Math.sin(userLatRad));
    polarization = this.radToDeg(polarization);
    
    // 调整极化角范围
    if (userLatitude < 0) {
      polarization = 180 - polarization;
    }
    
    return polarization;
  }
  
  /**
   * 度数转弧度
   * @param degrees 角度值（度）
   * @returns 弧度值
   */
  private degToRad(degrees: number): number {
    return degrees * Math.PI / 180.0;
  }
  
  /**
   * 弧度转度数
   * @param radians 弧度值
   * @returns 角度值（度）
   */
  private radToDeg(radians: number): number {
    return radians * 180.0 / Math.PI;
  }
}