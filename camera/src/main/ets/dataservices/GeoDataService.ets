import sensor from '@ohos.sensor'
import { geoLocationManager } from '@kit.LocationKit'
import { common } from '@kit.AbilityKit'
import { Logger } from 'commons'

export enum DataStatus { Loading, Ready, Error }

export interface AltitudeData {
  status: DataStatus
  meters?: number
  display: string
}

export type Cardinal = '东'|'东北'|'北'|'西北'|'西'|'西南'|'南'|'东南'

export interface DirectionData {
  status: DataStatus
  degrees?: number
  cardinal?: Cardinal
  display: string
}

export interface LongitudeData {
  status: DataStatus
  degrees?: number
  hemisphere?: 'E'|'W'
  display: string
}

export interface LatitudeData {
  status: DataStatus
  degrees?: number
  hemisphere?: 'N'|'S'
  display: string
}

export interface GeoSnapshot {
  altitude: AltitudeData
  direction: DirectionData
  longitude: LongitudeData
  latitude: LatitudeData
  timestamp: number
  orientationBeta?: number
  orientationGamma?: number
}

class SnapshotListener {
  private fn: (s: GeoSnapshot) => void
  constructor(fn: (s: GeoSnapshot) => void) { this.fn = fn }
  call(s: GeoSnapshot): void { this.fn(s) }
}

export class GeoDataService {
  private static instance?: GeoDataService

  static getInstance(): GeoDataService {
    if (!GeoDataService.instance) GeoDataService.instance = new GeoDataService()
    return GeoDataService.instance as GeoDataService
  }

  private appContext?: Context
  private started = false
  private listeners = new Map<number, SnapshotListener>()
  private nextListenerId = 1

  private snapshot: GeoSnapshot = {
    altitude: { status: DataStatus.Loading, display: '获取中' },
    direction: { status: DataStatus.Loading, display: '获取中' },
    longitude: { status: DataStatus.Loading, display: '获取中' },
    latitude: { status: DataStatus.Loading, display: '获取中' },
    timestamp: Date.now()
  }

  private azimuthDeg: number = 0
  private barometerSubscribed = false
  private orientationSubscribed = false
  private barometerCb: (data: sensor.BarometerResponse) => void = () => {}
  private orientationCb: (data: sensor.OrientationResponse) => void = () => {}
  private directionThrottleTimer?: number

  async start(ctx?: common.UIAbilityContext | Context): Promise<void> {
    if (this.started) return
    if (ctx) {
      try {
        if (typeof (ctx as common.UIAbilityContext).getApplicationContext === 'function') {
          this.appContext = (ctx as common.UIAbilityContext).getApplicationContext()
        } else {
          this.appContext = ctx as Context
        }
      } catch (_) {
        this.appContext = ctx as Context
      }
    }
    this.started = true

    this.snapshot.altitude = { status: DataStatus.Loading, display: '获取中' }
    this.snapshot.direction = { status: DataStatus.Loading, display: '获取中' }
    this.snapshot.longitude = { status: DataStatus.Loading, display: '获取中' }
    this.snapshot.latitude = { status: DataStatus.Loading, display: '获取中' }
    this.snapshot.timestamp = Date.now()
    this.notify()

    try {
      sensor.once(sensor.SensorId.ORIENTATION, (resp: sensor.OrientationResponse) => {
        const raw = typeof resp.alpha === 'number' ? resp.alpha : 0
        const deg = ((raw + 90) % 360 + 360) % 360
        this.azimuthDeg = deg
        this.snapshot.orientationBeta = typeof resp.beta === 'number' ? resp.beta : this.snapshot.orientationBeta
        this.snapshot.orientationGamma = typeof resp.gamma === 'number' ? resp.gamma : this.snapshot.orientationGamma
        this.snapshot.direction = this.formatDirection(this.azimuthDeg)
        this.snapshot.timestamp = Date.now()
        this.notify()
      })
    } catch (_) {}

    try {
      sensor.once(sensor.SensorId.BAROMETER, (resp: sensor.BarometerResponse) => {
        const pressure = resp?.pressure
        if (typeof pressure === 'number' && !Number.isNaN(pressure)) {
          const altitude = this.calculateAltitudeFromPressure(pressure)
          if (altitude !== null) {
            this.snapshot.altitude = this.formatAltitude(altitude)
            this.snapshot.timestamp = Date.now()
            this.notify()
          }
        }
      })
    } catch (_) {}

    try {
      await this.acquireSingleLocation()
    } catch (e) {
      Logger.warn('GeoDataService', `单次定位失败: ${String(e)}`)
      this.snapshot.longitude = { status: DataStatus.Error, display: '获取失败' }
      this.snapshot.latitude = { status: DataStatus.Error, display: '获取失败' }
      this.notify()
    }

    try {
      this.subscribeOrientation()
    } catch (e) {
      Logger.warn('GeoDataService', `方向传感器订阅失败: ${String(e)}`)
      this.snapshot.direction = { status: DataStatus.Error, display: '获取失败' }
      this.notify()
    }

    try {
      this.subscribeBarometer()
    } catch (e) {
      Logger.warn('GeoDataService', `气压传感器订阅失败: ${String(e)}`)
      // 若后续有定位海拔则仍可填充，否则标为失败
      this.snapshot.altitude = { status: DataStatus.Error, display: '获取失败' }
      this.notify()
    }
  }

