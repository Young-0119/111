/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'commons';
import { OrganizationService } from 'camera';
import AmapService from 'camera/src/main/ets/dataservices/AmapService';
import { GeoDataService } from 'camera';
import { WatermarkInfo } from '../types/DataInterfaces';
import { PhotoManager } from 'camera';
import PermissionManager from '../utils/PermissionManager';
import { Permissions, common } from '@kit.AbilityKit';

@Component
export struct WatermarkOverlay {
  @ObjectLink watermarkInfo: WatermarkInfo;
  @Prop previewWidth: number = 0;  // 预览区域宽度
  @Prop previewHeight: number = 0; // 预览区域高度
  @Prop photoManager: PhotoManager | undefined;
  @State currentOrganization: string = '';
  @State showEditDialog: boolean = false;
  @State editingOrganization: string = '';
  private orgListener?: (org: string) => void;
  private geoListenerId?: number;
  private tsTimerId?: number;
  
  aboutToAppear() {
    // 初始化组织服务并加载当前值
    OrganizationService.getInstance().initialize(AppStorage.get('abilityCtx') as common.UIAbilityContext);
    this.loadOrganization();
    // 订阅制作单位变更事件，保持视图层与服务内存态一致
    this.orgListener = (org: string) => {
      this.currentOrganization = org;
      this.watermarkInfo.organization = org;
    };
    OrganizationService.getInstance().addListener(this.orgListener);
    this.photoManager?.setLocationWeatherProvider(() => AmapService.fetchLocationAndWeatherAuto());
    this.updateTimestamp();
    const perms: Permissions[] = ['ohos.permission.LOCATION', 'ohos.permission.APPROXIMATELY_LOCATION'];
    PermissionManager.request(perms, AppStorage.get('abilityCtx') as common.UIAbilityContext)
      .then(() => {
        this.loadLocationAndWeather();
        return GeoDataService.getInstance().start(AppStorage.get('abilityCtx') as common.UIAbilityContext);
      })
      .then(() => {
        const snap = GeoDataService.getInstance().getSnapshot();
        this.watermarkInfo.altitude = snap.altitude.display;
        this.watermarkInfo.direction = snap.direction.display;
        this.watermarkInfo.longitude = snap.longitude.display;
        this.watermarkInfo.latitude = snap.latitude.display;
        this.geoListenerId = GeoDataService.getInstance().onUpdate(snap => {
          this.watermarkInfo.altitude = snap.altitude.display;
          this.watermarkInfo.direction = snap.direction.display;
          this.watermarkInfo.longitude = snap.longitude.display;
          this.watermarkInfo.latitude = snap.latitude.display;
        });
      })
      .catch(() => {
        this.loadLocationAndWeather();
        this.watermarkInfo.altitude = '获取失败';
        this.watermarkInfo.direction = '获取失败';
        this.watermarkInfo.longitude = '获取失败';
        this.watermarkInfo.latitude = '获取失败';
      });
  }
  
  aboutToDisappear() {
    // 取消订阅，避免泄漏
    if (this.orgListener) {
      OrganizationService.getInstance().removeListener(this.orgListener);
      this.orgListener = undefined;
    }
    if (this.geoListenerId) {
      GeoDataService.getInstance().removeListener(this.geoListenerId);
      this.geoListenerId = undefined;
    }
    if (this.tsTimerId) {
      try { clearInterval(this.tsTimerId); } catch (_) {}
      this.tsTimerId = undefined;
    }
  }
  
  
  private getCurrentTimestamp(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const weekdays = ['星期日','星期一','星期二','星期三','星期四','星期五','星期六'];
    const weekday = weekdays[now.getDay()];
    return `${year}.${month}.${day} ${weekday} ${hours}:${minutes}`;
  }
  
  private updateTimestamp() {
    this.tsTimerId = setInterval(() => {
      this.watermarkInfo.timestamp = this.getCurrentTimestamp();
    }, 1000) as number;
  }
  
  private loadOrganization() {
    try {
      const org = OrganizationService.getInstance().getOrganization() || this.watermarkInfo.organization || '';
      this.currentOrganization = org;
      this.watermarkInfo.organization = org;
    } catch (err) {
      Logger.error('WatermarkOverlay', `loadOrganization failed: ${String(err)}`);
    }
  }
  
  private async saveOrganization(newOrg: string) {
    try {
      await OrganizationService.getInstance().setOrganization(newOrg, AppStorage.get('abilityCtx') as common.UIAbilityContext);
      this.currentOrganization = newOrg;
      this.watermarkInfo.organization = newOrg;
    } catch (err) {
      Logger.error('WatermarkOverlay', `saveOrganization failed: ${String(err)}`);
    }
  }
  
