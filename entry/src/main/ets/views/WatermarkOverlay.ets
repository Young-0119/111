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
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';

@Component
export struct WatermarkOverlay {
  @ObjectLink watermarkInfo: WatermarkInfo;
  @Prop previewWidth: number = 0;  // 预览区域宽度
  @Prop previewHeight: number = 0; // 预览区域高度
  @Prop photoManager: PhotoManager | undefined;
  @State currentOrganization: string = '';
  @State currentTitle: string = '';
  @State currentLogoPath: string = '';
  @State showEditDialog: boolean = false;
  @State editingOrganization: string = '';
  @State editingTitle: string = '';
  private orgListener?: (org: string) => void;
  private logoListener?: (path: string) => void;
  private titleListener?: (title: string) => void;
  private geoListenerId?: number;
  private tsTimerId?: number;
  
  aboutToAppear() {
    // 初始化组织服务并加载当前值
    OrganizationService.getInstance().initialize(AppStorage.get('abilityCtx') as common.UIAbilityContext);
    this.loadOrganization();
    this.loadTitle();
    this.loadLogo();
    
    // 订阅制作单位变更事件
    this.orgListener = (org: string) => {
      this.currentOrganization = org;
      this.watermarkInfo.organization = org;
    };
    OrganizationService.getInstance().addListener(this.orgListener);

    // 订阅标题变更事件
    this.titleListener = (title: string) => {
      this.currentTitle = title;
      this.watermarkInfo.title = title;
    };
    OrganizationService.getInstance().addTitleListener(this.titleListener);

    // 订阅Logo变更事件
    this.logoListener = (path: string) => {
      this.currentLogoPath = path;
    };
    OrganizationService.getInstance().addLogoListener(this.logoListener);

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
    if (this.titleListener) {
      OrganizationService.getInstance().removeTitleListener(this.titleListener);
      this.titleListener = undefined;
    }
    if (this.logoListener) {
      OrganizationService.getInstance().removeLogoListener(this.logoListener);
      this.logoListener = undefined;
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

  private loadTitle() {
    try {
      const title = OrganizationService.getInstance().getTitle() || this.watermarkInfo.title || '';
      this.currentTitle = title;
      this.watermarkInfo.title = title;
    } catch (err) {
      Logger.error('WatermarkOverlay', `loadTitle failed: ${String(err)}`);
    }
  }

  private async saveTitle(newTitle: string) {
    try {
      await OrganizationService.getInstance().setTitle(newTitle, AppStorage.get('abilityCtx') as common.UIAbilityContext);
      this.currentTitle = newTitle;
      this.watermarkInfo.title = newTitle;
    } catch (err) {
      Logger.error('WatermarkOverlay', `saveTitle failed: ${String(err)}`);
    }
  }

  private loadLogo() {
    try {
      const logo = OrganizationService.getInstance().getLogoPath();
      this.currentLogoPath = logo;
    } catch (err) {
      Logger.error('WatermarkOverlay', `loadLogo failed: ${String(err)}`);
    }
  }

  private async selectImage() {
    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      const photoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const photoSelectResult = await photoViewPicker.select(photoSelectOptions);
      if (photoSelectResult && photoSelectResult.photoUris.length > 0) {
        await this.saveImageToSandbox(photoSelectResult.photoUris[0]);
      }
    } catch (err) {
      Logger.error('WatermarkOverlay', `selectImage failed: ${String(err)}`);
    }
  }

  private async saveImageToSandbox(uri: string) {
    try {
      const context = AppStorage.get('abilityCtx') as common.UIAbilityContext;
      const filesDir = context.filesDir;
      const targetPath = `${filesDir}/custom_watermark_logo.jpg`;
      
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const targetFile = fs.openSync(targetPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      
      const buffer = new ArrayBuffer(4096);
      let len = 0;
      while ((len = fs.readSync(file.fd, buffer)) > 0) {
        fs.writeSync(targetFile.fd, buffer, { length: len });
      }
      
      fs.closeSync(file.fd);
      fs.closeSync(targetFile.fd);
      
      // 保存文件URI到Service（使用file://协议）
      const fileUri = `file://${targetPath}`;
      await OrganizationService.getInstance().setLogoPath(fileUri, context);
      this.currentLogoPath = fileUri;
    } catch (err) {
      Logger.error('WatermarkOverlay', `saveImageToSandbox failed: ${String(err)}`);
    }
  }
  
  @Builder
  EditDialogBuilder() {
    // 使用全屏容器实现居中显示
    Stack() {
      Column() {
        Text('编辑水印信息')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .margin({ bottom: 20 })
          .width('100%')
          .textAlign(TextAlign.Center)

        // Logo设置区
        Text('水印图标')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 8 })
          .width('100%')

        Row() {
          if (this.currentLogoPath) {
            Image(this.currentLogoPath)
              .width(60)
              .height(46.48)
              .objectFit(ImageFit.Contain)
              .border({ width: 1, color: '#e0e0e0' })
              .margin({ right: 12 })
          } else {
            Text('无图标')
              .width(60)
              .height(46.48)
              .fontSize(12)
              .fontColor('#999999')
              .textAlign(TextAlign.Center)
              .backgroundColor('#f5f5f5')
              .border({ width: 1, color: '#e0e0e0' })
              .margin({ right: 12 })
          }

          Row({ space: 12 }) {
            Button('更换图片')
              .fontSize(14)
              .height(32)
              .backgroundColor('#0057d9')
              .fontColor('#ffffff')
              .onClick(() => {
                this.selectImage();
              })
            
            Button('清除图片')
              .fontSize(14)
              .height(32)
              .backgroundColor('#ffffff')
              .fontColor('#ff4d4f')
              .border({ width: 1, color: '#ff4d4f' })
              .onClick(async () => {
                await OrganizationService.getInstance().setLogoPath('', AppStorage.get('abilityCtx') as common.UIAbilityContext);
                this.currentLogoPath = '';
              })
          }
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .margin({ bottom: 20 })

        // 标题设置区
        Text('水印标题')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 8 })
          .width('100%')

        TextInput({ placeholder: '请输入标题', text: this.editingTitle })
          .width('100%')
          .height(40)
          .fontSize(16)
          .fontColor('#222222')
          .placeholderColor('#888888')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#DCDCDC' })
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 20 })
          .onChange((value: string) => {
            this.editingTitle = value;
          })

