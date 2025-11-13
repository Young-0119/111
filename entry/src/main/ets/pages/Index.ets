/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 ("the License");
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

import { sensor } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { curves } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  CameraManager,
  GridLine,
  LevelIndicator,
  PhotoManager,
  PreviewManager,
  VideoManager
} from 'camera';
import { IndexContent as CompassPage } from './Compass';
import CameraConstant from '../constants/Constants';
import { calCameraPoint, getClampedChildPosition, limitNumberInRange, showToast } from '../utils/CommonUtil';
import RefreshableTimer from '../utils/RefreshableTimer';
import PermissionManager from '../utils/PermissionManager';
import ZoomButtonsView from '../views/ZoomButtonsView';
import ModeButtonsView from '../views/ModeButtonsView';
import SettingButtonsView from '../views/SettingButtonsView';
import OperateButtonsView from '../views/OperateButtonsView';
import { WatermarkOverlay } from '../views/WatermarkOverlay';
import { WatermarkInfo } from '../types/DataInterfaces';
import PreviewViewModel from '../viewmodels/PreviewViewModel';
import { Logger } from 'commons';

@Extend(SymbolGlyph)
function funcButtonStyle() {
  .fontSize(22)
  .fontColor([Color.White])
  .borderRadius('50%')
  .padding(12)
  .backgroundColor('#664D4D4D')
}

const TAG = 'Index'

@Entry
@Component
struct Index {
  private context: Context = this.getUIContext().getHostContext()!;
  private applicationContext = this.context.getApplicationContext();
  private windowClass = (this.context as common.UIAbilityContext).windowStage.getMainWindowSync();
  @State videoManager: VideoManager = new VideoManager(this.context);
  @State isLivePhoto: boolean = false;
  private photoManager: PhotoManager = new PhotoManager(this.context, true);
  private previewManager: PreviewManager = new PreviewManager(() => {
    this.onPreviewStart()
  });
  private cameraManager: CameraManager = new CameraManager(this.context, [this.previewManager,
    this.photoManager, this.videoManager]);
  @State previewVM: PreviewViewModel = new PreviewViewModel(this.getUIContext());
  @State isGridLineVisible: boolean = false;
  @State isLevelIndicatorVisible: boolean = false;
  @State isFocusBoxVisible: boolean = false;
  @State focusBoxPosition: Edges = { top: 0, left: 0 };
  private focusBoxSize: Size = { width: 80, height: 80 };
  private focusBoxTimer: RefreshableTimer = new RefreshableTimer(() => {
    this.isFocusBoxVisible = false;
  }, 3 * 1000);
  private exposureFontSize: number = 24;
  @State isSleeping: boolean = false;
  private sleepTimer?: RefreshableTimer;
  private zoomRange: number[] = [];
  @State zooms: number[] = [1, 5, 10];
  @State currentZoom: number = 1;
  @State isZoomPinching: boolean = false;
  private originZoomBeforePinch: number = 1; // record zoom after pinch, sale base it.
  @State isStabilizationEnabled: boolean = false;
  @State photoDelayTime: number = 0;
  @State photoRemainder: number = 0;
  @State isDelayTakePhoto: boolean = false;
  @State acc: sensor.AccelerometerResponse = { x: 0, y: 0, z: 0 } as sensor.AccelerometerResponse;
  private setPreviewSize: () => void = () => {
    this.previewVM.setPreviewSize();
  }
  @State isShowBlack: boolean = false;
  @StorageLink('captureClick') @Watch('onCaptureClick') captureClickFlag: number = 0;
  @State flashBlackOpacity: number = 1;
  @State watermarkInfo: WatermarkInfo = {
    timestamp: '',
    weather: '',
    location: '',
    altitude: '',
    direction: '',
    longitude: '',
    latitude: '',
    organization: ''
  };
  @State isWatermarkVisible: boolean = true;
  // Swiper 控制与当前页索引：0-相机主页，1-指南针页
  @State currentTab: number = 0;

