

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
  private readonly SATELLITE_LONGITUDE: number = 134.0;
  private lastUserLon?: number;
  private lastUserLat?: number;
  private lastSatLon?: number;
  private lastAngles?: SatelliteAngles;
  private lastTs?: number;
  
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
    return this.calculateAzimuthWithSatellite(userLongitude, userLatitude, this.SATELLITE_LONGITUDE);
  }
  
  /**
   * 计算俯仰角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @returns 俯仰角（度）
   */
  public calculateElevation(userLongitude: number, userLatitude: number): number {
    return this.calculateElevationWithSatellite(userLongitude, userLatitude, this.SATELLITE_LONGITUDE);
  }
  
  /**
   * 计算极化角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @returns 极化角（度）
   */
  public calculatePolarization(userLongitude: number, userLatitude: number): number {
    return this.calculatePolarizationWithSatellite(userLongitude, userLatitude, this.SATELLITE_LONGITUDE);
  }
  
  /**
   * 自动获取当前位置并计算方位角
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<number | null> 方位角（度），如果定位失败返回null
   */
  public calculateAllAnglesWithSatellite(userLongitude: number, userLatitude: number, satelliteLongitude: number): SatelliteAngles {
    const now = Date.now();
    if (
      this.lastAngles &&
      this.lastUserLon === userLongitude &&
      this.lastUserLat === userLatitude &&
      this.lastSatLon === satelliteLongitude &&
      this.lastTs && now - this.lastTs < 200
    ) {
      return this.lastAngles;
    }
    const azimuth = this.calculateAzimuthWithSatellite(userLongitude, userLatitude, satelliteLongitude);
    const elevation = this.calculateElevationWithSatellite(userLongitude, userLatitude, satelliteLongitude);
    const polarization = this.calculatePolarizationWithSatellite(userLongitude, userLatitude, satelliteLongitude);
    const result: SatelliteAngles = { azimuth, elevation, polarization };
    this.lastAngles = result;
    this.lastUserLon = userLongitude;
    this.lastUserLat = userLatitude;
    this.lastSatLon = satelliteLongitude;
    this.lastTs = now;
    return result;
  }
  
  /**
   * 自动获取当前位置并计算俯仰角
   * @param satelliteLongitude 卫星经度（可选，默认使用亚太6C）
   * @returns Promise<number | null> 俯仰角（度），如果定位失败返回null
   */
  
  /**
   * 计算指定卫星的方位角
   * @param userLongitude 用户所在经度（度）
   * @param userLatitude 用户所在纬度（度）
   * @param satelliteLongitude 卫星经度（度）
   * @returns 方位角（度）
   */
  public calculateAzimuthWithSatellite(userLongitude: number, userLatitude: number, satelliteLongitude: number): number {
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    const earthRadius = 6378.0;
    const geoHeight = 35786.0;
    const rSat = earthRadius + geoHeight;
    const xs = earthRadius * Math.cos(userLatRad) * Math.cos(userLongRad);
    const ys = earthRadius * Math.cos(userLatRad) * Math.sin(userLongRad);
    const zs = earthRadius * Math.sin(userLatRad);
    const xg = rSat * Math.cos(satLongRad);
    const yg = rSat * Math.sin(satLongRad);
    const zg = 0;
    const vx = xg - xs;
    const vy = yg - ys;
    const vz = zg - zs;
    const E = -Math.sin(userLongRad) * vx + Math.cos(userLongRad) * vy;
    const N = -Math.sin(userLatRad) * Math.cos(userLongRad) * vx - Math.sin(userLatRad) * Math.sin(userLongRad) * vy + Math.cos(userLatRad) * vz;
    let azimuth = Math.atan2(E, N);
    azimuth = this.radToDeg(azimuth);
    if (azimuth < 0) azimuth += 360;
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
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    const earthRadius = 6378.0;
    const geoHeight = 35786.0;
    const rSat = earthRadius + geoHeight;
    const xs = earthRadius * Math.cos(userLatRad) * Math.cos(userLongRad);
    const ys = earthRadius * Math.cos(userLatRad) * Math.sin(userLongRad);
    const zs = earthRadius * Math.sin(userLatRad);
    const xg = rSat * Math.cos(satLongRad);
    const yg = rSat * Math.sin(satLongRad);
    const zg = 0;
    const vx = xg - xs;
    const vy = yg - ys;
    const vz = zg - zs;
    const E = -Math.sin(userLongRad) * vx + Math.cos(userLongRad) * vy;
    const N = -Math.sin(userLatRad) * Math.cos(userLongRad) * vx - Math.sin(userLatRad) * Math.sin(userLongRad) * vy + Math.cos(userLatRad) * vz;
    const U = Math.cos(userLatRad) * Math.cos(userLongRad) * vx + Math.cos(userLatRad) * Math.sin(userLongRad) * vy + Math.sin(userLatRad) * vz;
    let elevation = Math.atan2(U, Math.sqrt(E * E + N * N));
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
    const userLongRad = this.degToRad(userLongitude);
    const userLatRad = this.degToRad(userLatitude);
    const satLongRad = this.degToRad(satelliteLongitude);
    const longDiff = satLongRad - userLongRad;
    const polarizationRad = Math.atan2(Math.tan(longDiff), Math.sin(userLatRad));
    let polarization = this.radToDeg(polarizationRad);
    if (polarization > 90) polarization -= 180;
    if (polarization < -90) polarization += 180;
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