        // 单位设置区
        Text('制作单位')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .margin({ bottom: 8 })
          .width('100%')

        TextInput({ placeholder: '请输入制作单位', text: this.editingOrganization })
          .width('100%')
          .height(40)
          .fontSize(16)
          .fontColor('#222222')
          .placeholderColor('#888888')
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#DCDCDC' })
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 24 })
          .onChange((value: string) => {
            this.editingOrganization = value;
          })

        Row() {
          Button('取消')
            .width('48%')
            .height(40)
            .fontSize(16)
            .backgroundColor('#ffffff')
            .fontColor('#666666')
            .border({ width: 1, color: '#e0e0e0' })
            .borderRadius(4)
            .onClick(() => {
              this.showEditDialog = false;
              this.editingOrganization = '';
              this.editingTitle = '';
            })

          Button('保存')
            .width('48%')
            .height(40)
            .fontSize(16)
            .backgroundColor('#0057d9')
            .fontColor('#ffffff')
            .borderRadius(4)
            .onClick(async () => {
              // 保存制作单位和标题
              await this.saveOrganization(this.editingOrganization.trim());
              await this.saveTitle(this.editingTitle.trim());
              this.showEditDialog = false;
              this.editingOrganization = '';
              this.editingTitle = '';
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width(320)
      .padding(20)
      .backgroundColor('#ffffff')
      .borderRadius(12)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.2)' })
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
          if (this.currentLogoPath) {
            Image(this.currentLogoPath)
              .width(60)
              .height(46.48)
              .margin({ right: 12 })
              .objectFit(ImageFit.Contain)
          } else {
            // 无Logo时的占位符
            Stack() {
              Text('双击编辑')
                .fontSize(10)
                .fontColor('#FFFFFF')
                .fontWeight(FontWeight.Normal)
                .textAlign(TextAlign.Center)
            }
            .width(60)
            .height(46.48)
            .margin({ right: 12 })
            .backgroundColor('rgba(255, 255, 255, 0.2)')
            .border({ width: 1, color: 'rgba(255, 255, 255, 0.5)', style: BorderStyle.Dashed })
            .alignContent(Alignment.Center)
          }

          Text(this.currentTitle || this.watermarkInfo.title || $r('app.string.watermark_title'))
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
          

        // 第八行：制作单位
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
      .hitTestBehavior(HitTestMode.Transparent) // 允许穿透，但可被手势识别
      .gesture(
        TapGesture({ count: 2 })
          .onAction(() => {
            this.editingOrganization = this.currentOrganization || this.watermarkInfo.organization || '';
            this.editingTitle = this.currentTitle || this.watermarkInfo.title || '';
            // 如果没有设置过自定义标题，则尝试获取默认资源值（虽然这里拿不到resource的字符串值，但可以留空让用户自己填）
            // 注意：resource转string在ArkTS中需要Context，这里简单处理，若为空则显示空
            this.showEditDialog = true;
          })
      )

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
