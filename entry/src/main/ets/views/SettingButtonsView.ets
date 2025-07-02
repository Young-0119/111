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

import { camera } from "@kit.CameraKit";
import { AVRecorderState, CameraManager, PhotoManager, PreviewManager, VideoManager } from "camera";
import PreviewViewModel from "../viewmodels/PreviewViewModel";

@Component
struct SettingButtonsView {
  private flashImageMap: Map<camera.FlashMode, Resource> = new Map([
    [camera.FlashMode.FLASH_MODE_CLOSE, $r('sys.symbol.camera_flash_slash')],
    [camera.FlashMode.FLASH_MODE_OPEN, $r('sys.symbol.camera_flash')],
    [camera.FlashMode.FLASH_MODE_AUTO, $r('sys.symbol.camera_flash_auto')],
    [camera.FlashMode.FLASH_MODE_ALWAYS_OPEN, $r('sys.symbol.lightbulb_1')],
  ]);
  private photoFlashMenuTitleMap: Map<ResourceStr, camera.FlashMode> = new Map([
    ['off', camera.FlashMode.FLASH_MODE_CLOSE],
    ['on', camera.FlashMode.FLASH_MODE_OPEN],
    ['auto', camera.FlashMode.FLASH_MODE_AUTO],
    ['always_on', camera.FlashMode.FLASH_MODE_ALWAYS_OPEN]
  ]);
  private videoFlashMenuTitleMap: Map<ResourceStr, camera.FlashMode> = new Map([
    ['off', camera.FlashMode.FLASH_MODE_CLOSE],
    ['always_on', camera.FlashMode.FLASH_MODE_ALWAYS_OPEN]
  ]);
  @State flashMode: camera.FlashMode = camera.FlashMode.FLASH_MODE_CLOSE;
  @Link isLivePhoto: boolean;
  @Require cameraManager: CameraManager;
  @Require previewManager: PreviewManager;
  @Require photoManager: PhotoManager;
  @Link videoManager: VideoManager;
  @Link photoDelayTime: number;
  @State isStabilizationEnabled: boolean = false;
  @Link isSinglePhoto: boolean;
  @Link previewVM: PreviewViewModel;

  getFlashMenuElements(flashMenuTitleMap: Map<ResourceStr, camera.FlashMode>): MenuElement[] {
    return Array.from(flashMenuTitleMap.keys()).map(text => {
      const flashMode = flashMenuTitleMap.get(text);
      const menuElement: MenuElement = {
        value: text,
        action: () => {
          this.flashMode = flashMode!;
          this.cameraManager.setFlashMode(this.flashMode);
        }
      };
      return menuElement;
    });
  }

  @Builder
  flashButton(flashMenuElements: MenuElement[]) {
    SymbolGlyph(this.flashImageMap.get(this.flashMode))
      .fontSize(22)
      .fontColor([Color.White])
      .bindMenu(flashMenuElements)
  }

  @Builder
  videoTimerBuilder() {
    if (this.videoManager.isRecording()) {
      Row({ space: 5 }) {
        SymbolGlyph(this.videoManager.state === AVRecorderState.STARTED ? $r('sys.symbol.record_circle') :
        $r('sys.symbol.pause'))
          .fontSize(22)
          .fontColor(this.videoManager.state === AVRecorderState.STARTED ? [Color.Red, 'rgba(255,0,0,0)'] :
            [Color.White])
          .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_COLOR)
        Text(this.videoManager.state === AVRecorderState.STARTED ? $r('app.string.recording') : $r('app.string.paused'))
          .fontColor(Color.White)
          .fontSize(12)
      }
    }
  }

  @Builder
  livePhotoButton() {
    SymbolGlyph(this.isLivePhoto
      ? $r('sys.symbol.livephoto')
      : $r('sys.symbol.livephoto_slash'))
      .onClick(() => {
        this.isLivePhoto = !this.isLivePhoto
        this.photoManager.enableMovingPhoto(this.isLivePhoto)
      })
      .fontSize(22)
      .fontColor([Color.White])
  }

  @Builder
  rateButton() {
    if (this.previewVM.rates) {
      Text(`${this.previewVM.currentRate} fps`)
        .fontColor(Color.White)
        .fontSize(16)
        .bindMenu(this.previewVM.rates.map(rate => {
          const menuElement: MenuElement = {
            value: rate + 'fps',
            action: () => {
              this.previewManager.setFrameRate(rate, rate);
              this.previewVM.currentRate = rate;
            }
          };
          return menuElement;
        }))
    }
  }

  @Builder
  delayPhotoButton(photoDelayTimeElements: MenuElement[]) {
    if (this.photoDelayTime) {
      Text(`${this.photoDelayTime}s`)
        .fontColor(Color.White)
        .fontSize(16)
        .bindMenu(photoDelayTimeElements)
    } else {
      SymbolGlyph($r('sys.symbol.time_lapse'))
        .fontSize(22)
        .fontColor([Color.White])
        .bindMenu(photoDelayTimeElements)
    }
  }

  getPhotoDelayTimeElements(): MenuElement[] {
    const menuTextMap: Map<string, number> = new Map([
      ['off', 0],
      ['2s', 2],
      ['5s', 5],
      ['10s', 10]
    ])
    return Array.from(menuTextMap.keys()).map(text => {
      const time = menuTextMap.get(text);
      const menuElement: MenuElement = {
        value: text,
        action: () => {
          this.photoDelayTime = time!
        }
      };
      return menuElement;
    });
  }

  @Builder
  stabilizationButton() {
    SymbolGlyph(this.isStabilizationEnabled
      ? $r('sys.symbol.motion_stabilization')
      : $r('sys.symbol.motion_stabilization_slash'))
      .onClick(() => {
        this.isStabilizationEnabled = !this.isStabilizationEnabled;
        this.cameraManager.setVideoStabilizationMode(camera.VideoStabilizationMode.AUTO);
      })
      .fontSize(22)
      .fontColor([Color.White])
  }

  @Builder
  togglePhotoModeButton() {
    SymbolGlyph(this.isSinglePhoto
      ? $r('sys.symbol.picture')
      : $r('sys.symbol.picture_on_square_1'))
      .onClick(() => {
        this.isSinglePhoto = !this.isSinglePhoto;
        this.photoManager.setPhotoOutputCallback(this.isSinglePhoto);
        if (this.isSinglePhoto) {
          this.isLivePhoto = false;
        }
        this.photoManager.enableMovingPhoto(this.isLivePhoto);
      })
      .fontSize(22)
      .fontColor([Color.White])
  }

  build() {
    Row() {
      if (this.previewVM.isPhotoMode()) {
        this.rateButton()
        this.flashButton(this.getFlashMenuElements(this.photoFlashMenuTitleMap))
        this.delayPhotoButton(this.getPhotoDelayTimeElements())
        if (!this.isSinglePhoto) {
          this.livePhotoButton()
        }
        this.togglePhotoModeButton()
      } else {
        if (this.videoManager.isRecording()) {
          this.videoTimerBuilder()
        } else {
          this.rateButton()
          this.flashButton(this.getFlashMenuElements(this.videoFlashMenuTitleMap))
          this.stabilizationButton()
        }
      }
    }
    .id('settingButtonsView')
    .width('100%')
    .margin({ top: 50 })
    .justifyContent(FlexAlign.SpaceAround)
    .alignRules({ top: { anchor: '__container__', align: VerticalAlign.Top } })
  }
}

export default SettingButtonsView;