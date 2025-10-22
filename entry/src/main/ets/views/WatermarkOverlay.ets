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

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'commons';

export interface WatermarkInfo {
  timestamp: string;
  weather?: string;
  location?: string;
  altitude?: string;
  direction?: string;
  longitude?: string;
  latitude?: string;
  organization?: string;
}

@Component
export struct WatermarkOverlay {
  @Prop watermarkInfo: WatermarkInfo = {
    timestamp: this.getCurrentTimestamp(),
    weather: '晴朗',
    location: '北京市朝阳区',
    altitude: '50米',
    direction: '北偏东30度',
    longitude: '116.4074°',
    latitude: '39.9042°',
    organization: '消防救援支队'
  };
  
  @State private currentOrganization: string = '';
  @State private showEditDialog: boolean = false;
  @State private editingOrganization: string = '';
  
  private PREF_KEY_ORGANIZATION = 'organization_name';
  
  aboutToAppear() {
    this.loadOrganization();
    this.updateTimestamp();
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
  
  private updateTimestamp() {
    // 每秒更新时间戳
    setInterval(() => {
      this.watermarkInfo.timestamp = this.getCurrentTimestamp();
    }, 1000);
  }
  
  private async loadOrganization() {
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(getContext(this), 'watermark_prefs');
      this.currentOrganization = await prefs.get(this.PREF_KEY_ORGANIZATION, this.watermarkInfo.organization || '') as string;
      // 更新传入的watermarkInfo
      this.watermarkInfo.organization = this.currentOrganization;
    } catch (err) {
      Logger.error('WatermarkOverlay', `loadOrganization failed: ${err}`);
    }
  }
  
  private async saveOrganization(newOrg: string) {
    try {
      const prefs: preferences.Preferences = await preferences.getPreferences(getContext(this), 'watermark_prefs');
      await prefs.put(this.PREF_KEY_ORGANIZATION, newOrg);
      await prefs.flush();
      this.currentOrganization = newOrg;
      this.watermarkInfo.organization = newOrg;
    } catch (err) {
      Logger.error('WatermarkOverlay', `saveOrganization failed: ${err}`);
    }
  }
  
  @Builder
  EditDialogBuilder() {
    // 使用全屏容器实现居中显示
    Stack() {
      Column() {
        Text('编辑制作单位')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 16 })

        TextInput({ placeholder: '请输入制作单位名称', text: this.editingOrganization })
          .width('100%')
          .height(36)
          .fontSize(14)
          .backgroundColor('#f8f8f8')
          .borderRadius(4)
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

  
  build() {
    // 使用Row容器来实现左上角对齐
    Row() {
      Column() {
        // 图片和标题行
        Row() {
          Image($r('app.media.watermark_logo'))
            .width(60)
            .height(46.48)
            .margin({ right: 12 })

          Text($r('app.string.watermark_title'))
            .fontSize(14)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
        }
        .alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(0, 87, 217, 0.5)')
        .width('60%')
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })

        // 第一行：拍摄时间
        Text() {
          Span($r('app.string.watermark_timestamp'))
          Span('：')
          Span(this.watermarkInfo.timestamp)
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第二行：天气信息
        Text() {
          Span($r('app.string.watermark_weather'))
          Span('：')
          Span(this.watermarkInfo.weather || '获取中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第三行：地点信息
        Text() {
          Span($r('app.string.watermark_location'))
          Span('：')
          Span(this.watermarkInfo.location || '定位中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第四行：海拔信息
        Text() {
          Span($r('app.string.watermark_altitude'))
          Span('：')
          Span(this.watermarkInfo.altitude || '计算中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第五行：方位角信息
        Text() {
          Span($r('app.string.watermark_direction'))
          Span('：')
          Span(this.watermarkInfo.direction || '计算中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第六行：经度信息
        Text() {
          Span($r('app.string.watermark_longitude'))
          Span('：')
          Span(this.watermarkInfo.longitude || '计算中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第七行：纬度信息
        Text() {
          Span($r('app.string.watermark_latitude'))
          Span('：')
          Span(this.watermarkInfo.latitude || '获取中...')
        }
          .fontSize(12)
          .fontColor('#000000')
          .margin({ bottom: 4 })

        // 第八行：制作单位（支持双击编辑）
        Text() {
          Span($r('app.string.watermark_organization'))
          Span('：')
          Span(this.currentOrganization || this.watermarkInfo.organization || '双击编辑')
        }
          .fontSize(12)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .backgroundColor('rgba(0, 87, 217, 0.5)')
          .width('60%')
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
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
      .scale({ 
        x: 0.8, 
        y: 0.8,
        centerX: '0%',
        centerY: '100%'
      }) // 以左下角为中心缩放到80%大小
      .rotate({ 
        angle: 90, 
        centerX: '0%', 
        centerY: '100%'
      }) // 以左下角为轴心，顺时针旋转90度
      .translate({ 
        x: 0, 
        y: '-100%'
      }) // 向上移动一个水印宽度的距离
      .padding({ left: 4, right: 4, top: 4, bottom: 4 })  // 添加内边距
      .borderRadius(8)  // 添加圆角
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
    .justifyContent(FlexAlign.Start)
    .padding({ top: 1, left: 1 })
    .bindContentCover(this.showEditDialog, this.EditDialogBuilder(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: 'rgba(0, 0, 0, 0.4)',
      onAppear: () => {},
      onDisappear: () => {}
    })
  }
}

export default WatermarkOverlay;