  stop(): void {
    if (!this.started) return
    this.started = false
    try { if (this.barometerSubscribed) sensor.off(sensor.SensorId.BAROMETER, this.barometerCb) } catch (_) {}
    try { if (this.orientationSubscribed) sensor.off(sensor.SensorId.ORIENTATION, this.orientationCb) } catch (_) {}
    this.barometerSubscribed = false
    this.orientationSubscribed = false
    this.directionThrottleTimer = undefined
  }

  getSnapshot(): GeoSnapshot {
    return {
      altitude: this.snapshot.altitude,
      direction: this.snapshot.direction,
      longitude: this.snapshot.longitude,
      latitude: this.snapshot.latitude,
      timestamp: this.snapshot.timestamp,
      orientationBeta: this.snapshot.orientationBeta,
      orientationGamma: this.snapshot.orientationGamma
    }
  }

  onUpdate(cb: (s: GeoSnapshot) => void): number {
    const id = this.nextListenerId++
    this.listeners.set(id, new SnapshotListener(cb))
    return id
  }

  removeListener(id: number): void {
    this.listeners.delete(id)
  }

  private notify(): void {
    const snap = this.getSnapshot()
    for (const listener of this.listeners.values()) {
      try { listener.call(snap) } catch (_) {}
    }
  }

  private async acquireSingleLocation(): Promise<void> {
    try {
      const fastReq: geoLocationManager.SingleLocationRequest = {
        locatingTimeoutMs: 4000,
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
      }
      const loc1: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(fastReq)
      const lon1 = loc1.longitude
      const lat1 = loc1.latitude
      const alt1 = loc1.altitude
      this.snapshot.longitude = this.formatLongitude(lon1)
      this.snapshot.latitude = this.formatLatitude(lat1)
      if (alt1 !== undefined && alt1 !== null) {
        this.snapshot.altitude = this.formatAltitude(alt1)
      }
      this.snapshot.timestamp = Date.now()
      this.notify()
    } catch (_) {
      try {
        const fallbackReq: geoLocationManager.SingleLocationRequest = {
          locatingTimeoutMs: 3000,
          locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY
        }
        const loc2: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(fallbackReq)
        const lon2 = loc2.longitude
        const lat2 = loc2.latitude
        const alt2 = loc2.altitude
        this.snapshot.longitude = this.formatLongitude(lon2)
        this.snapshot.latitude = this.formatLatitude(lat2)
        if (alt2 !== undefined && alt2 !== null) {
          this.snapshot.altitude = this.formatAltitude(alt2)
        }
        this.snapshot.timestamp = Date.now()
        this.notify()
      } catch (e2) {
        this.snapshot.longitude = { status: DataStatus.Error, display: '获取失败' }
        this.snapshot.latitude = { status: DataStatus.Error, display: '获取失败' }
        this.snapshot.timestamp = Date.now()
        throw new Error(String(e2))
      }
    }
  }