  async aboutToAppear() {
    this.addGravityEventListener();
    this.initSleepTimer();
    this.registerApplicationStateChange();
    this.addOrientationChangeEventListener();
    try {
      display.on('foldStatusChange', () => {
        this.onFoldStatusChange()
      });
    } catch (exception) {
      Logger.error(TAG, `onFoldStatusChange failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  aboutToDisappear(): void {
    this.removeOrientationChangeEventListener();
  }

  // [Start addGravityEventListener]
  addGravityEventListener() {
    try {
      sensor.on(sensor.SensorId.GRAVITY, (data) => {
        this.acc = data;
      }, { interval: 100 * 1000 * 1000 }); // 100ms
    } catch (exception) {
      Logger.error(TAG, `addGravityEventListener failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  // [End addGravityEventListener]

  addOrientationChangeEventListener() {
    this.windowClass.on('windowSizeChange', this.setPreviewSize);
  }

  removeOrientationChangeEventListener() {
    this.windowClass.off('windowSizeChange', this.setPreviewSize);
  }

  // [Start initSleepTimer]
  initSleepTimer() {
    this.sleepTimer = new RefreshableTimer(() => {
      this.previewVM.openPreviewBlur();
      this.isSleeping = true;
      this.cameraManager.release();
    }, 30 * 1000);
    this.sleepTimer.start();
    const observer = this.getUIContext().getUIObserver();
    observer.on('willClick', () => {
      this.sleepTimer?.refresh();
    });
  }

  // [End initSleepTimer]

  async onFoldStatusChange() {
    await this.cameraManager.release();
    if (this.currentTab === 0) {
      await this.startCamera();
      this.syncButtonSettings();
    }
  }

  // [Start registerApplicationStateChange]
  registerApplicationStateChange() {
    this.applicationContext.on('applicationStateChange', {
      onApplicationForeground: async () => {
        // 前台预热：刷新水印信息与底图缓存，降低首帧耗时
        try {
          await this.photoManager.prewarmWatermarkCaches();
        } catch (err) {
          Logger.warn(TAG, `前台预热失败: ${String(err)}`);
        }
        if (this.currentTab === 0) {
          await this.startCamera();
          // [StartExclude registerApplicationStateChange]
          this.syncButtonSettings();
          // [EndExclude registerApplicationStateChange]
        } else {
          this.cameraManager.release();
        }
      },
      onApplicationBackground: () => {
        // [StartExclude registerApplicationStateChange]
        this.previewVM.openPreviewBlur();
        // [EndExclude registerApplicationStateChange]
        this.cameraManager.release();
      }
    })
  }

  async startCamera() {
    const cameraPosition = this.previewVM.getCameraPosition();
    const sceneMode = this.previewVM.getSceneMode();
    await this.cameraManager.start(this.previewVM.surfaceId, cameraPosition, sceneMode, this.previewVM.getProfile);
  }

  // [End registerApplicationStateChange]

  exitApp() {
    this.applicationContext.killAllProcesses().catch((err: BusinessError) => {
      Logger.error('showToast', `showToast failed, code is ${err.code}, message is ${err.message}`);
    });
  }

  onPreviewStart() {
    this.previewVM.closePreviewBlur();
  }

  initZooms() {
    const zoomRange = this.cameraManager.getZoomRange();
    const minZoom = zoomRange[0];
    this.zoomRange = zoomRange;
    if (minZoom < this.zooms[0]) {
      this.zooms.unshift(minZoom);
    }
  }

  initRates() {
    const frameRates = this.previewManager.getSupportedFrameRates();
    if (frameRates && frameRates[0]) {
      const minRate = frameRates[0].min;
      const maxRate = frameRates[0].max;
      this.previewVM.rates = [minRate, maxRate];
      this.previewVM.currentRate = maxRate;
      this.previewManager.setFrameRate(maxRate, maxRate);
    }
    ;
  }

  syncButtonSettings() {
    this.previewManager.setFrameRate(this.previewVM.currentRate, this.previewVM.currentRate);
    this.photoManager.enableMovingPhoto(this.isLivePhoto);
    this.photoManager.setPhotoOutputCallback();
  }

  flashBlackAnim() {
    this.flashBlackOpacity = 1;
    this.isShowBlack = true;
    animateToImmediately({
      curve: curves.interpolatingSpring(1, 1, 410, 38),
      delay: 50,
      onFinish: () => {
        this.isShowBlack = false;
        this.flashBlackOpacity = 1;
      }
    }, () => {
      this.flashBlackOpacity = 0;
    })
  }

  onCaptureClick(): void {
    this.flashBlackAnim();
  }

  @Builder
  preview() {
    // [Start Stack]
    Stack({
      alignContent: Alignment.Center
    }) {
      // [Start XComponent]
      // [Start XComponent_gesture]
      XComponent({
        type: XComponentType.SURFACE,
        controller: this.previewVM.xComponentController
      })
      // [StartExclude Stack]
      // [StartExclude XComponent_gesture]
        .onLoad(async () => {
          // [StartExclude XComponent]
          await PermissionManager.request(CameraConstant.PERMISSIONS, this.context)
            .catch(() => {
              this.exitApp()
            });
          // [EndExclude XComponent]
          this.previewVM.surfaceId = this.previewVM.xComponentController.getXComponentSurfaceId();
          this.previewVM.setPreviewSize();
          this.previewVM.xComponentController.setXComponentSurfaceRotation({ lock: true });
          // [StartExclude XComponent]
          await this.startCamera();
          this.initZooms();
          this.initRates();
          // [EndExclude XComponent]
        })
        // [StartExclude XComponent_gesture]
        // [End XComponent]
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.originZoomBeforePinch = this.currentZoom;
              this.isZoomPinching = true;
              this.sleepTimer?.refresh();
            })
            .onActionUpdate((event: GestureEvent) => {
              if (this.previewVM.isVideoMode() && this.isStabilizationEnabled) {
                return;
              }
              const targetZoom = this.originZoomBeforePinch * event.scale;
              this.currentZoom = limitNumberInRange(targetZoom, this.zoomRange);
              this.cameraManager.setZoomRatio(this.currentZoom);
            })
            .onActionEnd(() => {
              this.isZoomPinching = false;
            })
        )
        // [End XComponent_gesture]
        .onClick(event => {
          this.isFocusBoxVisible = true;
          const previewSize = this.previewVM.previewSize;
          const cameraPoint = calCameraPoint(
            this.getUIContext().vp2px(event.x),
            this.getUIContext().vp2px(event.y),
            previewSize.width,
            previewSize.height
          );
          this.cameraManager.setFocusPoint(cameraPoint);
          this.cameraManager.setMeteringPoint(cameraPoint);
          this.focusBoxPosition = getClampedChildPosition(this.focusBoxSize, {
            width: this.getUIContext().px2vp(previewSize.width),
            height: this.getUIContext().px2vp(previewSize.height)
          }, event);
          this.focusBoxTimer.refresh();
        })
      // [EndExclude Stack]
      if (this.isGridLineVisible) {
        GridLine()
      }
      // [StartExclude Stack]
      if (this.isLevelIndicatorVisible) {
        LevelIndicator({
          acc: this.acc
        })
      }
      // focus box
      if (this.isFocusBoxVisible) {
        Image($r('app.media.focus_box'))
          .width(80)
          .height(80)
          .position(this.focusBoxPosition)
        SymbolGlyph($r('sys.symbol.sun_max'))
          .fontSize(this.exposureFontSize)
          .fontColor([Color.White])
          .position(this.getExposurePosition())
      }

      if (this.isDelayTakePhoto) {
        Text(`${this.photoRemainder}S`)
          .fontSize(44)
          .fontWeight(FontWeight.Regular)
          .fontColor(Color.White)
      }
      // [EndExclude Stack]

      if (this.isShowBlack) {
        Column()
          .id('black')
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .opacity(this.flashBlackOpacity)
      }

      // 水印组件
      if (this.isWatermarkVisible) {
        WatermarkOverlay({
          watermarkInfo: this.watermarkInfo,
          previewWidth: this.previewVM.getPreviewWidth(),
          previewHeight: this.previewVM.getPreviewHeight(),
          photoManager: this.photoManager
        })
      }
    }
    // [End Stack]
    .alignRules({
      middle: { anchor: '__container__', align: HorizontalAlign.Center }
    })
    .width(this.previewVM.getPreviewWidth())
    .height(this.previewVM.getPreviewHeight())
    .margin({ top: this.previewVM.getPreviewTop() })
    .blur(this.previewVM.blurRadius)
    .rotate(this.previewVM.blurRotation)
  }

