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
import { Logger } from 'commons/src/main/ets/utils/Logger';
import { BusinessError } from '@kit.BasicServicesKit';
import OutputManager, { CreateOutputConfig } from './OutputManager';
import CameraConstant from '../constants/CameraConstants';

const TAG_LOG = 'PreviewManager'

export class PreviewManager implements OutputManager {
  output?: camera.PreviewOutput;
  isActive: boolean = true;

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
      Logger.error(TAG_LOG, 'Failed to get preview profile');
      return;
    }
    this.output = config.cameraManager.createPreviewOutput(previewProfile, config.surfaceId);
    this.addOutputListener(this.output);
    return this.output;
  }

  addOutputListener(output: camera.PreviewOutput) {
    this.addFrameStartEventListener(output);
    this.addFrameEndEventListener(output);
  }

  addFrameStartEventListener(output: camera.PreviewOutput) {
    output.on('frameStart', (err: BusinessError) => {
      if (err !== undefined && err.code !== 0) {
        Logger.error(TAG_LOG, `FrameStart callback Error, errorCode: ${err.code}`);
        return;
      }
      Logger.info(TAG_LOG, 'Preview frame started');
    });
  }

  addFrameEndEventListener(output: camera.PreviewOutput) {
    output.on('frameEnd', (err: BusinessError) => {
      if (err !== undefined && err.code !== 0) {
        Logger.error(TAG_LOG, `FrameStart callback Error, errorCode: ${err.code}`);
        return;
      }
      Logger.info(TAG_LOG, 'Preview frame end');
    });
  }

  async release() {
    await this.output?.release();
    this.output = undefined;
  }

  getSupportedFrameRates() {
    return this.output?.getSupportedFrameRates();
  }

  setFrameRate(minFps: number, maxFps: number) {
    try {
      this.output?.setFrameRate(minFps, maxFps);
    } catch(e) {
      Logger.error(TAG_LOG, 'setActiveFrameRate error ' + JSON.stringify(e));
    }
  }
}
