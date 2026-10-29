"""OpenWeather adapter and deterministic offline weather (standard library only)."""
import json
import math
import os
import socket
import time
from pathlib import Path
from dataclasses import asdict, dataclass
from datetime import date, datetime, timedelta, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen


class WeatherError(RuntimeError):
    """Public errors deliberately exclude request URLs and API credentials."""


class WeatherHorizonError(WeatherError):
    """Valid API response with no slots on the requested local date."""


def load_openweather_key(config_path=None):
    """Prefer the process environment, then a local ignored .env file.

    Read only this key; never execute or interpolate configuration content.
    """
    configured = os.environ.get('OPENWEATHER_API_KEY', '').strip()
    if configured:
        return configured
    path = Path(config_path) if config_path else Path(__file__).resolve().parents[1] / '.env'
    if not path.exists():
        return None
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        name, separator, value = line.strip().partition('=')
        if separator and name.strip() == 'OPENWEATHER_API_KEY':
            return value.strip().strip('"\'').strip() or None
    return None


@dataclass(frozen=True)
class WeatherData:
    target_date: str
    temperature_c: float
    rain_probability: float
    condition: str
    source: str
    fetched_at: str
    sample_count: int = 1

    def __post_init__(self):
        date.fromisoformat(self.target_date)
        if not math.isfinite(self.temperature_c) or not -90 <= self.temperature_c <= 65:
            raise ValueError("Invalid weather temperature")
        if not math.isfinite(self.rain_probability) or not 0 <= self.rain_probability <= 1:
            raise ValueError("Invalid rain probability")
        if self.source not in {"mock", "openweather_current", "openweather_forecast"}:
            raise ValueError("Invalid weather source")
        if self.condition not in {"CLEAR", "CLOUDS", "RAIN", "SNOW", "OTHER"}:
            raise ValueError("Invalid weather condition")
        timestamp = datetime.fromisoformat(self.fetched_at)
        if timestamp.tzinfo is None:
            raise ValueError("Weather fetched_at must include timezone")
        if not isinstance(self.sample_count, int) or self.sample_count < 1:
            raise ValueError("Invalid weather sample count")

    def to_dict(self):
        return asdict(self)


def mock_weather(target_date: str, scenario: str = "normal") -> WeatherData:
    scenarios = {"normal": (28.0, .1, "CLEAR"), "hot": (36.0, .1, "CLEAR"),
                 "rainy": (27.0, .9, "RAIN"), "hot_rainy": (35.0, .9, "RAIN")}
    if scenario not in scenarios:
        raise ValueError(f"Unknown mock scenario: {scenario}")
    return WeatherData(target_date, *scenarios[scenario], "mock",
                       datetime.now(timezone.utc).isoformat(), 8)


def _condition(code: int) -> str:
    if 200 <= code < 600:
        return "RAIN"
    if 600 <= code < 700:
        return "SNOW"
    if code == 800:
        return "CLEAR"
    if 801 <= code <= 804:
        return "CLOUDS"
    return "OTHER"


class OpenWeatherClient:
    def __init__(self, api_key=None, timeout=10.0, retries=2):
        self._key = api_key or load_openweather_key()
        if not self._key:
            raise WeatherError("Configure OPENWEATHER_API_KEY in the server environment or project .env; run SET_WEATHER_KEY.ps1 once.")
        if not math.isfinite(timeout) or timeout <= 0 or retries not in range(4):
            raise ValueError("Invalid timeout/retry configuration")
        self.timeout, self.retries = timeout, retries

    def _request(self, endpoint, latitude, longitude):
        if not math.isfinite(latitude) or not -90 <= latitude <= 90:
            raise ValueError("Invalid latitude")
        if not math.isfinite(longitude) or not -180 <= longitude <= 180:
            raise ValueError("Invalid longitude")
        query = urlencode({"lat": latitude, "lon": longitude, "appid": self._key,
                           "units": "metric"})
        url = f"https://api.openweathermap.org/data/2.5/{endpoint}?{query}"
        for attempt in range(self.retries + 1):
            try:
                with urlopen(url, timeout=self.timeout) as response:
                    payload = json.load(response)
                if str(payload.get("cod", 200)) != "200":
                    raise WeatherError("OpenWeather returned an unsuccessful response")
                return payload
            except HTTPError as error:
                code = error.code
                if code not in {429, 500, 502, 503, 504} or attempt == self.retries:
                    raise WeatherError(f"OpenWeather HTTP {code}") from None
            except (URLError, TimeoutError, socket.timeout):
                if attempt == self.retries:
                    raise WeatherError("OpenWeather network request failed") from None
            except (ValueError, TypeError):
                raise WeatherError("OpenWeather returned invalid JSON") from None
            time.sleep(.5 * (2 ** attempt))

    def current(self, latitude: float, longitude: float) -> WeatherData:
        payload = self._request("weather", latitude, longitude)
        try:
            local = timezone(timedelta(seconds=int(payload["timezone"])))
            day = datetime.fromtimestamp(payload["dt"], local).date().isoformat()
            condition = _condition(int(payload["weather"][0]["id"]))
            # Current endpoint has no forecast pop: this is an occurrence indicator.
            return WeatherData(day, float(payload["main"]["temp"]),
                               float(condition == "RAIN"), condition, "openweather_current",
                               datetime.now(timezone.utc).isoformat())
        except (KeyError, IndexError, ValueError, TypeError, OverflowError):
            raise WeatherError("Invalid current weather response") from None

    def forecast(self, latitude: float, longitude: float, target_date: str) -> WeatherData:
        date.fromisoformat(target_date)
        try:
            return self.parse_forecast(self._request("forecast", latitude, longitude), target_date)
        except WeatherHorizonError:
            # Late in the day the first 3-hour forecast may be tomorrow.
            # Current conditions are valid only for the same local date.
            current = self.current(latitude, longitude)
            if current.target_date == target_date:
                return current
            raise

    @staticmethod
    def parse_forecast(payload: dict, target_date: str) -> WeatherData:
        """Aggregate only slots on the requested location-local date."""
        try:
            day = date.fromisoformat(target_date)
            local = timezone(timedelta(seconds=int(payload["city"]["timezone"])))
            slots = [slot for slot in payload["list"]
                     if datetime.fromtimestamp(slot["dt"], local).date() == day]
            if not slots:
                dates = sorted({datetime.fromtimestamp(slot['dt'], local).date().isoformat() for slot in payload['list']})
                window = f'{dates[0]} through {dates[-1]}' if dates else 'no dates'
                raise WeatherHorizonError(f'Weather date {target_date} is unavailable. OpenWeather returned {window}. '
                                          'Use a supported date or mock weather; live current weather can be checked separately.')
            codes = [_condition(int(slot["weather"][0]["id"])) for slot in slots]
            condition = "RAIN" if "RAIN" in codes else codes[0]
            return WeatherData(target_date, max(float(slot["main"]["temp"]) for slot in slots),
                               max(float(slot["pop"]) for slot in slots), condition,
                               "openweather_forecast", datetime.now(timezone.utc).isoformat(), len(slots))
        except (KeyError, IndexError, ValueError, TypeError, OverflowError):
            raise WeatherError("Invalid forecast response") from None
