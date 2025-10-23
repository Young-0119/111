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

import { curves, display } from '@kit.ArkUI';
import { camera } from '@kit.CameraKit';
import WindowUtil from '../utils/WindowUtil';
import CameraConstant from '../constants/Constants';
import { Logger } from 'commons';
import { WatermarkInfo } from 'commons/src/main/ets/utils/ImageWatermarkUtil';

export enum CameraMode {
  PHOTO,
  VIDEO
}

const TAG = 'PreviewViewModel';

/**
 * States and methods related to preview.
 */
class PreviewViewModel {
  private uiContext: UIContext;
  // [Start isFront]
  isFront: boolean = false;
  // [StartExclude isFront]
  cameraMode: CameraMode = CameraMode.PHOTO;
  xComponentController: XComponentController = new XComponentController();
  surfaceId: string = '';
  previewSize: Size = WindowUtil.getMaxDisplaySize(CameraConstant.RATIO_PHOTO);
  rates?: number[] = [];
  currentRate: number = 0;
  blurRadius: number = 0;
  blurRotation: RotateOptions = { y: 0.5, angle: 0 };
  
  // 水印相关状态
  watermarkInfo: WatermarkInfo = {
    timestamp: this.getCurrentTimestamp(),
    weather: '晴朗',
    location: '北京市朝阳区',
    altitude: '50米',
    direction: '北偏东30度',
    longitude: '116.4074°',
    latitude: '39.9042°',
    organization: '消防救援支队'
  };
  isWatermarkEnabled: boolean = true; // 水印功能开关

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  // [EndExclude isFront]
  getCameraPosition() {
    return this.isFront
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
  }

  // [End isFront]

  getPreviewRatio() {
    return this.cameraMode === CameraMode.PHOTO
      ? CameraConstant.RATIO_PHOTO
      : CameraConstant.RATIO_VIDEO;
  }

  getSceneMode() {
    return this.cameraMode === CameraMode.PHOTO
      ? camera.SceneMode.NORMAL_PHOTO
      : camera.SceneMode.NORMAL_VIDEO;
  }

  // [Start getProfile]
  getProfile: (cameraOrientation: number) => camera.Profile = cameraOrientation => {
    const displaySize: Size = WindowUtil.getMaxDisplaySize(this.getPreviewRatio());
    let displayDefault: display.Display | null = null;
    try {
      displayDefault = display.getDefaultDisplaySync();
    } catch (exception) {
      Logger.error(TAG, `getDefaultDisplaySync failed, code is ${exception.code}, message is ${exception.message}`);
    }
    const displayRotation = (displayDefault?.rotation ?? 0) * 90;
    const isRevert = (cameraOrientation + displayRotation) % 180 !== 0;
    return {
      format: camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP,
      size: {
        height: isRevert ? displaySize.width : displaySize.height,
        width: isRevert ? displaySize.height : displaySize.width
      }
    };
  }

  // [End getProfile]

  // [Start setPreviewSize]
  setPreviewSize() {
    const displaySize: Size = WindowUtil.getMaxDisplaySize(this.getPreviewRatio());
    this.previewSize = displaySize;
    this.xComponentController.setXComponentSurfaceRect({
      surfaceWidth: displaySize.width,
      surfaceHeight: displaySize.height
    });
  }

  // [End setPreviewSize]

  getPreviewTop() {
    const previewRatio = this.getPreviewRatio();
    return WindowUtil.getWindowRatio() > previewRatio ? 85 : 0;
  }

  getPreviewWidth() {
    return this.uiContext.px2vp(this.previewSize.width);
  }

  getPreviewHeight() {
    return this.uiContext.px2vp(this.previewSize.height);
  }

  isPhotoMode() {
    return this.cameraMode === CameraMode.PHOTO;
  }

  isVideoMode() {
    return this.cameraMode === CameraMode.VIDEO;
  }

  isCurrentCameraMode(mode: CameraMode) {
    return this.cameraMode === mode;
  }

