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

import CameraConstant from '../constants/Constants';
import { calCameraPoint, getClampedChildPosition, limitNumberInRange, showToast } from '../utils/CommonUtil';
import RefreshableTimer from '../utils/RefreshableTimer';
import PermissionManager from '../utils/PermissionManager';
import ZoomButtonsView from '../views/ZoomButtonsView';
import ModeButtonsView from '../views/ModeButtonsView';
import SettingButtonsView from '../views/SettingButtonsView';
import OperateButtonsView from '../views/OperateButtonsView';
import { sensor } from '@kit.SensorServiceKit';
import { common } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import PreviewViewModel from '../viewmodels/PreviewViewModel';
import { CameraManager,
  GridLine,
  ImageReceiverManager,
  LevelIndicator,
  PhotoManager, PreviewManager, VideoManager } from 'camera';

@Extend(SymbolGlyph)
function funcButtonStyle() {
  .fontSize(22)
  .fontColor([Color.White])
  .borderRadius('50%')
  .padding(12)
  .backgroundColor('#664D4D4D')
}

@Entry
@Component
struct Index {
  private context: Context = this.getUIContext().getHostContext()!;
  private applicationContext = this.context.getApplicationContext();
  private windowClass = (this.context as common.UIAbilityContext).windowStage.getMainWindowSync();

  @State videoManager: VideoManager = new VideoManager(this.context);
  @State isSinglePhoto: boolean = false;
  @State isLivePhoto: boolean = false;
  private photoManager: PhotoManager = new PhotoManager(this.context, true, this.isSinglePhoto);
  private previewManager: PreviewManager = new PreviewManager();
  private imageReceiverManager: ImageReceiverManager = new ImageReceiverManager(px => {
    this.onImageReceiver(px);
  });
  private cameraManager: CameraManager = new CameraManager(this.context, [this.previewManager,
    this.photoManager, this.videoManager, this.imageReceiverManager]);

  @State previewVM: PreviewViewModel = new PreviewViewModel(this.getUIContext());

  @State isGridLineVisible: boolean = false;
  @State isLevelIndicatorVisible: boolean = false;
  @State isPreviewImageVisible: boolean = false;

  @State isFocusBoxVisible: boolean = false;
  @State focusBoxPosition: Edges = { top: 0, left: 0 };
  private focusBoxSize: Size = { width: 80, height: 80 };
  private focusBoxTimer: RefreshableTimer = new RefreshableTimer(() => {
    this.isFocusBoxVisible = false;
  }, 3 * 1000);

  @State isSleeping: boolean = false;
  private sleepTimer?: RefreshableTimer;

  private zoomRange: number[] = [];
  @State zooms: number[] = [1, 5, 10];
  @State currentZoom: number = 1;
  @State isZoomPinching: boolean = false;
  private originZoomBeforePinch: number = 1; // record zoom after pinch, sale base it.

  @State blurRadius: number = 0;

  @State previewImage: PixelMap | ResourceStr = '';
  private PreviewImageHeight: number = 80;

  @State photoDelayTime: number = 0;
  @State photoRemainder: number = 0;
  @State isDelayTakePhoto:boolean = false;

  @State acc: sensor.AccelerometerResponse = { x: 0, y: 0, z: 0 } as sensor.AccelerometerResponse;
  private setPreviewSize: () => void = () => { this.previewVM.setPreviewSize(); }

  async aboutToAppear() {
    sensor.on(sensor.SensorId.ACCELEROMETER, (data) => {
      this.acc = data;
    }, { interval: 100 * 1000 * 1000 }); // 100ms
    this.initSleepTimer();
    this.registerApplicationStateChange();
    this.addOrientationChangeEventListener();
  }

  aboutToDisappear(): void {
    this.removeOrientationChangeEventListener();
  }

  addOrientationChangeEventListener() {
    this.windowClass.on('windowSizeChange', this.setPreviewSize);
  }

  removeOrientationChangeEventListener() {
    this.windowClass.off('windowSizeChange', this.setPreviewSize);
  }

  onImageReceiver(pixelMap: PixelMap) {
    this.previewImage = pixelMap;
  }

  initSleepTimer() {
    this.sleepTimer = new RefreshableTimer(() => {
      this.isSleeping = true;
      this.cameraManager.release();
    }, 30 * 1000);
    this.sleepTimer.start();
    const observer = this.getUIContext().getUIObserver();
    observer.on('willClick', () => {
      this.sleepTimer?.refresh();
    })
  }

  openPreviewBlur() {
    this.blurRadius = 150;
  }

  closePreviewBlur() {
    this.blurRadius = 0;
  }

