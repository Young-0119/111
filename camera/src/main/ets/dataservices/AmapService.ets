import http from '@ohos.net.http';
import geoLocationManager from '@ohos.geoLocationManager';
import { Logger } from 'commons';

export interface LocationResult {
  text: string;
  adcode: string;
}

export interface WeatherResult {
  text: string;
}

interface RegeoResponseAddressComponent {
  province?: string;
  city?: string | string[];
  district?: string;
  streetNumber?: StreetNumber;
  adcode?: string;
}

interface StreetNumber {
  street?: string;
  number?: string;
}

interface RegeoResponse {
  status?: string;
  info?: string;
  infocode?: string;
  regeocode?: RegeoRegeocode;
}

interface RegeoRegeocode {
  addressComponent?: RegeoResponseAddressComponent;
}

interface WeatherItem {
  weather?: string;
  temperature?: string;
  winddirection?: string;
  windpower?: string;
  humidity?: string;
}

interface WeatherInfoResponse {
  status?: string;
  info?: string;
  infocode?: string;
  lives?: WeatherItem[];
}

export class AmapService {
  private static key: string = '';
  private static locationCache?: Cache<LocationResult>;
  private static weatherCache?: Cache<WeatherResult>;
  private static debug: boolean = false;

  static setKey(k: string): void {
    AmapService.key = (k || '').trim();
  }

  static setDebug(enabled: boolean): void {
    AmapService.debug = !!enabled;
  }