  // [Start wakeupMask]
  @Builder
  wakeupMask() {
    Column() {
      Text($r('app.string.wakeup_text'))
        .fontColor(Color.White)
        .opacity(0.6)
    }
    // [StartExclude wakeupMask]
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .justifyContent(FlexAlign.Center)
    // [EndExclude wakeupMask]
    .onClick(async () => {
      this.isSleeping = false;
      this.sleepTimer?.refresh();
      await this.startCamera();
      this.syncButtonSettings();
    })
  }

  // [End wakeupMask]

  @Builder
  gridLineButton() {
    SymbolGlyph(
      this.isGridLineVisible
        ? $r('sys.symbol.camera_assistive_grid')
        : $r('sys.symbol.camera_assistive_grid_slash')
    )
      .funcButtonStyle()
      .onClick(() => {
        this.isGridLineVisible = !this.isGridLineVisible;
        const message = this.isGridLineVisible ? $r('app.string.grid_line_open') : $r('app.string.grid_line_close');
        showToast(this.getUIContext(), message);
      })
  }

  @Builder
  levelButton() {
    SymbolGlyph($r('sys.symbol.horizontal_level'))
      .funcButtonStyle()
      .onClick(() => {
        this.isLevelIndicatorVisible = !this.isLevelIndicatorVisible;
        const message = this.isLevelIndicatorVisible ? $r('app.string.level_open') : $r('app.string.level_close');
        showToast(this.getUIContext(), message);
      })
  }