  registerApplicationStateChange() {
    this.applicationContext.on('applicationStateChange', {
      onApplicationForeground: async () => {
        await this.startCamera();
        this.syncButtonSettings();
      },
      onApplicationBackground: () => {
        this.cameraManager.release();
      }
    })
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
    };
  }

  async startCamera() {
    const cameraPosition = this.previewVM.getCameraPosition();
    const sceneMode = this.previewVM.getSceneMode();
    const profile = this.previewVM.getProfile();
    await this.cameraManager.start(this.previewVM.surfaceId, cameraPosition, sceneMode, profile);
  }

  exitApp() {
    this.applicationContext.killAllProcesses();
  }

  syncButtonSettings() {
    this.previewManager.setFrameRate(this.previewVM.currentRate, this.previewVM.currentRate);
    this.photoManager.enableMovingPhoto(this.isLivePhoto);
    this.photoManager.setPhotoOutputCallback(this.isSinglePhoto);
  }

  @Builder
  preview() {
    Stack({
      alignContent: Alignment.Center
    }) {
      XComponent({
        type: XComponentType.SURFACE,
        controller: this.previewVM.xComponentController
      })
        .onLoad(async () => {
          await PermissionManager.request(CameraConstant.PERMISSIONS, this.context)
            .catch(() => { this.exitApp() });
          this.previewVM.surfaceId = this.previewVM.xComponentController.getXComponentSurfaceId();
          this.previewVM.setPreviewSize();
          this.previewVM.xComponentController.setXComponentSurfaceRotation({ lock: true })
          await this.startCamera();
          this.initZooms();
          this.initRates();
        })
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.originZoomBeforePinch = this.currentZoom;
              this.isZoomPinching = true;
            })
            .onActionUpdate((event: GestureEvent) => {
              const targetZoom = this.originZoomBeforePinch * event.scale;
              this.currentZoom = limitNumberInRange(targetZoom, this.zoomRange);
              this.cameraManager.setZoomRatio(this.currentZoom);
            })
            .onActionEnd(() => {
              this.isZoomPinching = false;
            })
        )
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
          this.focusBoxPosition = getClampedChildPosition(this.focusBoxSize, {
            width: this.getUIContext().px2vp(previewSize.width),
            height: this.getUIContext().px2vp(previewSize.height)
          }, event)
          this.focusBoxTimer.refresh();
        })
      // gird line
      if (this.isGridLineVisible) {
        GridLine()
      }
      // level indicator
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
      }

      if(this.isDelayTakePhoto){
        Text(`${this.photoRemainder}S`)
          .fontSize(44)
          .fontWeight(FontWeight.Regular)
          .fontColor(Color.White)
      }
    }
    .alignRules({
      middle: { anchor: '__container__', align: HorizontalAlign.Center }
    })
    .width(this.previewVM.getPreviewWidth())
    .height(this.previewVM.getPreviewHeight())
    .margin({ top: this.previewVM.getPreviewTop() })
    .blur(this.blurRadius)
  }

  @Builder
  wakeupMask() {
    Column() {
      Text($r('app.string.wakeup_text'))
        .fontColor(Color.White)
        .opacity(0.6)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .justifyContent(FlexAlign.Center)
    .onClick(async () => {
      this.isSleeping = false;
      this.sleepTimer?.refresh();
      await this.startCamera();
      this.syncButtonSettings();
    })
  }

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

  @Builder
  previewImageButton() {
    SymbolGlyph(
      this.isPreviewImageVisible ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash')
    )
      .funcButtonStyle()
      .onClick(() => {
        this.isPreviewImageVisible = !this.isPreviewImageVisible;
        const message = this.isPreviewImageVisible ? $r('app.string.preview_image_open') : $r('app.string.preview_image_close');
        showToast(this.getUIContext(), message);
      })
  }

  getPreviewImageWidth() {
    const orientation = display.getDefaultDisplaySync().orientation;
    const isLandscape = orientation === display.Orientation.LANDSCAPE_INVERTED
      || orientation === display.Orientation.LANDSCAPE;
    const ratio = this.previewVM.getPreviewRatio();
    const displayRatio = isLandscape ? 1 / ratio : ratio;
    return this.PreviewImageHeight / displayRatio;
  }

  @Builder
  previewImageView() {
    Image(this.previewImage)
      .width(this.getPreviewImageWidth())
      .height(this.PreviewImageHeight)
      .alignRules({
        bottom: { anchor: '__container__', align: VerticalAlign.Bottom },
        left: { anchor: '__container__', align: HorizontalAlign.Start }
      })
      .margin({
        bottom: 10,
        left: 10
      })
  }

  @Builder
  funcButtonsView() {
    Column({ space: 24 }) {
      this.gridLineButton()
      this.levelButton()
      this.previewImageButton()
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

  build() {
    RelativeContainer() {
      this.preview()
      if (this.isPreviewImageVisible) {
        this.previewImageView()
      }
      this.funcButtonsView()
      SettingButtonsView({
        previewVM: this.previewVM,
        cameraManager: this.cameraManager,
        previewManager: this.previewManager,
        photoManager: this.photoManager,
        videoManager: this.videoManager,
        photoDelayTime: this.photoDelayTime,
        isSinglePhoto: this.isSinglePhoto,
        isLivePhoto: this.isLivePhoto
      })
      if (!this.photoRemainder) {
        if (!this.previewVM.isFront) {
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
    .onClick(() => {})
  }
}