import CameraConstant from '../constants/Constants';
import { camera } from '@kit.CameraKit';
import WindowUtil from '../utils/WindowUtil';
import { curves, display } from '@kit.ArkUI';

export enum CameraMode {
  PHOTO,
  VIDEO
}

/**
 * States and methods related to preview.
 */
class PreviewViewModel {
  private uiContext: UIContext;
  isFront: boolean = false;
  cameraMode: CameraMode = CameraMode.PHOTO;
  xComponentController: XComponentController = new XComponentController();
  surfaceId: string = '';
  previewSize: Size = WindowUtil.getMaxDisplaySize(CameraConstant.RATIO_PHOTO);
  rates?: number[] = [];
  currentRate: number = 0;
  blurRadius: number = 0;
  blurRotation: RotateOptions = { y: 0.5, angle: 0};

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

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

  getCameraPosition() {
    return this.isFront
      ? camera.CameraPosition.CAMERA_POSITION_FRONT
      : camera.CameraPosition.CAMERA_POSITION_BACK;
  }

  getProfile: (cameraOrientation: number) => camera.Profile = cameraOrientation => {
    const displaySize: Size = WindowUtil.getMaxDisplaySize(this.getPreviewRatio());
    const displayRotation = display.getDefaultDisplaySync().rotation * 90;
    const isRevert = (cameraOrientation + displayRotation) % 180 !== 0;
    return {
      format: camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP,
      size: {
        height: isRevert ? displaySize.width : displaySize.height,
        width: isRevert ? displaySize.height : displaySize.width
      }
    };
  }

  setPreviewSize() {
    const displaySize: Size = WindowUtil.getMaxDisplaySize(this.getPreviewRatio())
    this.previewSize = displaySize;
    this.xComponentController.setXComponentSurfaceRect({
      surfaceWidth: displaySize.width,
      surfaceHeight: displaySize.height
    })
  }

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
}

export default PreviewViewModel;