  getExposurePosition(): Edges {
    const focusBoxLeft = this.focusBoxPosition.left as number;
    const focusBoxTop = this.focusBoxPosition.top as number;
    const exposureWidth = this.exposureFontSize;
    const exposureHeight = this.exposureFontSize;
    const focusBoxWidth = this.focusBoxSize.width;
    const focusBoxHeight = this.focusBoxSize.height;
    const previewWidth = this.getUIContext().px2vp(this.previewVM.previewSize.width);
    const GAP = 10;
    const top = focusBoxTop - exposureHeight / 2 + focusBoxHeight / 2;
    const left = focusBoxLeft > previewWidth / 2
      ? focusBoxLeft - GAP - exposureWidth
      : focusBoxLeft + focusBoxWidth + GAP;
    return { top, left };
  }

  @Builder
  funcButtonsView() {
    Column({ space: 24 }) {
      this.gridLineButton()
      this.levelButton()
      // Removed dual-channel preview button - only single-channel preview supported
    }
    .alignRules({
      top: { anchor: 'settingButtonsView', align: VerticalAlign.Bottom },
      right: { anchor: 'settingButtonsView', align: HorizontalAlign.End }
    })
    .margin({
      top: 40,
      right: 10
    })
  }

  // 将原有主页 UI 封装为构建器，便于作为 Swiper 子项
  @Builder
  cameraPage() {
    RelativeContainer() {
      this.preview()
      this.funcButtonsView()
      SettingButtonsView({
        previewVM: this.previewVM,
        cameraManager: this.cameraManager,
        previewManager: this.previewManager,
        photoManager: this.photoManager,
        videoManager: this.videoManager,
        photoDelayTime: this.photoDelayTime,
        isLivePhoto: this.isLivePhoto,
        isStabilizationEnabled: this.isStabilizationEnabled
      })
      if (!this.photoRemainder) {
        if (!this.previewVM.isFront &&
          !(this.isStabilizationEnabled && this.previewVM.isVideoMode())) {
          ZoomButtonsView({
            cameraManager: this.cameraManager,
            zoomRange: this.zoomRange,
            zooms: this.zooms,
            currentZoom: this.currentZoom
          })
        }
        ModeButtonsView({
          previewVM: this.previewVM,
          photoManager: this.photoManager,
          videoManager: this.videoManager,
          cameraManager: this.cameraManager,
          syncButtonSettings: () => {
            this.syncButtonSettings();
          }
        })
        OperateButtonsView({
          previewVM: this.previewVM,
          cameraManager: this.cameraManager,
          photoManager: this.photoManager,
          videoManager: this.videoManager,
          isDelayTakePhoto: this.isDelayTakePhoto,
          photoDelayTime: this.photoDelayTime,
          photoRemainder: this.photoRemainder,
          syncButtonSettings: () => {
            this.syncButtonSettings();
          }
        })
      }
      if (this.isSleeping) {
        this.wakeupMask()
      }
    }
    .height('100%')
    .width('100%')
    .backgroundColor(Color.Black)
    .onClick(() => {
    })
  }

  // Swiper 切换处理：进入相机页或指南针页
  private onSwiperChange(index: number) {
    this.currentTab = index;
    if (index === 0) {
      this.onEnterCameraTab();
    } else {
      this.onEnterCompassTab();
    }
  }

  private onEnterCameraTab() {
    try {
      this.previewVM.closePreviewBlur();
      this.sleepTimer?.refresh();
      this.startCamera();
      this.syncButtonSettings();
    } catch {}
  }

  private onEnterCompassTab() {
    try {
      this.previewVM.openPreviewBlur();
      this.cameraManager.release();
    } catch {}
  }

  build() {
    Swiper() {
      // 页 0：相机主页
      this.cameraPage()
      // 页 1：指南针页面
      CompassPage({ isActive: this.currentTab === 1 })
    }
    .index(this.currentTab)
    .loop(false)
    .indicator(true)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .onChange((index: number) => {
      this.onSwiperChange(index);
    })
  }
}