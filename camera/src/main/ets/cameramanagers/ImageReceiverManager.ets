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

import { image } from '@kit.ImageKit';
import { camera } from '@kit.CameraKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'commons/src/main/ets/utils/Logger';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import { display } from '@kit.ArkUI';
import CameraConstant from '../constants/CameraConstants';

const TAG = 'ImageReceiverManager';

export class ImageReceiverManager implements OutputManager {
  output?: camera.PreviewOutput;
  isActive: boolean = true;
  callback: (px: PixelMap) => void;
  private position: camera.CameraPosition = camera.CameraPosition.CAMERA_POSITION_BACK;

  constructor(cb: (px: PixelMap) => void) {
    this.callback = cb;
  }

  async createOutput(config: CreateOutputConfig) {
    const cameraOutputCap = config.cameraManager.getSupportedOutputCapability(config.device, config.sceneMode);
    const displayRatio = config.profile.size.width / config.profile.size.height;
    const profileWidth = config.profile.size.width;
    const previewProfile = cameraOutputCap.previewProfiles
      .sort((a, b) => Math.abs(a.size.width - profileWidth) - Math.abs(b.size.width - profileWidth))
      .find(pf => {
        const pfDisplayRatio = pf.size.width / pf.size.height;
        return Math.abs(pfDisplayRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE;
      });
    if (!previewProfile) {
      Logger.error(TAG, 'Failed to get preview profile');
      return;
    }
    const surfaceId = await this.init(config.profile.size);
    this.output = config.cameraManager.createPreviewOutput(previewProfile, surfaceId);
    this.position = config.device.cameraPosition;
    return this.output;
  }

  async release() {
    await this.output?.release();
    this.output = undefined;
  }

  async init(size: Size, format = image.ImageFormat.JPEG, capacity = 8) {
    const receiver = image.createImageReceiver(size, format, capacity);
    const surfaceId = await receiver.getReceivingSurfaceId();
    this.onImageArrival(receiver);
    return surfaceId;
  }

  getRotate(): number {
    const displayRotation = display.getDefaultDisplaySync().rotation;
    if (this.position === camera.CameraPosition.CAMERA_POSITION_BACK) {
      return (displayRotation * camera.ImageRotation.ROTATION_90 + 90) % 360;
    }
    const rotation = displayRotation * camera.ImageRotation.ROTATION_90;
    const angle = (displayRotation * camera.ImageRotation.ROTATION_90 + 270) % 360;
    if (rotation === 90 || rotation === 270) {
      return (angle + 180) % 360;
    }
    return angle;
  }

  async getPixelMap(imgComponent: image.Component, width: number, height: number, stride: number) {
    if (stride === width) {
      return await image.createPixelMap(imgComponent.byteBuffer, {
        size: { height: height, width: width },
        srcPixelFormat: image.PixelMapFormat.NV21,
      });
    }
    const dstBufferSize = width * height * 1.5
    const dstArr = new Uint8Array(dstBufferSize);
    for (let j = 0; j < height * 1.5; j++) {
      const srcBuf = new Uint8Array(imgComponent.byteBuffer, j * stride, width);
      dstArr.set(srcBuf, j * width);
    }
    return await image.createPixelMap(dstArr.buffer, {
      size: { height: height, width: width },
      srcPixelFormat: image.PixelMapFormat.NV21,
    });
  }

  onImageArrival(receiver: image.ImageReceiver): void {
    receiver.on('imageArrival', () => {
      Logger.info(TAG, 'image arrival');
      receiver.readNextImage((err: BusinessError, nextImage: image.Image) => {
        if (err || nextImage === undefined) {
          Logger.error(TAG, 'readNextImage failed');
          return;
        }
        nextImage.getComponent(image.ComponentType.JPEG, async (err: BusinessError, imgComponent: image.Component) => {
          if (err || imgComponent === undefined) {
            Logger.error(TAG, 'getComponent failed');
          }
          if (imgComponent.byteBuffer) {
            const width = nextImage.size.width;
            const height = nextImage.size.height;
            const stride = imgComponent.rowStride;
            Logger.info(TAG, `getComponent with width:${width} height:${height} stride:${stride}`);
            const pixelMap = await this.getPixelMap(imgComponent, width, height, stride);
            const displayRotation = display.getDefaultDisplaySync().rotation;
            const rotation = this.output!.getPreviewRotation(displayRotation * camera.ImageRotation.ROTATION_90);
            await pixelMap.rotate(rotation);
            if (this.position === camera.CameraPosition.CAMERA_POSITION_FRONT) {
              await pixelMap.flip(true, false);
            }
            this.callback(pixelMap);
          } else {
            Logger.error(TAG, 'byteBuffer is null');
          }
          nextImage.release();
          Logger.info(TAG, 'image process done');
        })
      })
    })
  }
}
