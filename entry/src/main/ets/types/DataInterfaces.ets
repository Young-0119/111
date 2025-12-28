/*
 * 项目通用数据接口定义
 */

// 位置信息（格式化展示用）
export interface LocationInfo {
  directionLon: string;
  valueLon: string;
  directionLat: string;
  valueLat: string;
}

// 卫星参数（静态配置）
export interface SatelliteParams {
  longitude: number;
  name: string;
  description: string;
}

// 卫星角度（计算结果）
export interface SatelliteAngles {
  azimuth: number;         // 方位角
  elevation: number;       // 俯仰角
  polarization: number;    // 极化角
}

// 水印信息（拍照叠加显示）
export interface WatermarkInfo {
  timestamp: string;
  weather?: string;
  location?: string;
  altitude?: string;
  direction?: string;
  longitude?: string;
  latitude?: string;
  organization?: string;
  title?: string;
}

// 传感器读数（可用于收敛订阅数据）
export interface CompassSensorReadings {
  azimuth: number;
  pitch: number;
  roll: number;
  pressure: number;
  magneticField: number;
}