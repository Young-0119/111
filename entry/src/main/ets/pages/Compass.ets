/**
 * 卫星寻星助手主页面
 * 分为三个区域：顶部信息区、中部罗盘区、底部控制区
 */

import router from '@ohos.router';
import sensor from '@ohos.sensor';
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import bundleManager from '@ohos.bundle.bundleManager';
import { CompassMain } from '../views/CompassMain';
// 临时注释掉以下导入以排除编译
// import { AltitudeCalculator } from 'camera';
// import { SatelliteCalculator } from 'camera';
import { LocationService } from 'camera';
import preferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import geoLocationManager from '@ohos.geoLocationManager';

// 卫星参数接口
interface SatelliteParams {
  longitude: number;
  name: string;
  description: string;
}

// 定义位置信息接口
interface LocationInfo {
  directionLon: string;
  valueLon: string;
  directionLat: string;
  valueLat: string;
}

// 可复用的卫星寻星页面内容组件
@Component
export struct IndexContent {
  // 状态变量
  @State azimuth: number = 0; // 设备方位角
  @State pitch: number = 0; // 俯仰角
  @State roll: number = 0; // 极化角
  @State deviceAzimuth: number = 0; // 设备方位角（用于罗盘显示）
  @State longitude: number = 0; // 经度
  @State latitude: number = 0; // 纬度
  @State targetAzimuth: number = 134; // 目标卫星方位角
  @State targetElevation: number = 45; // 目标卫星俯仰角
  @State polarizationAngle: number = 0; // 极化角
  @State isLocationEnabled: boolean = false;
  @State locationStatus: string = '未获取位置';
  @State privacyAgreed: boolean = false; // 隐私政策同意状态
  @State showPrivacyDialog: boolean = false; // 显示隐私政策弹窗
  @State selectedSatellite: string = 'APSTAR'; // 当前选择的卫星类型
  @State satelliteName: string = '亚太6C/6D'; // 当前卫星名称


  
  // 新增传感器数据
  @State pressure: number = 0; // 气压 (hPa)
  @State altitude: number = 0; // 海拔 (m)
  @State magneticField: number = 0; // 磁场强度 (μT)
  
  // 格式化的位置信息
  @State formattedLocation: LocationInfo = {
    directionLon: '东经',
    valueLon: '0.0000000000',
    directionLat: '北纬',
    valueLat: '0.0000000000'
  };
  
  // 方向名称
  @State directionName: string = '北';
  @State formattedDirection: number = 0;
  
  // 位置服务实例
  private locationService: LocationService = new LocationService();
  // 临时注释掉海拔计算器实例
  // private altitudeCalculator: AltitudeCalculator = AltitudeCalculator.getInstance();

  constructor() {
    super();
  }

  /**
   * 初始化位置服务
   */
  async initLocationService() {
    // 新版 LocationService 在构造时已启动轮询，无需显式初始化
    console.info('LocationService 使用 dataservices 版本，无需初始化');
  }

  /**
   * 检查隐私政策同意状态
   */
  async checkPrivacyAgreement() {
    try {
      const context = getContext(this);
      const dataPreferences = await preferences.getPreferences(context, 'privacy_settings');
      const agreed = await dataPreferences.get('privacy_agreed', false);
      
      if (agreed) {
        this.privacyAgreed = true;
        // 用户已同意隐私政策，延迟申请权限避免冲突
        setTimeout(() => {
          this.requestLocationPermission();
        }, 300);
      } else {
        // 延迟显示隐私政策弹窗，确保页面完全加载
        setTimeout(() => {
          this.showPrivacyDialog = true;
        }, 100);
      }
    } catch {
      console.error('检查隐私政策状态失败');
      // 出错时延迟显示隐私政策弹窗
      setTimeout(() => {
        this.showPrivacyDialog = true;
      }, 100);
    }
  }

