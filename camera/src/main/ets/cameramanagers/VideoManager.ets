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

import { media } from '@kit.MediaKit';
import { camera } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { sensor } from '@kit.SensorServiceKit';
import { Decimal } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from 'commons/src/main/ets/utils/Logger';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';

const LOG_TAG = 'video';

enum QualityLevel {
  NORMAL,
  HIGHER
}

export enum AVRecorderState {
  IDLE = "idle",
  PREPARED = "prepared",
  STARTED = "started",
  PAUSED = "paused",
  STOPPED = "stopped",
  RELEASED = "released",
  ERROR = "error"
}

export class VideoManager implements OutputManager {
  private avRecorder: media.AVRecorder | undefined = undefined;
  private avConfig: media.AVRecorderConfig | undefined = undefined;
  private avProfile: media.AVRecorderProfile | undefined = undefined;
  private videoProfile: camera.VideoProfile | undefined = undefined;
  private context: Context | undefined = undefined;
  private cameraPosition: number = 0;
  private qualityLevel: QualityLevel = QualityLevel.NORMAL;
  output: camera.VideoOutput | undefined = undefined;
  private videoUri: string = '';
  private file: fileIo.File | undefined = undefined;
  state: media.AVRecorderState = AVRecorderState.IDLE;
  isActive: boolean = false;
  private callback: (pixelMap: image.PixelMap, url: string) => void = () => {
  };

  constructor(context: Context) {
    this.context = context;
  }

  setIsActive(isActive: boolean) {
    this.isActive = isActive;
  }

  async createOutput(config: CreateOutputConfig) {
    try {
      this.avRecorder = await media.createAVRecorder();
      this.avRecorder.on('stateChange', state => {
        this.state = state;
        Logger.info(LOG_TAG, 'on avRecorder state change: ', state)
      });
    } catch (error) {
      Logger.error(LOG_TAG, 'createAVRecorder call failed. error code: %{public}s', (error as BusinessError).code);
    }
    if (this.avRecorder === undefined || this.avRecorder === null) {
      return;
    }

    this.setVideoProfile(config.cameraManager, config.profile, config.device);
    await this.setAVConfig();
    await this.prepare();
    await this.createVideoOutput(config.cameraManager);
    return this.output;
  }

  // 配置录制参数。
  async prepare() {
    try {
      if (this.avRecorder?.state === AVRecorderState.IDLE && this.avConfig) {
        await this.avRecorder.prepare(this.avConfig);
        Logger.info(LOG_TAG, 'Succeeded in preparing');
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to prepare and catch error is  ${error.message}`);
    }
  }

  async start() {
    try {
      if (this.avRecorder?.state === AVRecorderState.PREPARED) {
        await this.avRecorder.updateRotation(this.getVideoRotation(await this.getGravity())); // 配置录像旋转角度。
        await this.output?.start();
        await this.avRecorder?.start();
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to start and catch error is  ${error.message}`);
    }
  }

  async stop() {
    try {
      if (this.avRecorder?.state === AVRecorderState.STARTED
        || this.avRecorder?.state === AVRecorderState.PAUSED) {
        await this.avRecorder.stop();
        await this.output?.stop();
        const thumbnail = await this.getVideoThumbnail();
        if (thumbnail) {
          this.callback(thumbnail, this.videoUri);
        }
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to stop and catch error is  ${error.message}`);
    }
  }

  // 暂停录制。
  async pause() {
    try {
      if (this.avRecorder?.state === AVRecorderState.STARTED) {
        await this.avRecorder.pause();
        await this.output?.stop();
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to pause and catch error is  ${error.message}`);
    }
  }

