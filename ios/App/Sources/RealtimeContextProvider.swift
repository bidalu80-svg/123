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

    private struct ChinaFuelPriceSnapshot {
        let province: String
        let gasoline92: Double
        let gasoline95: Double
        let gasoline98: Double
        let diesel0: Double
        let updateDate: String?
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
    private var chinaFuelCache: [String: CachedEntry] = [:]

    private let weatherTTL: TimeInterval = 15 * 60
    private let marketTTL: TimeInterval = 5 * 60
    private let hotNewsTTL: TimeInterval = 10 * 60
    private let realtimeLineTimeout: TimeInterval = 1.6

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

    func prewarm(config: ChatConfig, now: Date = Date()) async {
        guard config.realtimeContextEnabled else { return }
        async let weatherWarm: String? = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeWeatherContextLine(config: config, userPrompt: "天气", now: now)
        }
        async let marketWarm: String? = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeMarketContextLine(config: config, userPrompt: "股市油价金价", now: now)
        }
        async let hotNewsWarm: String? = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeHotNewsContextLine(config: config, userPrompt: "新闻热点", now: now)
        }
        _ = await (weatherWarm, marketWarm, hotNewsWarm)
    }

    func buildSystemContext(config: ChatConfig, userPrompt: String? = nil, now: Date = Date()) async -> String? {
        guard config.realtimeContextEnabled else { return nil }
        let wantsDateTime = shouldInjectDateTimeContext(for: userPrompt)
        let wantsWeather = config.weatherContextEnabled && shouldInjectWeatherContext(for: userPrompt)
        let wantsMarket = config.marketContextEnabled && shouldInjectMarketContext(for: userPrompt)
        let wantsHotNews = config.hotNewsContextEnabled && shouldInjectHotNewsContext(for: userPrompt)
        let wantsFuel = (userPrompt != nil) && shouldInjectChinaFuelPrice(for: userPrompt ?? "")

        guard wantsDateTime || wantsWeather || wantsMarket || wantsHotNews || wantsFuel else {
            return nil
        }

        var lines: [String] = []
        lines.append("以下是系统实时信息（仅供当前回答参考）：")
        if wantsDateTime {
            lines.append(buildDateTimeLine(now: now))
        }

        // Build external realtime context in parallel to reduce first-message latency.
        async let weatherLine = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeWeatherContextLine(config: config, userPrompt: userPrompt, now: now)
        }
        async let marketLine = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeMarketContextLine(config: config, userPrompt: userPrompt, now: now)
        }
        async let hotNewsLine = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeHotNewsContextLine(config: config, userPrompt: userPrompt, now: now)
        }
        async let fuelLine = resolveLineWithTimeout(seconds: realtimeLineTimeout) { [self] in
            await makeChinaFuelContextLine(userPrompt: userPrompt, now: now)
        }

        let resolvedWeatherLine = await weatherLine
        let resolvedMarketLine = await marketLine
        let resolvedHotNewsLine = await hotNewsLine
        let resolvedFuelLine = await fuelLine

        if let resolvedWeatherLine {
            lines.append(resolvedWeatherLine)
        }
        if let resolvedMarketLine {
            lines.append(resolvedMarketLine)
        }
        if let resolvedHotNewsLine {
            lines.append(resolvedHotNewsLine)
        }
        if let resolvedFuelLine {
            lines.append(resolvedFuelLine)
        }

        lines.append("以上信息会随时间变化，回答价格或事件时请注明“以最新市场为准”。")
        return lines.joined(separator: "\n")
    }

    private func resolveLineWithTimeout(
        seconds: TimeInterval,
        operation: @Sendable @escaping () async -> String?
    ) async -> String? {
        let timeoutNanoseconds = UInt64(max(0.1, seconds) * 1_000_000_000)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    private func makeWeatherContextLine(config: ChatConfig, userPrompt: String?, now: Date) async -> String? {
        guard config.weatherContextEnabled else { return nil }
        guard shouldInjectWeatherContext(for: userPrompt) else { return nil }
        let location = config.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return nil }

        if let weatherLine = try? await fetchWeatherSummary(location: location, now: now) {
            return weatherLine
        }
        return "天气：\(location) 暂时获取失败。"
    }

    private func makeMarketContextLine(config: ChatConfig, userPrompt: String?, now: Date) async -> String? {
        guard config.marketContextEnabled else { return nil }
        guard shouldInjectMarketContext(for: userPrompt) else { return nil }
        let inferredSymbols = inferSymbols(from: userPrompt ?? "")
        let symbols = mergeSymbols(parseSymbols(config.marketSymbols), inferredSymbols)
        guard !symbols.isEmpty else { return nil }

        if let marketLine = try? await fetchMarketSummary(symbols: symbols, now: now) {
            return marketLine
        }
        return "市场价格：暂时获取失败。"
    }

    private func makeHotNewsContextLine(config: ChatConfig, userPrompt: String?, now: Date) async -> String? {
        guard config.hotNewsContextEnabled else { return nil }
        guard shouldInjectHotNewsContext(for: userPrompt) else { return nil }

        if let newsBlock = try? await fetchHotNewsSummary(count: config.hotNewsCount, now: now) {
            return newsBlock
        }
        return "热门事件：暂时获取失败。"
    }

    private func makeChinaFuelContextLine(userPrompt: String?, now: Date) async -> String? {
        guard let prompt = userPrompt, shouldInjectChinaFuelPrice(for: prompt) else { return nil }

        if let fuelLine = try? await fetchChinaFuelSummary(from: prompt, now: now) {
            return fuelLine
        }
        return "中国成品油（省级）价格：暂时获取失败。"
    }

    private func shouldInjectChinaFuelPrice(for prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        if lowered.contains("油价") || lowered.contains("汽油") || lowered.contains("柴油") {
            return true
        }
        return false
    }

    private func shouldInjectDateTimeContext(for prompt: String?) -> Bool {
        let lowered = (prompt ?? "").lowercased()
        guard !lowered.isEmpty else { return false }
        let keywords = [
            "现在几点", "几点", "时间", "日期", "今天几号", "星期几", "当前时间",
            "what time", "current time", "date today", "today date", "time now"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private func shouldInjectWeatherContext(for prompt: String?) -> Bool {
        let lowered = (prompt ?? "").lowercased()
        guard !lowered.isEmpty else { return false }
        let keywords = [
            "天气", "温度", "气温", "下雨", "降雨", "风速", "湿度", "体感", "forecast", "weather", "temperature", "rain"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private func shouldInjectMarketContext(for prompt: String?) -> Bool {
        let lowered = (prompt ?? "").lowercased()
        guard !lowered.isEmpty else { return false }
        if !inferSymbols(from: lowered).isEmpty { return true }
        let keywords = [
            "股市", "股票", "指数", "大盘", "行情", "市值", "油价", "金价", "汇率", "币价", "期货",
            "market", "stock", "stocks", "index", "indices", "price", "prices", "forex", "crypto", "commodity"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private func shouldInjectHotNewsContext(for prompt: String?) -> Bool {
        let lowered = (prompt ?? "").lowercased()
        guard !lowered.isEmpty else { return false }
        let keywords = [
            "新闻", "热点", "热搜", "时事", "最新消息", "发生了什么", "头条", "news", "headline", "headlines", "breaking", "latest"
        ]
        return keywords.contains { lowered.contains($0) }
    }

    private func fetchChinaFuelSummary(from prompt: String, now: Date) async throws -> String {
        let province = detectProvince(from: prompt) ?? "广东"
        let cacheKey = province.lowercased()
        if let cached = chinaFuelCache[cacheKey], now.timeIntervalSince(cached.timestamp) < 30 * 60 {
            return cached.summary
        }

        let snapshot = try await fetchChinaFuelPrice(province: province)
        let updateTime = snapshot.updateDate ?? formatTime(now, timeZone: .current)
        let summary = String(
            format: "中国油价（%@，更新 %@）：92# %.2f，95# %.2f，98# %.2f，0#柴油 %.2f（元/升）",
            snapshot.province,
            updateTime,
            snapshot.gasoline92,
            snapshot.gasoline95,
            snapshot.gasoline98,
            snapshot.diesel0
        )

        chinaFuelCache[cacheKey] = CachedEntry(summary: summary, timestamp: now)
        return summary
    }

    private func fetchChinaFuelPrice(province: String) async throws -> ChinaFuelPriceSnapshot {
        let slug = provincePageSlug(for: province)
        guard let url = URL(string: "https://www.chayoujia.net/\(slug).html") else {
            throw ProviderError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ProviderError.badResponse
        }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
            throw ProviderError.noData
        }

        guard let prices = extractFuelPrices(from: html) else {
            throw ProviderError.noData
        }
        let updateDate = extractFuelUpdateDate(from: html)
        return ChinaFuelPriceSnapshot(
            province: provinceDisplayName(for: province),
            gasoline92: prices.0,
            gasoline95: prices.1,
            gasoline98: prices.2,
            diesel0: prices.3,
            updateDate: updateDate
        )
    }

    private func extractFuelPrices(from html: String) -> (Double, Double, Double, Double)? {
        let pattern = #"\]\s*([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange),
              match.numberOfRanges >= 5 else {
            return nil
        }

        func group(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: html) else { return nil }
            return Double(String(html[range]))
        }

        guard let p92 = group(1),
              let p95 = group(2),
              let p98 = group(3),
              let d0 = group(4) else {
            return nil
        }
        return (p92, p95, p98, d0)
    }

    private func extractFuelUpdateDate(from html: String) -> String? {
        let pattern = #"最后更新[:：]\s*([0-9]{4}-[0-9]{2}-[0-9]{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: nsRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private func detectProvince(from prompt: String) -> String? {
        let map: [String: String] = [
            "北京": "beijing",
            "天津": "tianjin",
            "河北": "hebei",
            "山西": "shanxi",
            "内蒙古": "neimenggu",
            "辽宁": "liaoning",
            "吉林": "jilin",
            "黑龙江": "heilongjiang",
            "上海": "shanghai",
            "江苏": "jiangsu",
            "浙江": "zhejiang",
            "安徽": "anhui",
            "福建": "fujian",
            "江西": "jiangxi",
            "山东": "shandong",
            "河南": "henan",
            "湖北": "hubei",
            "湖南": "hunan",
            "广东": "guangdong",
            "广西": "guangxi",
            "海南": "hainan",
            "重庆": "chongqing",
            "四川": "sichuan",
            "贵州": "guizhou",
            "云南": "yunnan",
            "西藏": "xizang",
            "陕西": "shanxisheng",
            "甘肃": "gansu",
            "青海": "qinghai",
            "宁夏": "ningxia",
            "新疆": "xinjiang"
        ]
        for key in map.keys where prompt.contains(key) {
            return key
        }
        return nil
    }

    private func provincePageSlug(for province: String) -> String {
        let map: [String: String] = [
            "北京": "beijing",
            "天津": "tianjin",
            "河北": "hebei",
            "山西": "shanxi",
            "内蒙古": "neimenggu",
            "辽宁": "liaoning",
            "吉林": "jilin",
            "黑龙江": "heilongjiang",
            "上海": "shanghai",
            "江苏": "jiangsu",
            "浙江": "zhejiang",
            "安徽": "anhui",
            "福建": "fujian",
            "江西": "jiangxi",
            "山东": "shandong",
            "河南": "henan",
            "湖北": "hubei",
            "湖南": "hunan",
            "广东": "guangdong",
            "广西": "guangxi",
            "海南": "hainan",
            "重庆": "chongqing",
            "四川": "sichuan",
            "贵州": "guizhou",
            "云南": "yunnan",
            "西藏": "xizang",
            "陕西": "shanxisheng",
            "甘肃": "gansu",
            "青海": "qinghai",
            "宁夏": "ningxia",
            "新疆": "xinjiang"
        ]
        return map[province] ?? "guangdong"
    }

    private func provinceDisplayName(for province: String) -> String {
        province.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let envelope = try await fetchYahooQuotes(symbols: normalized)
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

    private func fetchYahooQuotes(symbols: [String]) async throws -> YahooQuoteEnvelope {
        let hosts = [
            "https://query1.finance.yahoo.com/v7/finance/quote",
            "https://query2.finance.yahoo.com/v7/finance/quote"
        ]

        var lastError: Error?
        for base in hosts {
            do {
                var components = URLComponents(string: base)
                components?.queryItems = [
                    URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))
                ]
                guard let url = components?.url else { throw ProviderError.invalidURL }
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw ProviderError.badResponse
                }
                return try JSONDecoder().decode(YahooQuoteEnvelope.self, from: data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ProviderError.noData
    }

    private func fetchHotNewsSummary(count: Int, now: Date) async throws -> String {
        let normalizedCount = min(max(count, 1), 12)
        if let cached = hotNewsCache[normalizedCount], now.timeIntervalSince(cached.timestamp) < hotNewsTTL {
            return cached.summary
        }

        var mergedTitles: [String] = []
        let feedURLs = hotNewsFeedURLs()
        let perFeedMaxItems = normalizedCount * 2
        await withTaskGroup(of: [String].self) { group in
            for url in feedURLs {
                group.addTask { [self] in
                    await fetchHeadlines(from: url, maxItems: perFeedMaxItems)
                }
            }

            for await titles in group {
                if !titles.isEmpty {
                    mergedTitles.append(contentsOf: titles)
                }
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

    private func fetchHeadlines(from url: URL, maxItems: Int) async -> [String] {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            let parser = RSSHeadlineParser(maxItems: maxItems)
            return parser.parse(data: data)
        } catch {
            return []
        }
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

    private func mergeSymbols(_ left: [String], _ right: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for symbol in (left + right) {
            let key = symbol.uppercased()
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(symbol)
        }
        return result
    }

    private func inferSymbols(from prompt: String) -> [String] {
        let normalized = prompt.lowercased()
        guard !normalized.isEmpty else { return [] }

        let map: [(keys: [String], symbols: [String])] = [
            (["油价", "原油", "wti"], ["CL=F"]),
            (["布伦特", "brent"], ["BZ=F"]),
            (["金价", "黄金", "gold"], ["GC=F"]),
            (["白银", "silver"], ["SI=F"]),
            (["铜价", "铜", "copper"], ["HG=F"]),
            (["比特币", "btc", "bitcoin"], ["BTC-USD"]),
            (["以太坊", "eth", "ethereum"], ["ETH-USD"]),
            (["纳斯达克", "纳指", "nasdaq"], ["^IXIC"]),
            (["标普", "sp500", "s&p"], ["^GSPC"]),
            (["道琼斯", "dow"], ["^DJI"]),
            (["恒生", "hsi"], ["^HSI"]),
            (["日经", "nikkei"], ["^N225"]),
            (["美元", "人民币", "usd/cny", "usdcny"], ["CNY=X"]),
            (["苹果", "aapl"], ["AAPL"]),
            (["英伟达", "nvidia", "nvda"], ["NVDA"]),
            (["特斯拉", "tesla", "tsla"], ["TSLA"]),
            (["微软", "msft"], ["MSFT"]),
            (["亚马逊", "amazon", "amzn"], ["AMZN"])
        ]

        var inferred: [String] = []
        for item in map {
            if item.keys.contains(where: { normalized.contains($0) }) {
                inferred.append(contentsOf: item.symbols)
            }
        }
        return inferred
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
