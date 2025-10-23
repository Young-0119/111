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
import { colorSpaceManager } from '@kit.ArkGraphics2D';
import { geoLocationManager } from '@kit.LocationKit';
import { Logger } from 'commons';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';
import { ImageWatermarkUtil, WatermarkInfo } from 'commons/src/main/ets/utils/ImageWatermarkUtil';

const TAG_LOG = 'PhotoManager';

export class PhotoManager implements OutputManager {
  output?: camera.PhotoOutput;
  isActive: boolean = true;
  context: Context;
  isSingle: boolean = false;
  location: geoLocationManager.Location | null = null;
  private watermarkInfo: WatermarkInfo | null = null;
  private isWatermarkEnabled: boolean = false;
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

  setWatermarkInfo(watermarkInfo: WatermarkInfo | null) {
    this.watermarkInfo = watermarkInfo;
  }

  setWatermarkEnabled(enabled: boolean) {
    this.isWatermarkEnabled = enabled;
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

  // [Start create_photo_output]
  // Create photo output
  public createPhotoOutput(cameraManager: camera.CameraManager|undefined, cameraDevice: camera.CameraDevice,
    profile: camera.Profile) {
    let cameraPhotoOutput: camera.PhotoOutput | undefined = undefined;
    const cameraOutputCapability =
      cameraManager?.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    let photoProfilesArray: camera.Profile[] | undefined = cameraOutputCapability?.photoProfiles;
    if (photoProfilesArray?.length) {
      try {
        const displayRatio = profile.size.width / profile.size.height;
        const profileWidth = profile.size.width;
        const photoProfile = photoProfilesArray
          .sort((a, b) => Math.abs(a.size.width - profileWidth) - Math.abs(b.size.width - profileWidth))
          .find(pf => {
            const pfDisplayRatio = pf.size.width / pf.size.height;
            return Math.abs(pfDisplayRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE &&
              pf.format === camera.CameraFormat.CAMERA_FORMAT_JPEG;
          });
        if (!photoProfile) {
          Logger.error(TAG_LOG, 'Failed to get photo profile');
          return;
        }
        cameraPhotoOutput = cameraManager?.createPhotoOutput(photoProfile);
      } catch (error) {
        Logger.error(TAG_LOG, `Failed to createPhotoOutput. error: ${JSON.stringify(error)}`);
      }
    }
    this.output = cameraPhotoOutput;
    return cameraPhotoOutput;
  }

  // [End create_photo_output]

  // [Start set_photo_cb_double]
  // Save camera photo
  async mediaLibSavePhoto(photoAsset: photoAccessHelper.PhotoAsset,
    phAccessHelper: photoAccessHelper.PhotoAccessHelper): Promise<void> {
    try {
      let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
        new photoAccessHelper.MediaAssetChangeRequest(photoAsset);
      assetChangeRequest.saveCameraPhoto();
      await phAccessHelper.applyChanges(assetChangeRequest);
      phAccessHelper.release();
    } catch (error) {
      Logger.error(TAG_LOG, `apply saveCameraPhoto failed with error: ${error.code}, ${error.message}`);
    }
  }

  async mediaLibRequestBuffer(photoAsset: photoAccessHelper.PhotoAsset, context: Context,
    callback: (pixelMap: image.PixelMap, url: string) => void) {
    Logger.info(TAG_LOG, 'mediaLibRequestBuffer called (without watermark)');
    
    class MediaDataHandler implements photoAccessHelper.MediaAssetDataHandler<ArrayBuffer> {
      onDataPrepared(data: ArrayBuffer) {
        Logger.info(TAG_LOG, 'onDataPrepared called in MediaDataHandler (without watermark)');
        if (data === undefined) {
          Logger.error(TAG_LOG, 'Error occurred when preparing data - data is undefined (without watermark)');
          return;
        }
        Logger.info(TAG_LOG, `Data size: ${data.byteLength} bytes (without watermark)`);
        
        let imageSource = image.createImageSource(data);
        imageSource.createPixelMap().then((pixelMap: image.PixelMap) => {
          Logger.info(TAG_LOG, 'PixelMap created successfully, calling callback (without watermark)');
          callback(pixelMap, photoAsset.uri);
        }).catch((err: BusinessError) => {
          Logger.error(TAG_LOG, `createPixelMap err:${err.code}, message: ${err.message}`);
        })
      }
    }

    let requestOptions: photoAccessHelper.RequestOptions = {
      deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE,
    }
    const handler = new MediaDataHandler();
    try {
      Logger.info(TAG_LOG, 'Calling MediaAssetManager.requestImageData (without watermark)');
      await photoAccessHelper.MediaAssetManager.requestImageData(context, photoAsset, requestOptions, handler);
      Logger.info(TAG_LOG, 'MediaAssetManager.requestImageData called successfully (without watermark)');
    } catch (exception) {
      Logger.error(TAG_LOG, `requestImageData failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  async mediaLibRequestBufferWithWatermark(photoAsset: photoAccessHelper.PhotoAsset, context: Context,
    callback: (pixelMap: image.PixelMap, url: string) => void) {
    Logger.info(TAG_LOG, 'mediaLibRequestBufferWithWatermark called');
    
    class MediaDataHandler implements photoAccessHelper.MediaAssetDataHandler<ArrayBuffer> {
      async onDataPrepared(data: ArrayBuffer) {
        Logger.info(TAG_LOG, 'onDataPrepared called in MediaDataHandler');
        if (data === undefined) {
          Logger.error(TAG_LOG, 'Error occurred when preparing data - data is undefined');
          return;
        }
        
        Logger.info(TAG_LOG, `Original data size: ${data.byteLength} bytes`);
        let processedData = data;
        
        // 如果启用了水印且有水印信息，处理水印
        if (photoManager.isWatermarkEnabled && photoManager.watermarkInfo) {
          try {
            Logger.info(TAG_LOG, 'Adding watermark to photo in double callback mode...');
            Logger.info(TAG_LOG, `Watermark info: ${JSON.stringify(photoManager.watermarkInfo)}`);
            processedData = await ImageWatermarkUtil.addWatermarkToPhoto(data, photoManager.watermarkInfo);
            Logger.info(TAG_LOG, `Processed data size: ${processedData.byteLength} bytes`);
            Logger.info(TAG_LOG, 'Watermark added successfully in double callback mode');
          } catch (error) {
            Logger.error(TAG_LOG, `Failed to add watermark in double callback mode: ${JSON.stringify(error)}`);
            // 如果水印处理失败，继续使用原始图片数据
            processedData = data;
          }
        } else {
          Logger.info(TAG_LOG, 'Watermark not applied in double callback mode');
        }
        
        Logger.info(TAG_LOG, 'Creating PixelMap from processed data');
        let imageSource = image.createImageSource(processedData);
        imageSource.createPixelMap().then((pixelMap: image.PixelMap) => {
          Logger.info(TAG_LOG, 'PixelMap created successfully, calling callback');
          callback(pixelMap, photoAsset.uri);
        }).catch((err: BusinessError) => {
          Logger.error(TAG_LOG, `createPixelMap err:${err.code}, message: ${err.message}`);
        })
      }
    }

    let requestOptions: photoAccessHelper.RequestOptions = {
      deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE,
    }
    const photoManager = this; // 保存this引用
    const handler = new MediaDataHandler();
    try {
      Logger.info(TAG_LOG, 'Calling MediaAssetManager.requestImageData with watermark');
      await photoAccessHelper.MediaAssetManager.requestImageData(context, photoAsset, requestOptions, handler);
      Logger.info(TAG_LOG, 'MediaAssetManager.requestImageData called successfully');
    } catch (exception) {
      Logger.error(TAG_LOG, `requestImageData with watermark failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  public setPhotoOutputCbDouble(cameraPhotoOutput: camera.PhotoOutput) {
    Logger.info(TAG_LOG, 'Setting up photoAssetAvailable callback for double photo mode');
    cameraPhotoOutput.on('photoAssetAvailable',
      async (_err: BusinessError, photoAsset: photoAccessHelper.PhotoAsset): Promise<void> => {
        Logger.info(TAG_LOG, 'photoAssetAvailable callback triggered');
        Logger.info(TAG_LOG, `Current watermark state in double mode - Enabled: ${this.isWatermarkEnabled}, Info: ${JSON.stringify(this.watermarkInfo)}`);
        
        let accessHelper: photoAccessHelper.PhotoAccessHelper =
          photoAccessHelper.getPhotoAccessHelper(this.context);
        this.mediaLibSavePhoto(photoAsset, accessHelper);
        
        // 修改这里：如果启用了水印，使用新的带水印处理的buffer回调
        if (this.isWatermarkEnabled && this.watermarkInfo) {
          Logger.info(TAG_LOG, 'Requesting buffer with watermark for double photo mode');
          this.mediaLibRequestBufferWithWatermark(photoAsset, this.context, this.callback);
        } else {
          Logger.info(TAG_LOG, 'Requesting buffer without watermark for double photo mode');
          this.mediaLibRequestBuffer(photoAsset, this.context, this.callback);
        }
      });
  }

  // [End set_photo_cb_double]

  // [Start set_photo_cb_single]
  // Set photo callback single
  setPhotoOutputCbSingle(photoOutput: camera.PhotoOutput, context: Context) {
    Logger.info(TAG_LOG, 'Setting up photoAvailable callback for single photo mode');
    photoOutput.on('photoAvailable', (errCode: BusinessError, photo: camera.Photo): void => {
      Logger.info(TAG_LOG, 'photoAvailable callback triggered');
      if (errCode || photo === undefined) {
        Logger.error(TAG_LOG, `getPhoto failed, errCode: ${errCode}, photo: ${photo}`);
        return;
      }
      Logger.info(TAG_LOG, 'Photo object received, calling mediaLibSavePhotoSingle');
      this.mediaLibSavePhotoSingle(context, photo.main)
    });
  }

  // [End set_photo_cb_single]

  // [Start save_photo_single]
  // Save photo single
  mediaLibSavePhotoSingle(context: Context, imageObj: image.Image) {
    Logger.info(TAG_LOG, 'mediaLibSavePhotoSingle called');
    Logger.info(TAG_LOG, `Current watermark state - Enabled: ${this.isWatermarkEnabled}, Info: ${JSON.stringify(this.watermarkInfo)}`);
    
    imageObj.getComponent(image.ComponentType.JPEG, async (errCode: BusinessError, component: image.Component) => {
      if (errCode || component === undefined) {
        Logger.error(TAG_LOG, `getComponent failed, errCode: ${errCode}, component: ${component}`);
        return;
      }
      
      try {
        let buffer: ArrayBuffer = component.byteBuffer;
        if (!buffer) {
          Logger.error(TAG_LOG, 'byteBuffer is null');
          return;
        }
        
        Logger.info(TAG_LOG, `Buffer received, size: ${buffer.byteLength} bytes`);
        
        // 如果启用了水印且有水印信息，处理水印
        Logger.info(TAG_LOG, `Checking watermark conditions - isWatermarkEnabled: ${this.isWatermarkEnabled}, watermarkInfo: ${!!this.watermarkInfo}`);
        if (this.isWatermarkEnabled && this.watermarkInfo) {
          try {
            Logger.info(TAG_LOG, `Adding watermark to photo... Enabled: ${this.isWatermarkEnabled}, Info: ${JSON.stringify(this.watermarkInfo)}`);
            Logger.info(TAG_LOG, `Original buffer size: ${buffer.byteLength} bytes`);
            buffer = await ImageWatermarkUtil.addWatermarkToPhoto(buffer, this.watermarkInfo);
            Logger.info(TAG_LOG, `Processed buffer size: ${buffer.byteLength} bytes`);
            Logger.info(TAG_LOG, 'Watermark added successfully');
          } catch (error) {
            Logger.error(TAG_LOG, `Failed to add watermark: ${JSON.stringify(error)}`);
            // 如果水印处理失败，继续使用原始图片
          }
        } else {
          Logger.info(TAG_LOG, `Watermark not applied. Enabled: ${this.isWatermarkEnabled}, Info: ${JSON.stringify(this.watermarkInfo)}`);
        }
        
        let photoType: photoAccessHelper.PhotoType = photoAccessHelper.PhotoType.IMAGE;
        let extension: string = 'jpg';
        let options: photoAccessHelper.CreateOptions = {
          title: 'testPhoto'
        }
        try {
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
          Logger.info(TAG_LOG, 'Photo saved successfully with watermark');
        } catch (exception) {
          Logger.error(TAG_LOG,
            `mediaLibSavePhotoSingle failed, code is ${exception.code}, message is ${exception.message}`);
        }
      } catch (innerError) {
        Logger.error(TAG_LOG, `Error in getComponent callback: ${JSON.stringify(innerError)}`);
      }
    });
  }

  // [End save_photo_single]

  setPhotoOutputCallback(isSingle: boolean) {
    Logger.info(TAG_LOG, `setPhotoOutputCallback called with isSingle: ${isSingle}`);
    if (!this.output) {
      Logger.error(TAG_LOG, 'Cannot set photo output callback - output is null');
      return;
    }
    if (isSingle) {
      Logger.info(TAG_LOG, 'Setting up single photo mode callbacks');
      this.output?.off('photoAssetAvailable');
      this.setPhotoOutputCbSingle(this.output, this.context);
    } else {
      Logger.info(TAG_LOG, 'Setting up double photo mode callbacks');
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

  // [Start set_color_space]
  // Set color space
  setColorSpaceBeforeCommitConfig(session: camera.PhotoSession, isHdr: boolean): void {
    // The isHdr flag indicates whether HDR mode is enabled, with true representing the use of the DISPLAY_P3 color space.
    let colorSpace: colorSpaceManager.ColorSpace =
      isHdr ? colorSpaceManager.ColorSpace.DISPLAY_P3 : colorSpaceManager.ColorSpace.SRGB;
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = [];
    try {
      colorSpaces = session.getSupportedColorSpaces();
    } catch (error) {
      Logger.error(TAG_LOG, `The getSupportedColorSpaces call failed. error code: ${error.code}`);
    }
    if (!colorSpaces.includes(colorSpace)) {
      Logger.info(TAG_LOG, `colorSpace: ${colorSpace} is not support`);
      return;
    }
    try {
      Logger.info(TAG_LOG, `setColorSpace: ${colorSpace}`);
      session.setColorSpace(colorSpace);
    } catch (exception) {
      Logger.error(TAG_LOG, `setColorSpace failed, code is ${exception.code}, message is ${exception.message}`);
    }
    try {
      let activeColorSpace: colorSpaceManager.ColorSpace = session.getActiveColorSpace();
      Logger.info(TAG_LOG, `activeColorSpace: ${activeColorSpace}`);
    } catch (error) {
      Logger.error(TAG_LOG, `getActiveColorSpace Faild: ${error.message}`);
    }
  }

  // [End set_color_space]

  public checkFlash(photoSession: camera.PhotoSession) {
    let flashModeStatus: boolean = false;
    try {
      if (photoSession.hasFlash()) {
        flashModeStatus = photoSession.isFlashModeSupported(camera.FlashMode.FLASH_MODE_AUTO);
      }
    } catch (exception) {
      Logger.error(TAG_LOG, `checkFlash failed, code is ${exception.code}, message is ${exception.message}`);
    }
    return flashModeStatus;
  }

  public setPhotoFlash(photoSession: camera.PhotoSession, flashMode?: camera.FlashMode) {
    try {
      if (this.checkFlash(photoSession)) {
        photoSession.setFlashMode(flashMode || camera.FlashMode.FLASH_MODE_CLOSE);
      }
    } catch (error) {
      Logger.error(TAG_LOG, `Failed to hasFlash. error: ${JSON.stringify(error)}`);
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
      Logger.error(TAG_LOG,
        `Failed to check whether the focus mode is supported. error: ${JSON.stringify(error)}`);
    }
  }

  public setFocusPoint(photoSession: camera.PhotoSession, focusPoint: camera.Point): void {
    try {
      photoSession.setFocusPoint(focusPoint);
    } catch (error) {
      Logger.error(TAG_LOG, `The setFocusPoint call failed. error code: ${error.code}`);
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
        Logger.error(TAG_LOG, `Failed to get the zoom ratio range. error: ${JSON.stringify(error)}`);
      }
    }
    try {
      photoSession.setZoomRatio(zoomRatio || photoZoomRatio);
    } catch (exception) {
      Logger.error(TAG_LOG, `setZoomRatio failed, code is ${exception.code}, message is ${exception.message}`);
    }
  }

  getSupportedColorSpaces(session: camera.PhotoSession): Array<colorSpaceManager.ColorSpace> {
    let colorSpaces: Array<colorSpaceManager.ColorSpace> = [];
    try {
      colorSpaces = session.getSupportedColorSpaces();
    } catch (error) {
      Logger.error(TAG_LOG, `The getSupportedColorSpaces call failed. error code: ${error.code}`);
    }
    return colorSpaces;
  }

  // [Start get_photo_rotation]
  // Get photo rotation
  getPhotoRotation(photoOutput: camera.PhotoOutput, deviceDegree: number): camera.ImageRotation {
    let photoRotation: camera.ImageRotation = camera.ImageRotation.ROTATION_0;
    try {
      photoRotation = photoOutput.getPhotoRotation(deviceDegree);
    } catch (error) {
      Logger.error(TAG_LOG, `The photoOutput.getPhotoRotation call failed. error code: ${error.code}`);
    }
    return photoRotation;
  }

  // [End get_photo_rotation]

  // [Start capture_photo]
  // Capture photo
  public async capture(isFront: boolean) {
    const degree = await this.getPhotoDegree();
    const rotation = this.getPhotoRotation(this.output!, degree);
    let settings: camera.PhotoCaptureSetting = {
      quality: camera.QualityLevel.QUALITY_LEVEL_HIGH,
      rotation,
      mirror: isFront
    };
    this.output?.capture(settings, (err: BusinessError) => {
      if (err) {
        Logger.error(TAG_LOG, `Failed to capture the photo. error: ${JSON.stringify(err)}`);
        return;
      }
      Logger.info(TAG_LOG, 'Callback invoked to indicate the photo capture request success.');
    });
  }

  // [End capture_photo]

  private calculateDeviceDegree(x: number, y: number, z: number): number {
    let deviceDegree: number = 0;
    // Determine if the device is approaching a vertical position (perpendicular to the ground)
    if ((x * x + y * y) * 3 < z * z) {
      return deviceDegree;
    } else {
      try {
        // Calculate the inverse tangent value
        let sd: Decimal = Decimal.atan2(y, -x)
        // Convert radian values to angle values;
        let sc: Decimal = Decimal.round(Number(sd) / Math.PI * 180);
        // Adjust angle to be relative to vertical orientation
        deviceDegree = 90 - Number(sc);
        // Normalize angle to 0-360 degrees range
        deviceDegree = deviceDegree >= 0 ? deviceDegree % 360 : deviceDegree % 360 + 360;
      } catch (exception) {
        Logger.error(TAG_LOG,
          `calculateDeviceDegree failed, code is ${exception.code}, message is ${exception.message}`);
      }
    }
    return deviceDegree;
  }

  private getPhotoDegree() {
    const promise: Promise<number> = new Promise(resolve => {
      try {
        sensor.once(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
          let degree = this.calculateDeviceDegree(data.x, data.y, data.z);
          resolve(degree);
        });
      } catch (exception) {
        Logger.error(TAG_LOG, `getPhotoDegree failed, code is ${exception.code}, message is ${exception.message}`);
      }
    })
    return promise;
  }

  // [Start is_moving_photo]
  // Check whether support moving photo or not
  public isMovingPhotoSupported(photoOutput: camera.PhotoOutput): boolean {
    let isSupported: boolean = false;
    try {
      isSupported = photoOutput.isMovingPhotoSupported();
    } catch (error) {
      Logger.error(TAG_LOG, `The isMovingPhotoSupported call failed. error code: ${error.code}`);
    }
    return isSupported;
  }

  // [End is_moving_photo]

  // [Start enable_moving_photo]
  // Enable moving photo
  public enableMovingPhoto(enabled: boolean): void {
    try {
      this.output?.enableMovingPhoto(enabled);
    } catch (error) {
      Logger.error(TAG_LOG, `The enableMovingPhoto call failed. error code: ${error.code}`);
    }
  }

  // [End enable_moving_photo]

  // [Start photo_release]
  // Release photo
  async release() {
    try {
      await this.output?.release();
    } catch (exception) {
      Logger.error(TAG_LOG, `release failed, code is ${exception.code}, message is ${exception.message}`);
    }
    if (this.isSingle) {
      this.output?.off('photoAvailable');
    } else {
      this.output?.off('photoAssetAvailable');
    }
    this.output = undefined;
  }

  // [End photo_release]
}