  /**
   * 处理隐私政策同意
   */
  async handlePrivacyAgree() {
    try {
      const context = getContext(this);
      const dataPreferences = await preferences.getPreferences(context, 'privacy_settings');
      await dataPreferences.put('privacy_agreed', true);
      await dataPreferences.flush();
      
      this.privacyAgreed = true;
      this.locationStatus = '隐私政策已同意，准备获取位置...';
      
      // 延迟申请权限，避免与隐私弹窗冲突
      setTimeout(() => {
        this.requestLocationPermission();
      }, 500);
    } catch {
      console.error('保存隐私政策同意状态失败');
      this.locationStatus = '隐私政策设置失败';
    }
  }

  /**
   * 处理隐私政策拒绝
   */
  async handlePrivacyDisagree() {
    try {
      const context = getContext(this);
      const dataPreferences = await preferences.getPreferences(context, 'privacy_settings');
      await dataPreferences.put('privacy_agreed', false);
      await dataPreferences.flush();
      
      this.privacyAgreed = false;
      this.locationStatus = '用户拒绝隐私政策，无法获取位置信息';
      
      // 设置默认位置，不申请权限
      await this.setDefaultLocation();
    } catch {
      console.error('保存隐私政策拒绝状态失败');
      this.locationStatus = '隐私政策设置失败';
      await this.setDefaultLocation();
    }
  }

  aboutToAppear() {
    // 初始化位置服务
    this.initLocationService();
    
    // 检查隐私政策同意状态
    this.checkPrivacyAgreement();
    
    // 订阅方向传感器
    try {
      sensor.on(sensor.SensorId.ORIENTATION, (data: sensor.OrientationResponse) => {
        this.azimuth = data.alpha || 0;
        // 修正俯仰角正负号：设备向上倾斜为正值，向下倾斜为负值
        this.pitch = -(data.beta || 0);
        this.roll = data.gamma || 0;
        this.deviceAzimuth = this.azimuth;
        
        // 更新方向信息
        this.updateDirectionInfo(this.azimuth);
      }, { interval: 100000000 });
    } catch {
      console.error('传感器订阅失败');
    }
    
    // 订阅气压传感器
    try {
      sensor.on(sensor.SensorId.BAROMETER, (data: sensor.BarometerResponse) => {
        this.pressure = data.pressure || 0;
        // 实时计算海拔（临时使用简单计算）
        // const calculatedAltitude: number | null = this.altitudeCalculator.calculateAltitudeFromPressure(this.pressure);
        // if (calculatedAltitude !== null) {
        //   this.altitude = calculatedAltitude;
        // }
      }, { interval: 1000000000 });
    } catch {
      console.error('气压传感器订阅失败');
    }
    
    // 订阅磁场传感器
    try {
      sensor.on(sensor.SensorId.MAGNETIC_FIELD, (data: sensor.MagneticFieldResponse) => {
        const magnitude = Math.sqrt((data.x || 0) ** 2 + (data.y || 0) ** 2 + (data.z || 0) ** 2);
        this.magneticField = magnitude;
      }, { interval: 1000000000 });
    } catch {
      console.error('磁场传感器订阅失败');
    }
  }

  aboutToDisappear() {
    // 取消传感器订阅
    try {
      sensor.off(sensor.SensorId.ORIENTATION);
      sensor.off(sensor.SensorId.BAROMETER);
      sensor.off(sensor.SensorId.MAGNETIC_FIELD);
    } catch {
      console.error('传感器取消订阅失败');
    }
  }

  /**
   * 更新方向信息
   */
  updateDirectionInfo(degree: number) {
    const directions = ['北', '东北', '东', '东南', '南', '西南', '西', '西北'];
    const index = Math.round((degree % 360) / 45) % 8;
    this.directionName = directions[index];
    this.formattedDirection = Math.round(degree);
  }

  /**
   * 更新位置信息格式
   */
  updateLocationFormat(longitude: number, latitude: number) {
     this.formattedLocation = {
       directionLon: longitude >= 0 ? '东经' : '西经',
       valueLon: (longitude >= 0 ? longitude : -longitude).toFixed(10),
       directionLat: latitude >= 0 ? '北纬' : '南纬',
       valueLat: (latitude >= 0 ? latitude : -latitude).toFixed(10)
     } as LocationInfo;
  }



  /**
   * 请求位置权限
   */
  async requestLocationPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId = bundleInfo.appInfo.accessTokenId;
      