  static async reverseGeocode(lat: number, lon: number): Promise<LocationResult> {
    if (!AmapService.key) {
      return { text: '获取失败', adcode: '' };
    }
    const maskedKey = AmapService.key.length > 6 ? `${AmapService.key.slice(0, 4)}***${AmapService.key.slice(-2)}` : '***';
    const url = `https://restapi.amap.com/v3/geocode/regeo?key=${AmapService.key}&location=${lon},${lat}&extensions=all&output=json`;
    const client = http.createHttp();
    try {
      const reqOpt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 5000,
        connectTimeout: 5000
      };
      if (AmapService.debug) {
        Logger.info('AmapService', `regeo request url=${url.replace(AmapService.key, maskedKey)} opt=${JSON.stringify({ expectDataType: reqOpt.expectDataType, readTimeout: reqOpt.readTimeout, connectTimeout: reqOpt.connectTimeout })}`);
      }
      const res: http.HttpResponse = await client.request(url, reqOpt);
      const body: string = String(res.result ?? '');
      if (AmapService.debug) {
        const code: number = res.responseCode;
        Logger.info('AmapService', `regeo response code=${code} bodyLen=${body.length} bodyHead=${body.slice(0, 200)}`);
      }
      const code: number = res.responseCode;
      if (code !== 200) {
        throw new Error(`HTTP ${code}`);
      }
      const json: RegeoResponse = JSON.parse(body);
      if (json && json.status !== '1') {
        const info: string = json.info ?? '';
        const infocode: string = json.infocode ?? '';
        if (AmapService.debug) {
          Logger.warn('AmapService', `regeo error info=${info} infocode=${infocode}`);
        }
        throw new Error(`Amap regeo error ${infocode} ${info}`);
      }
      const comp: RegeoResponseAddressComponent | undefined = json.regeocode?.addressComponent;
      const cityField: string | string[] | undefined = comp?.city;
      const city: string = Array.isArray(cityField) ? (cityField[0] ?? '') : String(cityField ?? '');
      const district: string = String(comp?.district ?? '');
      const street: string = String(comp?.streetNumber?.street ?? '');
      const number: string = String(comp?.streetNumber?.number ?? '');
      const adcode: string = String(comp?.adcode ?? '');
      const streetPart: string = street ? `${street}${number ? number + '' : ''}` : '';
      const parts: string[] = [city, district, streetPart].filter(p => !!p);
      const text: string = parts.length > 0 ? parts.join('·') : '获取失败';
      const value: LocationResult = { text, adcode };
      const cache: Cache<LocationResult> = { value, expireAt: Date.now() + 24 * 60 * 60 * 1000 };
      AmapService.locationCache = cache;
      if (AmapService.debug) {
        Logger.info('AmapService', `regeo parse adcode=${adcode}  city=${city} district=${district} streetPart=${streetPart}`);
      }
      return value;
    } catch (err) {
      Logger.warn('AmapService', `reverseGeocode failed: ${String(err)}`);
      return { text: '获取失败', adcode: '' };
    } finally {
      client.destroy();
    }
  }

  static async getWeatherByAdcode(adcode: string): Promise<WeatherResult> {
    if (!AmapService.key) {
      return { text: '获取失败' };
    }
    const maskedKey = AmapService.key.length > 6 ? `${AmapService.key.slice(0, 4)}***${AmapService.key.slice(-2)}` : '***';
    const url = `https://restapi.amap.com/v3/weather/weatherInfo?key=${AmapService.key}&city=${adcode}&extensions=base`;
    const client = http.createHttp();
    try {
      const reqOpt: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        readTimeout: 5000,
        connectTimeout: 5000
      };
      if (AmapService.debug) {
        Logger.info('AmapService', `weather request url=${url.replace(AmapService.key, maskedKey)} opt=${JSON.stringify({ expectDataType: reqOpt.expectDataType, readTimeout: reqOpt.readTimeout, connectTimeout: reqOpt.connectTimeout })}`);
      }
      const res: http.HttpResponse = await client.request(url, reqOpt);
      const body: string = String(res.result ?? '');
      if (AmapService.debug) {
        const code: number = res.responseCode;
        Logger.info('AmapService', `weather response code=${code} bodyLen=${body.length} bodyHead=${body.slice(0, 200)}`);
      }
      const code: number = res.responseCode;
      if (code !== 200) {
        throw new Error(`HTTP ${code}`);
      }
      const json: WeatherInfoResponse = JSON.parse(body);
      if (json && json.status !== '1') {
        const info: string = json.info ?? '';
        const infocode: string = json.infocode ?? '';
        if (AmapService.debug) {
          Logger.warn('AmapService', `weather error info=${info} infocode=${infocode}`);
        }
        throw new Error(`Amap weather error ${infocode} ${info}`);
      }
      const w: WeatherItem | undefined = (json.lives && json.lives.length > 0) ? json.lives[0] : undefined;
      const weather: string = String(w?.weather ?? '');
      const temp: string = String(w?.temperature ?? '');
      const windDir: string = String(w?.winddirection ?? '');
      const windPower: string = String(w?.windpower ?? '');
      const humidity: string = String(w?.humidity ?? '');
      const windPart: string = windDir ? `${windDir}${windPower ? windPower + '级' : ''}` : '';
      const textParts: string[] = [weather, temp ? `${temp}℃` : '', windPart, humidity ? `湿度${humidity}%` : ''].filter(p => !!p);
      const text: string = textParts.length > 0 ? textParts.join(' ') : '获取失败';
      const value: WeatherResult = { text };
      const cache: Cache<WeatherResult> = { value, expireAt: Date.now() + 5 * 60 * 1000 };
      AmapService.weatherCache = cache;
      if (AmapService.debug) {
        Logger.info('AmapService', `weather parse weather=${weather} temp=${temp} windDir=${windDir} windPower=${windPower} humidity=${humidity}`);
      }
      return value;
    } catch (err) {
      Logger.warn('AmapService', `getWeatherByAdcode failed: ${String(err)}`);
      return { text: '获取失败' };
    } finally {
      client.destroy();
    }
  }

  static async fetchLocationAndWeatherAuto(): Promise<LocationWeatherPair> {
    const now: number = Date.now();
    const locCached = AmapService.locationCache;
    const weaCached = AmapService.weatherCache;
    if (locCached && locCached.expireAt > now && weaCached && weaCached.expireAt > now) {
      const pair: LocationWeatherPair = { location: locCached.value.text, weather: weaCached.value.text };
      return pair;
    }
    try {
      const loc: geoLocationManager.Location = await geoLocationManager.getCurrentLocation();
      const regeo = await AmapService.reverseGeocode(loc.latitude, loc.longitude);
      const fallbackWeather: WeatherResult = { text: '获取失败' };
      const weather: WeatherResult = regeo.adcode ? await AmapService.getWeatherByAdcode(regeo.adcode) : fallbackWeather;
      const pair: LocationWeatherPair = { location: regeo.text, weather: weather.text };
      return pair;
    } catch (err) {
      Logger.warn('AmapService', `fetchLocationAndWeatherAuto failed: ${String(err)}`);
      const pair: LocationWeatherPair = { location: '获取失败', weather: '获取失败' };
      return pair;
    }
  }
}

interface Cache<T> {
  value: T;
  expireAt: number;
}

interface LocationWeatherPair {
  location: string;
  weather: string;
}

export default AmapService;