  @Builder
  EditDialogBuilder() {
    // 使用全屏容器实现居中显示
    Stack() {
      Column() {
        Text('制作单位')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 16 })

        TextInput({ placeholder: '请输入', text: this.editingOrganization })
          .width('100%')
          .height(40)
          .fontSize(16)
          .fontColor('#222222')
          .placeholderColor('#888888')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#DCDCDC' })
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 16 })
          .onChange((value: string) => {
            this.editingOrganization = value;
          })

        Row() {
          Button('取消')
            .width('48%')
            .height(36)
            .fontSize(14)
            .backgroundColor('#ffffff')
            .fontColor('#666666')
            .border({ width: 1, color: '#e0e0e0' })
            .borderRadius(4)
            .onClick(() => {
              this.showEditDialog = false;
              this.editingOrganization = '';
            })

          Button('确认')
            .width('48%')
            .height(36)
            .fontSize(14)
            .backgroundColor('#0057d9')
            .fontColor('#ffffff')
            .borderRadius(4)
            .onClick(async () => {
              // 无论输入是否为空都进行保存，允许清空制作单位
              await this.saveOrganization(this.editingOrganization.trim());
              this.showEditDialog = false;
              this.editingOrganization = '';
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width(260)
      .padding(16)
      .backgroundColor('#ffffff')
      .borderRadius(8)
      .border({ width: 1, color: '#e8e8e8' })
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  
  // 计算水印区域尺寸为预览区的1/3
  private getWatermarkWidth(): number {
    return this.previewWidth > 0 ? Math.floor(this.previewWidth / 2) : 360;
  }
  
  private getWatermarkHeight(): number {
    return this.previewHeight > 0 ? Math.floor(this.previewHeight * 0.4) : 480;
  }

  private async loadLocationAndWeather() {
    try {
      this.watermarkInfo.location = '获取中';
      this.watermarkInfo.weather = '获取中';
      const result = await AmapService.fetchLocationAndWeatherAuto();
      this.watermarkInfo.location = result.location || '获取失败';
      this.watermarkInfo.weather = result.weather || '获取失败';
    } catch (_) {
      this.watermarkInfo.location = '获取失败';
      this.watermarkInfo.weather = '获取失败';
    }
  }

  build() {
    // 使用Stack容器实现绝对定位，避免全屏覆盖
    Stack() {
      // 水印内容容器
      Column() {
        // 图片和标题行
        Row() {
          Image($r('app.media.watermark_logo'))
            .width(60)
            .height(46.48)
            .margin({ right: 12 })

          Text($r('app.string.watermark_title'))
            .fontSize(12)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(0, 87, 217, 0.5)')
        .width('100%')
        .padding({ left: 3, right: 3, top: 3, bottom: 3 })
        .margin({ bottom: 3 })

        // 第一行：拍摄时间
        Text() {
          Span($r('app.string.watermark_timestamp'))
          Span('：')
          Span(this.watermarkInfo.timestamp)
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第二行：天气信息
        Text() {
          Span($r('app.string.watermark_weather'))
          Span('：')
          Span(this.watermarkInfo.weather || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第三行：地点信息
        Text() {
          Span($r('app.string.watermark_location'))
          Span('：')
          Span(this.watermarkInfo.location || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第四行：海拔信息
        Text() {
          Span($r('app.string.watermark_altitude'))
          Span('：')
          Span(this.watermarkInfo.altitude || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第五行：方位角信息
        Text() {
          Span($r('app.string.watermark_direction'))
          Span('：')
          Span(this.watermarkInfo.direction || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第六行：经度信息
        Text() {
          Span($r('app.string.watermark_longitude'))
          Span('：')
          Span(this.watermarkInfo.longitude || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })

        // 第七行：纬度信息
        Text() {
          Span($r('app.string.watermark_latitude'))
          Span('：')
          Span(this.watermarkInfo.latitude || '获取中')
        }
          .fontSize(9)
          .fontColor('#000000')
          .margin({ left: 3, bottom: 3 })
          

        // 第八行：制作单位（支持双击编辑）
        Text() {
          Span($r('app.string.watermark_organization'))
          Span('：')
          Span(this.currentOrganization || this.watermarkInfo.organization || '双击编辑')
        }
          .fontSize(9)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .backgroundColor('rgba(0, 87, 217, 0.5)')
          .width('100%')
          .padding({ left: 3, right: 3, top: 3, bottom: 3 })
          .hitTestBehavior(HitTestMode.Block)  // 单独设置此文本可以接收触摸事件
          .gesture(
            TapGesture({ count: 2 })
              .onAction(() => {
                this.editingOrganization = this.currentOrganization || this.watermarkInfo.organization || '';
                this.showEditDialog = true;
              })
          )
      }
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('rgba(255, 255, 255, 0.7)')  // 白色背景，透明度70%
      .shadow({
        radius: 6,
        color: 'rgba(0, 0, 0, 0.3)',
        offsetX: 0,
        offsetY: 3
      })
      .width(this.getWatermarkHeight())  // 动态设置宽度为预览区的1/2

      .rotate({ 
        angle: 90, 
        centerX: '0%', 
        centerY: '100%'
      }) // 以左下角为轴心，顺时针旋转90度
      .translate({ 
        x: 0, 
        y: '-100%'
      }) // 向上移动一个水印宽度的距离
      .padding({ left: 3, right: 3, top: 3, bottom: 3 })  // 添加内边距
      .borderRadius(4)  // 添加圆角
    }
    .width(this.getWatermarkHeight())  // 动态设置Stack容器宽度
    .height(this.getWatermarkWidth()) // 动态设置高度
    .alignContent(Alignment.TopStart)  // 左上角对齐
    .position({ x: 2, y: 2 })  // 绝对定位到左上角
    .hitTestBehavior(HitTestMode.None)  // 关键：设置为不拦截触摸事件
    .bindContentCover(this.showEditDialog, this.EditDialogBuilder(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: 'rgba(0, 0, 0, 0.4)',
      onAppear: () => {},
      onDisappear: () => {}
    })
  }
}

export default WatermarkOverlay;