  openPreviewBlur() {
    animateToImmediately({
      duration: 200,
      curve: Curve.Friction
    }, () => {
      this.blurRadius = 150;
    });
  }

  rotatePreviewBlur() {
    animateToImmediately({
      delay: 50,
      duration: 200,
      curve: curves.cubicBezierCurve(0.2, 0, 0.83, 1),
      onFinish: () => {
        this.rotatePreviewBlurSecond();
      }
    }, () => {
      this.blurRotation = { y: 0.5, angle: 90 };
    });
  }

  rotatePreviewBlurSecond() {
    this.blurRotation = { y: 0.5, angle: 270 };
    animateToImmediately({
      duration: 200,
      curve: curves.cubicBezierCurve(0.17, 0, 0.2, 1),
      onFinish: () => {
        this.blurRotation = { y: 0.5, angle: 0 };
      }
    }, () => {
      this.blurRotation = { y: 0.5, angle: 360 };
    });
  }

  closePreviewBlur() {
    animateToImmediately({
      duration: 200,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.blurRadius = 0;
    });
  }

  // 水印相关方法
  getCurrentTimestamp(): string {
    const now = new Date();
    const year = now.getFullYear();
    const month = String(now.getMonth() + 1).padStart(2, '0');
    const day = String(now.getDate()).padStart(2, '0');
    const hours = String(now.getHours()).padStart(2, '0');
    const minutes = String(now.getMinutes()).padStart(2, '0');
    const seconds = String(now.getSeconds()).padStart(2, '0');
    return `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
  }

  // 获取用于显示的水印信息
  getWatermarkInfoForDisplay(): WatermarkInfo {
    return {
      timestamp: this.getCurrentTimestamp(),
      weather: this.watermarkInfo.weather,
      location: this.watermarkInfo.location,
      altitude: this.watermarkInfo.altitude,
      direction: this.watermarkInfo.direction,
      longitude: this.watermarkInfo.longitude,
      latitude: this.watermarkInfo.latitude,
      organization: this.watermarkInfo.organization
    };
  }

  // 获取用于处理的水印信息（确保时间准确）
  getWatermarkInfoForProcessing(): WatermarkInfo {
    return {
      timestamp: this.getCurrentTimestamp(),
      weather: this.watermarkInfo.weather,
      location: this.watermarkInfo.location,
      altitude: this.watermarkInfo.altitude,
      direction: this.watermarkInfo.direction,
      longitude: this.watermarkInfo.longitude,
      latitude: this.watermarkInfo.latitude,
      organization: this.watermarkInfo.organization
    };
  }

  // 更新水印信息
  updateWatermarkInfo(
    timestamp?: string,
    weather?: string,
    location?: string,
    altitude?: string,
    direction?: string,
    longitude?: string,
    latitude?: string,
    organization?: string
  ): void {
    if (timestamp !== undefined) {
      this.watermarkInfo.timestamp = timestamp;
    }
    if (weather !== undefined) {
      this.watermarkInfo.weather = weather;
    }
    if (location !== undefined) {
      this.watermarkInfo.location = location;
    }
    if (altitude !== undefined) {
      this.watermarkInfo.altitude = altitude;
    }
    if (direction !== undefined) {
      this.watermarkInfo.direction = direction;
    }
    if (longitude !== undefined) {
      this.watermarkInfo.longitude = longitude;
    }
    if (latitude !== undefined) {
      this.watermarkInfo.latitude = latitude;
    }
    if (organization !== undefined) {
      this.watermarkInfo.organization = organization;
    }
  }

  // 切换水印开关
  toggleWatermark(): void {
    this.isWatermarkEnabled = !this.isWatermarkEnabled;
  }

  // 设置水印开关
  setWatermarkEnabled(enabled: boolean): void {
    this.isWatermarkEnabled = enabled;
  }

  // 获取水印开关状态
  isWatermarkEnabledStatus(): boolean {
    return this.isWatermarkEnabled;
  }
}

export default PreviewViewModel;