import Foundation

actor RealtimeContextProvider {
    private struct CachedWeather {
        let summary: String
        let timestamp: Date
    }

    private struct GeocodingResponse: Decodable {
        let results: [GeocodingResult]?
    }

    private struct GeocodingResult: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
    }

    private struct ForecastResponse: Decodable {
        let current: CurrentWeather?
    }

    private struct CurrentWeather: Decodable {
        let time: String?
        let temperature2m: Double?
        let apparentTemperature: Double?
        let weatherCode: Int?
        let windSpeed10m: Double?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case apparentTemperature = "apparent_temperature"
            case weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m"
        }
    }

    private enum ProviderError: Error {
        case invalidURL
        case badResponse
        case noData
    }

    private let session: URLSession
    private var weatherCache: [String: CachedWeather] = [:]
    private let weatherTTL: TimeInterval = 15 * 60

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func buildSystemContext(config: ChatConfig, now: Date = Date()) async -> String? {
        guard config.realtimeContextEnabled else { return nil }

        var lines: [String] = []
        lines.append("以下是系统实时信息（仅供当前回答参考）：")
        lines.append(buildDateTimeLine(now: now))

        if config.weatherContextEnabled {
            let location = config.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !location.isEmpty {
                if let weather = try? await fetchWeatherSummary(location: location, now: now) {
                    lines.append(weather)
                } else {
                    lines.append("天气：\(location) 暂时获取失败。")
                }
            }
        }

        lines.append("当用户询问今天日期、当前时间或天气时，请优先依据以上实时信息回答。")
        return lines.joined(separator: "\n")
    }

    private func fetchWeatherSummary(location: String, now: Date) async throws -> String {
        let cacheKey = location.lowercased()
        if let cached = weatherCache[cacheKey], now.timeIntervalSince(cached.timestamp) < weatherTTL {
            return cached.summary
        }

        let place = try await geocode(location: location)
        let current = try await fetchCurrentWeather(latitude: place.latitude, longitude: place.longitude)

        guard let temperature = current.temperature2m,
              let apparent = current.apparentTemperature,
              let weatherCode = current.weatherCode else {
            throw ProviderError.noData
        }

        let city = [place.name, place.country].compactMap { $0 }.joined(separator: " ")
        let updateTime = normalizedAPITime(current.time) ?? formatTime(now, timeZone: .current)
        let summary = String(
            format: "天气（%@）：%@，%.1f°C，体感 %.1f°C，风速 %.1f km/h（更新 %@）",
            city,
            weatherDescription(for: weatherCode),
            temperature,
            apparent,
            current.windSpeed10m ?? 0,
            updateTime
        )

        weatherCache[cacheKey] = CachedWeather(summary: summary, timestamp: now)
        return summary
    }

    private func geocode(location: String) async throws -> GeocodingResult {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: location),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json")
        ]

        guard let url = components?.url else { throw ProviderError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.badResponse
        }

        let decoded = try JSONDecoder().decode(GeocodingResponse.self, from: data)
        guard let first = decoded.results?.first else {
            throw ProviderError.noData
        }
        return first
    }

    private func fetchCurrentWeather(latitude: Double, longitude: Double) async throws -> CurrentWeather {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]

        guard let url = components?.url else { throw ProviderError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.badResponse
        }

        let decoded = try JSONDecoder().decode(ForecastResponse.self, from: data)
        guard let current = decoded.current else {
            throw ProviderError.noData
        }
        return current
    }

    private func buildDateTimeLine(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss EEEE"
        let dateTime = formatter.string(from: now)
        return "当前日期时间：\(dateTime)（时区：\(TimeZone.current.identifier)）"
    }

    private func formatTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func normalizedAPITime(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "T", with: " ")
    }

    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0:
            return "晴"
        case 1, 2, 3:
            return "多云"
        case 45, 48:
            return "雾"
        case 51, 53, 55:
            return "毛毛雨"
        case 56, 57:
            return "冻毛毛雨"
        case 61, 63, 65:
            return "降雨"
        case 66, 67:
            return "冻雨"
        case 71, 73, 75:
            return "降雪"
        case 77:
            return "雪粒"
        case 80, 81, 82:
            return "阵雨"
        case 85, 86:
            return "阵雪"
        case 95:
            return "雷暴"
        case 96, 99:
            return "雷暴伴冰雹"
        default:
            return "天气未知"
        }
    }
}
