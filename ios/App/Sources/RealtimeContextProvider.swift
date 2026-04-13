import Foundation

actor RealtimeContextProvider {
    private struct CachedEntry {
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

    private struct YahooQuoteEnvelope: Decodable {
        let quoteResponse: YahooQuoteResponse
    }

    private struct YahooQuoteResponse: Decodable {
        let result: [YahooQuoteItem]
    }

    private struct YahooQuoteItem: Decodable {
        let symbol: String
        let shortName: String?
        let regularMarketPrice: Double?
        let regularMarketChangePercent: Double?
        let currency: String?
        let regularMarketTime: Int?
    }

    private enum ProviderError: Error {
        case invalidURL
        case badResponse
        case noData
    }

    private let session: URLSession

    private var weatherCache: [String: CachedEntry] = [:]
    private var locationCache: [String: GeocodingResult] = [:]
    private var marketCache: [String: CachedEntry] = [:]
    private var hotNewsCache: [Int: CachedEntry] = [:]

    private let weatherTTL: TimeInterval = 15 * 60
    private let marketTTL: TimeInterval = 5 * 60
    private let hotNewsTTL: TimeInterval = 10 * 60

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
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
                if let weatherLine = try? await fetchWeatherSummary(location: location, now: now) {
                    lines.append(weatherLine)
                } else {
                    lines.append("天气：\(location) 暂时获取失败。")
                }
            }
        }

        if config.marketContextEnabled {
            let symbols = parseSymbols(config.marketSymbols)
            if !symbols.isEmpty {
                if let marketLine = try? await fetchMarketSummary(symbols: symbols, now: now) {
                    lines.append(marketLine)
                } else {
                    lines.append("市场价格：暂时获取失败。")
                }
            }
        }

        if config.hotNewsContextEnabled {
            if let newsBlock = try? await fetchHotNewsSummary(count: config.hotNewsCount, now: now) {
                lines.append(newsBlock)
            } else {
                lines.append("热门事件：暂时获取失败。")
            }
        }

        lines.append("以上信息会随时间变化，回答价格或事件时请注明“以最新市场为准”。")
        return lines.joined(separator: "\n")
    }

    private func fetchWeatherSummary(location: String, now: Date) async throws -> String {
        let cacheKey = location.lowercased()
        if let cached = weatherCache[cacheKey], now.timeIntervalSince(cached.timestamp) < weatherTTL {
            return cached.summary
        }

        let place: GeocodingResult
        if let cachedPlace = locationCache[cacheKey] {
            place = cachedPlace
        } else {
            place = try await geocode(location: location)
            locationCache[cacheKey] = place
        }

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

        weatherCache[cacheKey] = CachedEntry(summary: summary, timestamp: now)
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

    private func fetchMarketSummary(symbols: [String], now: Date) async throws -> String {
        let normalized = symbols.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw ProviderError.noData }

        let cacheKey = normalized.joined(separator: ",").lowercased()
        if let cached = marketCache[cacheKey], now.timeIntervalSince(cached.timestamp) < marketTTL {
            return cached.summary
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote")
        components?.queryItems = [
            URLQueryItem(name: "symbols", value: normalized.joined(separator: ","))
        ]

        guard let url = components?.url else { throw ProviderError.invalidURL }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.badResponse
        }

        let envelope = try JSONDecoder().decode(YahooQuoteEnvelope.self, from: data)
        guard !envelope.quoteResponse.result.isEmpty else { throw ProviderError.noData }

        let updateTime = formatTime(now, timeZone: .current)
        var rows: [String] = ["市场价格（更新 \(updateTime)）："]

        for item in envelope.quoteResponse.result.prefix(12) {
            guard let price = item.regularMarketPrice else { continue }
            let displayName = marketDisplayName(symbol: item.symbol, fallback: item.shortName)
            let changePercent = item.regularMarketChangePercent ?? 0
            let signedChange = String(format: "%+.2f%%", changePercent)
            let currency = item.currency ?? ""
            let line = "\(displayName)：\(formatPrice(price)) \(currency)（\(signedChange)）"
            rows.append("• \(line)")
        }

        if rows.count == 1 {
            throw ProviderError.noData
        }

        let summary = rows.joined(separator: "\n")
        marketCache[cacheKey] = CachedEntry(summary: summary, timestamp: now)
        return summary
    }

    private func fetchHotNewsSummary(count: Int, now: Date) async throws -> String {
        let normalizedCount = min(max(count, 1), 12)
        if let cached = hotNewsCache[normalizedCount], now.timeIntervalSince(cached.timestamp) < hotNewsTTL {
            return cached.summary
        }

        var mergedTitles: [String] = []
        for url in hotNewsFeedURLs() {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                continue
            }

            let parser = RSSHeadlineParser(maxItems: normalizedCount * 2)
            let titles = parser.parse(data: data)
            if !titles.isEmpty {
                mergedTitles.append(contentsOf: titles)
            }
        }

        let titles = deduplicateHeadlines(mergedTitles).prefix(normalizedCount)
        guard !titles.isEmpty else { throw ProviderError.noData }

        let updateTime = formatTime(now, timeZone: .current)
        var rows: [String] = ["热门事件（更新 \(updateTime)）："]
        for title in titles {
            rows.append("• \(title)")
        }

        let summary = rows.joined(separator: "\n")
        hotNewsCache[normalizedCount] = CachedEntry(summary: summary, timestamp: now)
        return summary
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

    private func hotNewsFeedURLs() -> [URL] {
        [
            "https://news.google.com/rss?hl=zh-CN&gl=CN&ceid=CN:zh-Hans",
            "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en",
            "https://news.google.com/rss/headlines/section/topic/WORLD?hl=en-US&gl=US&ceid=US:en",
            "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=en-US&gl=US&ceid=US:en"
        ].compactMap(URL.init(string:))
    }

    private func deduplicateHeadlines(_ input: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in input {
            let key = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func parseSymbols(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func formatPrice(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return String(format: "%.2f", value)
        }
        if abs(value) >= 1 {
            return String(format: "%.3f", value)
        }
        return String(format: "%.5f", value)
    }

    private func marketDisplayName(symbol: String, fallback: String?) -> String {
        let map: [String: String] = [
            "GC=F": "黄金",
            "CL=F": "WTI 原油",
            "BZ=F": "布伦特原油",
            "SI=F": "白银",
            "HG=F": "铜",
            "^GSPC": "标普500",
            "^IXIC": "纳斯达克",
            "^DJI": "道琼斯",
            "^RUT": "罗素2000",
            "^N225": "日经225",
            "^HSI": "恒生指数",
            "^FTSE": "富时100",
            "^GDAXI": "德国DAX",
            "AAPL": "Apple",
            "NVDA": "NVIDIA",
            "TSLA": "Tesla",
            "MSFT": "Microsoft",
            "GOOGL": "Google",
            "AMZN": "Amazon"
        ]
        return map[symbol] ?? fallback ?? symbol
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

private final class RSSHeadlineParser: NSObject, XMLParserDelegate {
    private let maxItems: Int

    private var titles: [String] = []
    private var currentElement: String = ""
    private var currentTitle: String = ""
    private var insideItem = false

    init(maxItems: Int) {
        self.maxItems = maxItems
        super.init()
    }

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
        return titles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            insideItem = true
            currentTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem, currentElement == "title" else { return }
        currentTitle += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard insideItem, currentElement == "title", let text = String(data: CDATABlock, encoding: .utf8) else { return }
        currentTitle += text
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "title", insideItem {
            let normalized = normalizeHeadline(currentTitle)
            if !normalized.isEmpty && !titles.contains(normalized) {
                titles.append(normalized)
            }
        }

        if elementName == "item" {
            insideItem = false
            currentTitle = ""
        }

        if titles.count >= maxItems {
            parser.abortParsing()
        }
    }

    private func normalizeHeadline(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let removedSource: String
        if let range = trimmed.range(of: " - ") {
            removedSource = String(trimmed[..<range.lowerBound])
        } else {
            removedSource = trimmed
        }

        let compact = removedSource.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(compact.prefix(100))
    }
}