  private subscribeOrientation(): void {
    if (this.orientationSubscribed) return
    this.orientationCb = (resp: sensor.OrientationResponse) => {
      // azimuth 取值按磁北 0–360
      const raw = typeof resp.alpha === 'number' ? resp.alpha : 0
      // 横屏修正：默认左旋 90°
      const deg = ((raw + 90) % 360 + 360) % 360
      this.azimuthDeg = deg
      this.snapshot.orientationBeta = typeof resp.beta === 'number' ? resp.beta : this.snapshot.orientationBeta
      this.snapshot.orientationGamma = typeof resp.gamma === 'number' ? resp.gamma : this.snapshot.orientationGamma
      // 节流到 ~2Hz
      if (this.directionThrottleTimer) return
      this.directionThrottleTimer = setTimeout(() => {
        this.directionThrottleTimer = undefined
        this.snapshot.direction = this.formatDirection(this.azimuthDeg)
        this.snapshot.timestamp = Date.now()
        this.notify()
      }, 10) as number
    }
    sensor.on(sensor.SensorId.ORIENTATION, this.orientationCb, { interval: 100000000 })
    this.orientationSubscribed = true
  }

  private subscribeBarometer(): void {
    if (this.barometerSubscribed) return
    this.barometerCb = (resp: sensor.BarometerResponse) => {
      const pressure = resp?.pressure
      if (typeof pressure === 'number' && !Number.isNaN(pressure)) {
        const altitude = this.calculateAltitudeFromPressure(pressure)
        if (altitude !== null) {
          this.snapshot.altitude = this.formatAltitude(altitude)
          this.snapshot.timestamp = Date.now()
          this.notify()
        }
      }
    }
    sensor.on(sensor.SensorId.BAROMETER, this.barometerCb)
    this.barometerSubscribed = true
  }

  private calculateAltitudeFromPressure(pressure: number): number | null {
    if (!pressure || Number.isNaN(pressure)) return null
    if (pressure <= 300 || pressure >= 1100) return null
    const STANDARD_PRESSURE = 1013.25
    const ALTITUDE_CONSTANT = 44330
    const PRESSURE_EXPONENT = 0.1903
    const altitude = ALTITUDE_CONSTANT * (1 - Math.pow(pressure / STANDARD_PRESSURE, PRESSURE_EXPONENT))
    if (altitude < -500 || altitude > 20000) return null
    return altitude
  }

  private formatAltitude(m: number): AltitudeData {
    try {
      return { status: DataStatus.Ready, meters: m, display: `${Math.round(m)}m` }
    } catch (_) {
      return { status: DataStatus.Error, display: '获取失败' }
    }
  }

  private formatDirection(deg: number): DirectionData {
    try {
      const d = ((deg % 360) + 360) % 360
      const cardinal = this.mapToCardinal(d)
      return { status: DataStatus.Ready, degrees: d, cardinal, display: `${cardinal} ${Math.round(d)}°` }
    } catch (_) {
      return { status: DataStatus.Error, display: '获取失败' }
    }
  }

  private formatLongitude(deg: number): LongitudeData {
    try {
      const hemi: 'E'|'W' = deg >= 0 ? 'E' : 'W'
      const abs = Math.abs(deg)
      return { status: DataStatus.Ready, degrees: deg, hemisphere: hemi, display: `${abs.toFixed(6)}°${hemi}` }
    } catch (_) {
      return { status: DataStatus.Error, display: '获取失败' }
    }
  }

  private formatLatitude(deg: number): LatitudeData {
    try {
      const hemi: 'N'|'S' = deg >= 0 ? 'N' : 'S'
      const abs = Math.abs(deg)
      return { status: DataStatus.Ready, degrees: deg, hemisphere: hemi, display: `${abs.toFixed(6)}°${hemi}` }
    } catch (_) {
      return { status: DataStatus.Error, display: '获取失败' }
    }
  }

  private mapToCardinal(deg: number): Cardinal {
    interface DirectionSector { start: number; end: number; label: Cardinal }
    const sectors: Array<DirectionSector> = [
      { start: 337.5, end: 360, label: '北' },
      { start: 0, end: 22.5, label: '北' },
      { start: 22.5, end: 67.5, label: '东北' },
      { start: 67.5, end: 112.5, label: '东' },
      { start: 112.5, end: 157.5, label: '东南' },
      { start: 157.5, end: 202.5, label: '南' },
      { start: 202.5, end: 247.5, label: '西南' },
      { start: 247.5, end: 292.5, label: '西' },
      { start: 292.5, end: 337.5, label: '西北' }
    ]
    for (const s of sectors) {
      if (deg >= s.start && deg < s.end) return s.label
    }
    return '北'
  }
}

export default GeoDataService