  async resume() {
    try {
      if (this.avRecorder?.state === AVRecorderState.PAUSED) {
        await this.output?.start();
        await this.avRecorder.resume();
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to resume and catch error is  ${error.message}`);
    }
  }

  async release() {
    await this.avRecorder?.release();
    await this.output?.release();
    this.file && await fileIo.close(this.file.fd);
    this.avRecorder?.off('stateChange');
    this.avRecorder = undefined;
    this.output = undefined;
    this.file = undefined;
  }

  async createVideoOutput(cameraManager: camera.CameraManager) {
    if (!this.avRecorder || this.avRecorder.state !== AVRecorderState.PREPARED) {
      return;
    }
    try {
      let videoSurfaceId = await this.avRecorder.getInputSurface();
      this.output = cameraManager.createVideoOutput(this.videoProfile, videoSurfaceId);
    } catch (error) {
      Logger.error(LOG_TAG,
        `Failed to create the output instance. error code: ${(error as BusinessError).code}`);
    }
  }

  getCurrentOutput() {
    return this.output;
  }

  setVideoCallback(callback: (pixelMap: image.PixelMap, url: string) => void) {
    this.callback = callback;
  }

  setVideoProfile(cameraManager: camera.CameraManager, targetProfile: camera.Profile,
    device: camera.CameraDevice) {
    this.cameraPosition = device.cameraPosition;
    let cameraOutputCap: camera.CameraOutputCapability | undefined =
      cameraManager.getSupportedOutputCapability(device,
        camera.SceneMode.NORMAL_VIDEO);
    let videoProfilesArray: camera.VideoProfile[] | undefined = cameraOutputCap?.videoProfiles;
    const displayRatio = targetProfile.size.height / targetProfile.size.width;
    const videoProfile = videoProfilesArray?.find((profile: camera.VideoProfile) => {
      const profileRatio = profile.size.height / profile.size.width
      if (this.cameraPosition === 1) {
        return profile.size.width >= 1080 && profile.size.height >= 1080 &&
          Math.abs(profileRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE &&
          profile.frameRateRange.max === 30;
      }
      if (this.qualityLevel === QualityLevel.NORMAL) {
        return profile.size.width <= 1920 && profile.size.width >= 1080 && profile.size.height >= 1080 &&
          Math.abs(profileRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE * profile.size.width &&
          profile.frameRateRange.max === 60;
      }
      if (this.qualityLevel === QualityLevel.HIGHER && this.cameraPosition === 0) {
        return profile.size.width <= 4096 && profile.size.width >= 3000 &&
          Math.abs(profileRatio - displayRatio) <= CameraConstant.PROFILE_DIFFERENCE * profile.size.width &&
          profile.frameRateRange.max === 60;
      }
      return false;
    })
    if (!videoProfile) {
      Logger.error(LOG_TAG, 'Failed to get videoProfile')
    }
    this.videoProfile = videoProfile;
  }

  async setAVConfig() {
    let options: photoAccessHelper.CreateOptions = {
      title: Date.now().toString()
    };
    let accessHelper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
    this.videoUri = await accessHelper.createAsset(photoAccessHelper.PhotoType.VIDEO, 'mp4', options);
    this.file = fileIo.openSync(this.videoUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    this.avProfile = {
      audioBitrate: 48000,
      audioChannels: 2,
      audioCodec: media.CodecMimeType.AUDIO_AAC,
      audioSampleRate: 48000,
      fileFormat: media.ContainerFormatType.CFT_MPEG_4,
      videoBitrate: 32000000,
      videoCodec: (this.qualityLevel === QualityLevel.HIGHER && this.cameraPosition === 0) ?
      media.CodecMimeType.VIDEO_HEVC : media.CodecMimeType.VIDEO_AVC,
      videoFrameWidth: this.videoProfile?.size.width,
      videoFrameHeight: this.videoProfile?.size.height,
      videoFrameRate: this.cameraPosition === 0 ? 60 : 30,
    }

    this.avConfig = {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_CAMCORDER,
      videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,
      profile: this.avProfile,
      url: `fd://${this.file.fd}`,
      metadata: {
        videoOrientation: this.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT ?
        camera.ImageRotation.ROTATION_270.toString() : camera.ImageRotation.ROTATION_90.toString(),
      }
    }
  }

  getRealData(data: sensor.GravityResponse): number {
    let getDeviceDegree: number = 0;
    let x = data.x;
    let y = data.y;
    let z = data.z;
    if ((x * x + y * y) * 3 < z * z) {
      return getDeviceDegree;
    } else {
      let sd: Decimal = Decimal.atan2(y, -x);
      let sc: Decimal = Decimal.round(Number(sd) / 3.141592653589 * 180)
      getDeviceDegree = 90 - Number(sc);
      getDeviceDegree = getDeviceDegree >= 0 ? getDeviceDegree % 360 : getDeviceDegree % 360 + 360;
    }
    return getDeviceDegree;
  }

  async getGravity(): Promise<number> {
    try {
      let isSupportedGravity: boolean = false;
      let data = await sensor.getSensorList();
      for (let i = 0; i < data.length; i++) {
        if (data[i].sensorId === sensor.SensorId.GRAVITY) {
          isSupportedGravity = true;
          break;
        }
      }
      if (isSupportedGravity === true) {
        const promise: Promise<number> = new Promise((resolve) => {
          sensor.once(sensor.SensorId.GRAVITY, (data: sensor.GravityResponse) => {
            resolve(this.getRealData(data));
          });
        })
        return promise;
      } else {
        const promise: Promise<number> = new Promise((resolve) => {
          sensor.once(sensor.SensorId.ACCELEROMETER, (data: sensor.AccelerometerResponse) => {
            resolve(this.getRealData(data as sensor.GravityResponse));
          });
        })
        return promise;
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to getGravity and catch error is  ${error.message}`);
      return 0
    }
  }

  getVideoRotation(deviceDegree: number): camera.ImageRotation {
    let videoRotation: camera.ImageRotation =
      this.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT ? camera.ImageRotation.ROTATION_270 :
      camera.ImageRotation.ROTATION_90;
    try {
      if (this.output) {
        videoRotation = this.output.getVideoRotation(deviceDegree);
        Logger.info(LOG_TAG, `Video rotation is: ${videoRotation}`);
      }
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to getVideoRotation and catch error is: ${error.message}`);
    }
    return videoRotation;
  }

  async getVideoThumbnail() {
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      let avImageGenerator: media.AVImageGenerator = await media.createAVImageGenerator();
      let dataSrc: media.AVFileDescriptor = {
        fd: this.file!.fd,
      };
      avImageGenerator.fdSrc = dataSrc;
      let timeUs = 0;
      let queryOption = media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC;
      let param: media.PixelMapParams = {
        width: 300,
        height: 300
      };
      pixelMap = await avImageGenerator.fetchFrameByTime(timeUs, queryOption, param);
      avImageGenerator.release();
    } catch (error) {
      Logger.error(LOG_TAG, `Failed to getVideoThumbnail and catch error is  ${error.message}`);
    }
    return pixelMap;
  }

  isRecording() {
    return this.state === AVRecorderState.STARTED || this.state === AVRecorderState.PAUSED;
  }
}