      // 检查精确位置权限
      const locationPermission = await atManager.checkAccessToken(tokenId, 'ohos.permission.LOCATION');
      // 检查大概位置权限
      const approximateLocationPermission = await atManager.checkAccessToken(tokenId, 'ohos.permission.APPROXIMATELY_LOCATION');
      
      if (locationPermission === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ||
          approximateLocationPermission === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        console.info('位置权限已授予');
        this.getCurrentLocation();
        return true;
      }
      
      // 请求权限
      const result = await atManager.requestPermissionsFromUser(getContext(this), [
        'ohos.permission.LOCATION',
        'ohos.permission.APPROXIMATELY_LOCATION'
      ]);
      
      console.info('权限请求结果:', result);
      
      // 检查是否至少有一个位置权限被授予
      const hasLocationPermission = result.authResults.some(status => 
        status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
      );
      
      if (hasLocationPermission) {
        console.info('位置权限请求成功');
        this.getCurrentLocation();
        return true;
      } else {
        console.warn('位置权限被拒绝');
        this.getCurrentLocation(); // 即使权限被拒绝也尝试获取位置
        return false;
      }
    } catch {
      console.error('权限请求失败');
      this.getCurrentLocation(); // 即使权限请求失败也尝试获取位置
      return false;
    }
  }

  /**
   * 获取当前位置
   */
  async getCurrentLocation(): Promise<void> {
    this.locationStatus = '正在获取位置...';

    // 使用 dataservices 的快照接口
    const snapshot: geoLocationManager.Location | null = this.locationService.getCurrentLocation();
    if (snapshot) {
      console.info('定位成功(快照):', snapshot);
      this.longitude = Number(snapshot.longitude || 0);
      this.latitude = Number(snapshot.latitude || 0);
      this.locationStatus = '位置获取成功';
      this.updateLocationFormat(this.longitude, this.latitude);
      this.isLocationEnabled = true;

      // 优先基于气压计算海拔，否则使用位置中的海拔
      if (this.pressure > 0) {
        const calculatedAltitude: number | null = this.altitudeCalculator.calculateAltitudeFromPressure(this.pressure);
        if (calculatedAltitude !== null) {
          this.altitude = calculatedAltitude;
        }
      } else if (snapshot.altitude !== null && snapshot.altitude !== undefined) {
        this.altitude = Number(snapshot.altitude);
      }

      await this.calculateSatelliteAngles();
      return;
    }

    // 没有快照：进入定位中状态，并监听一次位置更新
    this.locationStatus = '定位中...';
    const listener = async (loc: geoLocationManager.Location) => {
      try {
        this.longitude = Number(loc.longitude || 0);
        this.latitude = Number(loc.latitude || 0);
        this.locationStatus = '位置获取成功';
        this.updateLocationFormat(this.longitude, this.latitude);
        this.isLocationEnabled = true;

        if (this.pressure > 0) {
          const calculatedAltitude: number | null = this.altitudeCalculator.calculateAltitudeFromPressure(this.pressure);
          if (calculatedAltitude !== null) {
            this.altitude = calculatedAltitude;
          }
        } else if (loc.altitude !== null && loc.altitude !== undefined) {
          this.altitude = Number(loc.altitude);
        }
        await this.calculateSatelliteAngles();
      } finally {
        // 只监听一次
        try { this.locationService.removeLocationListener(listener); } catch {}
      }
    };
    this.locationService.addLocationListener(listener);

    // 若尚未启用，则设置默认位置以保证页面正常显示
    if (!this.isLocationEnabled) {
      await this.setDefaultLocation();
    }
  }
  
  /**
   * 设置默认位置
   */
  private async setDefaultLocation(): Promise<void> {
    // 使用默认位置（0,0）
    this.longitude = 0;
    this.latitude = 0;
    this.updateLocationFormat(this.longitude, this.latitude);
    this.isLocationEnabled = true;
    
    // 计算卫星角度
    await this.calculateSatelliteAngles();
  }

  /**
   * 获取卫星参数
   */
  getSatelliteParams(): SatelliteParams {
    switch (this.selectedSatellite) {
      case 'APSTAR':
        return {
          longitude: 134, // 亚太6C/6D卫星经度
          name: '亚太6C/6D',
          description: '亚太6C：2018年5月发射，传统通信卫星\n亚太6D：2020年7月发射，高通量宽带卫星'
        };
      case 'TIANTONG':
        return {
          longitude: 101.4, // 天通一号03星经度
          name: '天通一号',
          description: '天通一号03星：2021年1月发射，移动通信卫星\n提供卫星移动通信服务，覆盖中国及周边地区'
        };
      default:
        return {
          longitude: 134,
          name: '亚太6C/6D',
          description: '默认卫星'
        };
    }
  }

  /**
   * 检查方位角是否匹配
   */
  isAzimuthMatched(): boolean {
    const tolerance = 5; // 容差范围5度
    return Math.abs(this.azimuth - this.targetAzimuth) <= tolerance;
  }

  /**
   * 检查俯仰角是否匹配
   */
  isElevationMatched(): boolean {
    const tolerance = 3; // 容差范围3度
    return Math.abs(this.pitch - this.targetElevation) <= tolerance;
  }

  /**
   * 检查极化角是否匹配
   */
  isPolarizationMatched(): boolean {
    const tolerance = 3; // 容差范围3度
    return Math.abs(this.roll - this.polarizationAngle) <= tolerance;
  }

  /**
   * 计算卫星角度
   */
  async calculateSatelliteAngles() {
    const satParams = this.getSatelliteParams();
    const satLon = satParams.longitude;
    this.satelliteName = satParams.name; // 更新卫星名称 
    
    try {
      // 使用SatelliteCalculator的新方法，自动获取当前位置
      // const calculator: SatelliteCalculator = SatelliteCalculator.getInstance();
      
      // 计算方位角
      const azimuthResult: number | null = await calculator.calculateAzimuthFromCurrentLocation(satLon);
      if (azimuthResult !== null) {
        this.targetAzimuth = azimuthResult;
      }
      
      // 计算俯仰角
      const elevationResult: number | null = await calculator.calculateElevationFromCurrentLocation(satLon);
      if (elevationResult !== null) {
        this.targetElevation = elevationResult;
      }
      
      // 计算极化角
      const polarizationResult: number | null = await calculator.calculatePolarizationFromCurrentLocation(satLon);
      if (polarizationResult !== null) {
        this.polarizationAngle = polarizationResult;
      }
    } catch {
      console.error('计算卫星角度失败');
      // 如果自动获取失败，使用当前已有的经纬度作为备用方案
      if (this.latitude !== 0 && this.longitude !== 0) {
        const calculator = SatelliteCalculator.getInstance();
        this.targetAzimuth = calculator.calculateAzimuthWithSatellite(this.longitude, this.latitude, satLon);
        this.targetElevation = calculator.calculateElevationWithSatellite(this.longitude, this.latitude, satLon);
        this.polarizationAngle = calculator.calculatePolarizationWithSatellite(this.longitude, this.latitude, satLon);
      }
    }
    
    // 模拟海拔计算（基于气压，使用AltitudeCalculator统一处理）
    const calculatedAltitude: number | null = this.altitudeCalculator.calculateAltitudeFromPressure(this.pressure);
    if (calculatedAltitude !== null) {
      this.altitude = calculatedAltitude;
    }
  }

  build() {
    Column() {
      // 顶部信息区域
      this.CompassHeader()
      
      // 中部罗盘区域
      this.CompassMainArea()
      
      // 底部控制区域
      this.ControlArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
    .padding(0)
    .margin(0)
  }

  /**
   * 顶部信息组件
   */
  @Builder
  CompassHeader() {
    Column() {
      // 顶部导航栏
      Row() {
        // 左侧占位
        Text('')
          .layoutWeight(1)
        
        // 中间占位
        Text('')
          .layoutWeight(2)
        
        // 右侧帮助按钮
        Button('帮助')
          .fontSize(14)
          .fontColor(Color.White)
          .backgroundColor('rgba(52, 199, 89, 0.8)')
          .borderRadius(15)
          .width(50)
          .height(30)
          .layoutWeight(1)
          .onClick(() => {
            router.pushUrl({
              url: 'pages/HelpPage'
            }).catch(() => {
              console.error('导航到帮助页面失败');
            });
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 5 })
      

      
      // 方向信息
      Row() {
        Text(`${this.formattedDirection}°`)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
        
        Text(this.directionName)
          .fontSize(24)
          .fontColor(Color.White)
          .margin({ left: 10 })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 10 })
      
      // 坐标信息
      Row() {
        Text(`（${this.formattedLocation.directionLon}${this.formattedLocation.valueLon}，${this.formattedLocation.directionLat}${this.formattedLocation.valueLat}）`)
          .fontSize(14)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ top: 60, bottom: 10, left: 15, right: 15 })
    .backgroundColor('rgba(0, 0, 0, 0.7)')
  }

  /**
   * 中部罗盘区域
   */
  @Builder
  CompassMainArea() {
    Stack() {
      // 罗盘组件
      CompassMain({ 
        targetAzimuth: this.targetAzimuth,
        deviceDirection: this.deviceAzimuth,
        satelliteName: this.satelliteName
      })
        .width(300)
        .height(300)
      

    }
     .width('100%')
     .layoutWeight(1)
     .alignContent(Alignment.Center)
  }

  /**
   * 底部控制区域
   */
  @Builder
  ControlArea() {
    Column() {
      // 目标信息
      Row() {
        Column() {
          Text('目标方位角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.targetAzimuth.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
        
        Column() {
          Text('目标俯仰角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.targetElevation.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
        
        Column() {
          Text('目标极化角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.polarizationAngle.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 15, bottom: 15 })
      .justifyContent(FlexAlign.SpaceAround)
      
      // 设备信息
      Row() {
        Column() {
          Text('当前方位角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.azimuth.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(this.isAzimuthMatched() ? '#34C759' : Color.White)
            .animation({
              duration: 300,
              curve: Curve.EaseInOut
            })
        }
        .layoutWeight(1)
        
        Column() {
          Text('当前俯仰角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.pitch.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(this.isElevationMatched() ? '#34C759' : Color.White)
            .animation({
              duration: 300,
              curve: Curve.EaseInOut
            })
        }
        .layoutWeight(1)
        
        Column() {
          Text('当前极化角')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.roll.toFixed(1)}°`)
            .fontSize(14)
            .fontColor(this.isPolarizationMatched() ? '#34C759' : Color.White)
            .animation({
              duration: 300,
              curve: Curve.EaseInOut
            })
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ bottom: 15 })
      .justifyContent(FlexAlign.SpaceAround)
      
      // 环境信息
      Row() {
        Column() {
          Text('气压')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.pressure.toFixed(1)} hPa`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
        
        Column() {
          Text('海拔')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.altitude.toFixed(1)} m`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
        
        Column() {
          Text('磁场强度')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${this.magneticField.toFixed(1)} μT`)
            .fontSize(14)
            .fontColor(Color.White)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .padding({ bottom: 15 })
      .justifyContent(FlexAlign.SpaceAround)
      
      // 卫星选择按钮
        Row() {
          Button('亚太6C/6D')
            .width('45%')
            .height(40)
            .backgroundColor(this.selectedSatellite === 'APSTAR' ? '#34C759' : '#666666')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(async () => {
              this.selectedSatellite = 'APSTAR';
              await this.calculateSatelliteAngles();
            })
          
          Button('天通一号')
            .width('45%')
            .height(40)
            .backgroundColor(this.selectedSatellite === 'TIANTONG' ? '#34C759' : '#666666')
            .fontColor(Color.White)
            .borderRadius(8)
            .onClick(async () => {
              this.selectedSatellite = 'TIANTONG';
              await this.calculateSatelliteAngles();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ bottom: 15 })
      
      // 状态信息
      Text(this.locationStatus)
        .fontSize(12)
        .fontColor('#CCCCCC')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 20 })
        .padding({ top: 10, bottom: 10 })
        .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, bottom: 30 })
    .backgroundColor('rgba(0, 0, 0, 0.8)')
    .margin({ bottom: 20 })
  }
}

// 独立页面入口（移除@Entry装饰器避免与MainNavigationPage冲突）
@Component
struct Index {
  build() {
    Column() {
      IndexContent()
    }
    .width('100%')
    .height('100%')
  }
}