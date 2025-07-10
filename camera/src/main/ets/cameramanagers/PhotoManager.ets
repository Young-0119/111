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

import { camera } from '@kit.CameraKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { sensor } from '@kit.SensorServiceKit';
import { Decimal } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { Logger } from 'commons/src/main/ets/utils/Logger';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';
import { colorSpaceManager } from '@kit.ArkGraphics2D';

const LOG_TAG = 'PhotoManager';

export class PhotoManager implements OutputManager {
  output?: camera.PhotoOutput;
  isActive: boolean = true;
  context: Context;
  isSingle: boolean = false;
  private callback: (pixelMap: image.PixelMap, url: string) => void = () => {
  };

  constructor(context: Context, isActive = true, isSingle: boolean) {
    this.context = context;
    this.isActive = isActive;
    this.isSingle = isSingle;
  }

  setIsActive(isActive: boolean) {
    this.isActive = isActive;
  }

  setCallback(callback: (pixelMap: image.PixelMap, url: string) => void) {
    this.callback = callback;
  }

  async createOutput(config: CreateOutputConfig) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    cameraPhotoOutput = this.createPhotoOutput(config.cameraManager, config.device, config.profile);
    if (cameraPhotoOutput) {
      this.output = cameraPhotoOutput;
      this.setPhotoOutputCallback(this.isSingle);
    }
    return cameraPhotoOutput;
  }

  public createPhotoOutput(cameraManager: camera.CameraManager, cameraDevice: camera.CameraDevice,
    profile: camera.Profile) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    const cameraOutputCapability =
      cameraManager.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    let photoProfilesArray: Array<camera.Profile> | undefined = cameraOutputCapability?.photoProfiles;
    if (photoProfilesArray?.length) {
      try {
        const displayRatio = profile.size.width / profile.size.height;
        const profileWidth = profile.size.width;
        const PhotoProfile = photoProfilesArray
          .sort((a, b) => Math.abs(a.size.width - profileWidth) - Math.abs(b.size.width - profileWidth))
          .find(pf => {
            const pfDisplayRatio = pf.size.width / pf.size.height;
            return Math.abs(pfDisplayRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE;
          });
        cameraPhotoOutput = cameraManager.createPhotoOutput(PhotoProfile);
      } catch (error) {
        let err = error as BusinessError;
        Logger.error(LOG_TAG, `Failed to createPhotoOutput. error: ${JSON.stringify(err)}`);
      }
    }
    this.output = cameraPhotoOutput;
    return cameraPhotoOutput;
  }

  async mediaLibSavePhoto(photoAsset: photoAccessHelper.PhotoAsset,
    phAccessHelper: photoAccessHelper.PhotoAccessHelper): Promise<void> {
    try {
      let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        new photoAccessHelper.MediaAssetChangeRequest(photoAsset);
      assetChangeRequest.saveCameraPhoto();
      await phAccessHelper.applyChanges(assetChangeRequest);
      phAccessHelper.release();
    } catch (err) {
      Logger.error(LOG_TAG, `apply saveCameraPhoto failed with error: ${err.code}, ${err.message}`);
    }
  }

  async mediaLibRequestBuffer(photoAsset: photoAccessHelper.PhotoAsset, context: Context,
    callback: (pixelMap: image.PixelMap, url: string) => void) {
    class MediaDataHandler implements photoAccessHelper.MediaAssetDataHandler<ArrayBuffer> {
      onDataPrepared(data: ArrayBuffer) {
        if (data === undefined) {
          Logger.error(LOG_TAG, 'Error occurred when preparing data');
          return;
        }
        let imageSource = image.createImageSource(data);
        imageSource.createPixelMap((err: BusinessError, data: image.PixelMap) => {
          if (err) {
            Logger.info(LOG_TAG, `createPixelMap err:${err.code}`);
            return;
          }
          Logger.info(LOG_TAG, 'createPixelMap is called');
          callback(data, photoAsset.uri);
        })
      }
    }

    let requestOptions: photoAccessHelper.RequestOptions = {
      deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE,
    }
    const handler = new MediaDataHandler();
    await photoAccessHelper.MediaAssetManager.requestImageData(context, photoAsset, requestOptions, handler);
  }

  public setPhotoOutputCbDouble(cameraPhotoOutput: camera.PhotoOutput) {
    cameraPhotoOutput.on('photoAssetAvailable',
      async (_err: BusinessError, photoAsset: photoAccessHelper.PhotoAsset): Promise<void> => {
        let accessHelper: photoAccessHelper.PhotoAccessHelper =
          photoAccessHelper.getPhotoAccessHelper(this.context);
        this.mediaLibSavePhoto(photoAsset, accessHelper);
        this.mediaLibRequestBuffer(photoAsset, this.context, this.callback);
      });
  }

  setPhotoOutputCbSingle(photoOutput: camera.PhotoOutput, context: Context) {
    photoOutput.on('photoAvailable', (errCode: BusinessError, photo: camera.Photo): void => {
      Logger.info(LOG_TAG, 'getPhoto start');
      if (errCode || photo === undefined) {
        Logger.error(LOG_TAG, 'getPhoto failed');
        return;
      }
      this.mediaLibSavePhotoSingle(photo.main, context)
    });
  }

  mediaLibSavePhotoSingle(imageObj: image.Image, context: Context) {
    imageObj.getComponent(image.ComponentType.JPEG, async (errCode: BusinessError, component: image.Component) => {
      Logger.info(LOG_TAG, 'getComponent start');
      if (errCode || component === undefined) {
        Logger.error(LOG_TAG, 'getComponent failed');
        return;
      }
      let buffer: ArrayBuffer;
      if (component.byteBuffer) {
        buffer = component.byteBuffer;
      } else {
        Logger.error(LOG_TAG, 'byteBuffer is null');
        return;
      }
      let photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
      let extension: string = 'jpg';
      let options: photoAccessHelper.CreateOptions = {
        title: 'testPhoto'
      }
      let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context, photoType, extension, options);
      assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, buffer)
      assetChangeRequest.saveCameraPhoto();
      let accessHelper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context);
      await accessHelper.applyChanges(assetChangeRequest);
      let imageSource = image.createImageSource(buffer);
      let pixelmap = imageSource.createPixelMapSync();
      this.callback(pixelmap, assetChangeRequest.getAsset().uri);
      accessHelper.release();
      imageObj.release();
    });
  }

  setPhotoOutputCallback(isSingle: boolean) {
    if (!this.output) {
      return;
    }
    if (isSingle) {
      this.output?.off('photoAssetAvailable');
      this.setPhotoOutputCbSingle(this.output, this.context);
    } else {
      this.output?.off('photoAvailable');
      this.setPhotoOutputCbDouble(this.output);
    }
  }

  preparePhoto(session: camera.Session, zoomRatio?: number, flashMode?: camera.FlashMode,
    focusMode?: camera.FocusMode) {
    const photoSession = session as camera.PhotoSession;
    this.setPhotoFlash(photoSession, flashMode);
    this.setPhotoFocus(photoSession, focusMode);
    this.setPhotoZoomRatio(photoSession, zoomRatio || 0);
  }

  public checkFlash(photoSession: camera.PhotoSession) {
    let flashModeStatus: boolean = false;
    if (photoSession.hasFlash()) {
      flashModeStatus = photoSession.isFlashModeSupported(camera.FlashMode.FLASH_MODE_AUTO);
    }
    return flashModeStatus;
  }

  public setPhotoFlash(photoSession: camera.PhotoSession, flashMode?: camera.FlashMode) {
    try {
      if (this.checkFlash(photoSession)) {
        photoSession.setFlashMode(flashMode || camera.FlashMode.FLASH_MODE_CLOSE);
      }
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG, `Failed to hasFlash. error: ${JSON.stringify(err)}`);
    }
  }

  public setPhotoFocus(photoSession: camera.PhotoSession, focusMode?: camera.FocusMode) {
    const defaultMode = camera.FocusMode.FOCUS_MODE_CONTINUOUS_AUTO;
    try {
      let focusModeStatus: boolean = photoSession.isFocusModeSupported(focusMode || defaultMode);
      if (focusModeStatus) {
        photoSession.setFocusMode(focusMode || defaultMode);
      }
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG, `Failed to check whether the focus mode is supported. error: ${JSON.stringify(err)}`);
    }
  }

  public setFocusPoint(photoSession: camera.PhotoSession, focusPoint: camera.Point): void {
    try {
      photoSession.setFocusPoint(focusPoint);
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG, `The setFocusPoint call failed. error code: ${err.code}`);
    }
  }

  public setPhotoZoomRatio(photoSession: camera.PhotoSession, zoomRatio?: number) {
    let photoZoomRatio = 0;
    if (!zoomRatio) {
      try {
        let zoomRatioRange: number[] = photoSession.getZoomRatioRange();
        if (zoomRatioRange?.length) {
          photoZoomRatio = zoomRatioRange[0];
        }
      } catch (error) {
        let err = error as BusinessError;
        Logger.error(LOG_TAG, `Failed to get the zoom ratio range. error: ${JSON.stringify(err)}`);
      }
    }
    photoSession.setZoomRatio(zoomRatio || photoZoomRatio);
  }

  getSupportedColorSpaces(session: camera.PhotoSession): Array<colorSpaceManager.ColorSpace> {
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = [];
    try {
      colorSpaces = session.getSupportedColorSpaces();
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG,`The getSupportedColorSpaces call failed. error code: ${err.code}`);
    }
    return colorSpaces;
  }

  setColorSpaceBeforeCommitConfig(session: camera.PhotoSession, isHdr: boolean): void {
    let colorSpace: colorSpaceManager.ColorSpace =
      isHdr ? colorSpaceManager.ColorSpace.DISPLAY_P3 : colorSpaceManager.ColorSpace.SRGB;
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = this.getSupportedColorSpaces(session);
    let isSupportedColorSpaces = colorSpaces.indexOf(colorSpace) >= 0;
    if (isSupportedColorSpaces) {
      session.setColorSpace(colorSpace);
    } else {
      Logger.info(LOG_TAG,`colorSpace: ${colorSpace} is not support`);
    }
  }

  public async capture(isFront: boolean) {
    const rotation = await this.getPhotoRotation(isFront);
    let settings: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation,
      mirror: isFront
    };
    this.output?.capture(settings, (err: BusinessError) => {
      if (err) {
        Logger.error(LOG_TAG, `Failed to capture the photo. error: ${JSON.stringify(err)}`);
        return;
      }

      Logger.info(LOG_TAG, 'Callback invoked to indicate the photo capture request success.');
    });
  }

  private calculateDeviceDegree(x: number, y: number, z: number): number {
    let deviceDegree: number = 0;
    if ((x * x + y * y) * 3 < z * z) {
      return deviceDegree;
    } else {
      let sd: Decimal = Decimal.atan2(y, -x);
      let sc: Decimal = Decimal.round(Number(sd) / Math.PI * 180);
      deviceDegree = 90 - Number(sc);
      deviceDegree = deviceDegree >= 0 ? deviceDegree % 360 : deviceDegree % 360 + 360;
    }
    return deviceDegree;
  }

  private getPhotoRotation(isFront: boolean) {
    const promise: Promise<number> = new Promise(resolve => {
      let rotation = camera.ImageRotation.ROTATION_0;
      sensor.once(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
        let degree = this.calculateDeviceDegree(data.x, data.y, data.z);
        if (degree >= 0 && (degree <= 30 || degree >= 300)) {
          rotation = camera.ImageRotation.ROTATION_0;
        } else if (degree > 30 && degree <= 120) {
          rotation = isFront ? camera.ImageRotation.ROTATION_270 : camera.ImageRotation.ROTATION_90;
        } else if (degree > 120 && degree <= 210) {
          rotation = camera.ImageRotation.ROTATION_180;
        } else if (degree > 210 && degree < 300) {
          rotation = isFront ? camera.ImageRotation.ROTATION_90 : camera.ImageRotation.ROTATION_270;
        }
        resolve(rotation);
      });
    })
    return promise;
  }

  public isMovingPhotoSupported(photoOutput: camera.PhotoOutput): boolean {
    let isSupported: boolean = false;
    try {
      isSupported = photoOutput.isMovingPhotoSupported();
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG, `The isMovingPhotoSupported call failed. error code: ${err.code}`);
    }
    return isSupported;
  }

  public enableMovingPhoto(enabled: boolean): void {
    try {
      this.output?.enableMovingPhoto(enabled);
    } catch (error) {
      let err = error as BusinessError;
      Logger.error(LOG_TAG, `The enableMovingPhoto call failed. error code: ${err.code}`);
    }
  }

  async release() {
    await this.output?.release();
    if (this.isSingle) {
      this.output?.off('photoAvailable');
    } else {
      this.output?.off('photoAssetAvailable');
    }
    this.output = undefined;
  }
}
