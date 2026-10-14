import Foundation

/// How a company has been seen taking on freshers. The raw values are the ones
/// the Fresher Hiring Ledger uses, stored as-is in `companies.hiring_routes` and
/// `company_sources.route`.
enum HiringRoute: String, CaseIterable, Identifiable, Hashable {
    case offCampusHire = "off_campus_hire_or_interview"
    case offCampusOpening = "off_campus_opening"
    case routeUnclear = "route_unclear"
    case onCampus = "on_campus"
    case internConversion = "intern_conversion_or_ppo"
    case internPlusFTE = "six_month_intern_plus_fte"

    var id: String { rawValue }

    /// Strongest first: an off-campus hire is the best evidence that applying
    /// from outside works, an internship conversion the weakest.
    static let ordered: [HiringRoute] = [
        .offCampusHire, .offCampusOpening, .routeUnclear, .onCampus, .internConversion, .internPlusFTE
    ]

    var title: String {
        switch self {
        case .offCampusHire: "Off-campus hire"
        case .offCampusOpening: "Off-campus opening"
        case .routeUnclear: "Route unclear"
        case .onCampus: "On campus"
        case .internConversion: "Intern conversion / PPO"
        case .internPlusFTE: "6-month intern + FTE"
        }
    }

    /// One line on what the route means, for the editor and VoiceOver.
    var detail: String {
        switch self {
        case .offCampusHire: "Someone applied from outside and was interviewed or hired."
        case .offCampusOpening: "A fresher role was posted openly."
        case .routeUnclear: "An offer was reported without saying how it came about."
        case .onCampus: "Hired through a college placement drive."
        case .internConversion: "An intern was converted, or got a pre-placement offer."
        case .internPlusFTE: "A six-month internship that leads to a full-time offer."
        }
    }

    var systemImage: String {
        switch self {
        case .offCampusHire: "person.crop.circle.badge.checkmark"
        case .offCampusOpening: "megaphone.fill"
        case .routeUnclear: "questionmark.circle"
        case .onCampus: "building.columns.fill"
        case .internConversion: "arrow.up.forward.circle"
        case .internPlusFTE: "calendar.badge.clock"
        }
    }

    var category: RouteCategory {
        switch self {
        case .offCampusHire, .offCampusOpening: .offCampus
        case .routeUnclear: .unclear
        case .onCampus, .internConversion, .internPlusFTE: .campusOrIntern
        }
    }
}

/// The one bucket a company falls in, from the strongest route it has: any
/// off-campus evidence wins, then an unclear route, then campus or intern only.
/// Stored in `companies.route_category` so the catalog can be filtered by it.
enum RouteCategory: String, CaseIterable, Hashable {
    case offCampus = "off_campus"
    case unclear = "route_unclear"
    case campusOrIntern = "on_campus_or_intern_only"

    var title: String {
        switch self {
        case .offCampus: "Off-campus"
        case .unclear: "Route unclear"
        case .campusOrIntern: "Campus or intern only"
        }
    }

    /// The category a set of routes adds up to, or nil for none.
    static func of(_ routes: [HiringRoute]) -> RouteCategory? {
        if routes.contains(where: { $0.category == .offCampus }) { return .offCampus }
        if routes.contains(.routeUnclear) { return .unclear }
        return routes.isEmpty ? nil : .campusOrIntern
    }
}

/// Which slice of the catalog the Companies tab lists. Every scope but `all`
/// is a fresher-hiring one, filtered by the server so it pages like the rest.
enum CatalogScope: String, CaseIterable, Identifiable, Hashable {
    case all, fresher, openNow, offCampus, campusOrIntern, routeUnclear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .fresher: "Freshers"
        case .openNow: "Open now"
        case .offCampus: "Off-campus"
        case .campusOrIntern: "Campus & intern"
        case .routeUnclear: "Route unclear"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "building.2"
        case .fresher: "graduationcap.fill"
        case .openNow: "dot.radiowaves.left.and.right"
        case .offCampus: "megaphone.fill"
        case .campusOrIntern: "building.columns.fill"
        case .routeUnclear: "questionmark.circle"
        }
    }

    /// The PostgREST filters that select this scope.
    var filters: [URLQueryItem] {
        let fresher = URLQueryItem(name: "is_fresher", value: "is.true")
        switch self {
        case .all: return []
        case .fresher: return [fresher]
        case .openNow: return [fresher, URLQueryItem(name: "open_now", value: "is.true")]
        case .offCampus: return [fresher, URLQueryItem(name: "route_category", value: "eq.\(RouteCategory.offCampus.rawValue)")]
        case .campusOrIntern: return [fresher, URLQueryItem(name: "route_category", value: "eq.\(RouteCategory.campusOrIntern.rawValue)")]
        case .routeUnclear: return [fresher, URLQueryItem(name: "route_category", value: "eq.\(RouteCategory.unclear.rawValue)")]
        }
    }

    /// The same test, made on a company already in memory — for search hits,
    /// which come from the whole catalog.
    func includes(_ job: Job) -> Bool {
        switch self {
        case .all: true
        case .fresher: job.isFresher
        case .openNow: job.isFresher && job.isOpenNow
        case .offCampus: job.isFresher && job.routeCategory == .offCampus
        case .campusOrIntern: job.isFresher && job.routeCategory == .campusOrIntern
        case .routeUnclear: job.isFresher && job.routeCategory == .unclear
        }
    }
}

/// The kinds of company the ledger sorts into. Free text in the database, so a
/// type typed in the editor that isn't one of these still shows.
enum CompanyType {
    static let known = [
        "Product / MNC", "Startup / Indian scale-up", "IT services / consulting",
        "Bank / fintech MNC", "Quant / HFT", "Indian enterprise"
    ]
}

/// A piece of evidence that a company hires freshers — a job post, an offer
/// write-up, a placement page — backed by a `company_sources` row. Shared, like
/// contacts: marking one invalid takes it out of the stated package for everyone.
struct CompanySource: Identifiable, Decodable, Equatable, Hashable {
    var id: String = ""
    var companyID: String = ""
    /// The ledger company it came from; nil when it was added in the app.
    var ledgerID: String?
    var route: String = HiringRoute.offCampusOpening.rawValue
    var role: String?
    var location: String?
    var batch: String?
    var sourceCode: String?
    var sourceLabel: String?
    var url: String?
    /// A permanent snapshot proving the posting existed (a tracker commit).
    var proofURL: String?
    /// YYYY-MM-DD, or YYYY-MM when only the month is known.
    var postedOn: String?
    var confidence: String?
    var isOpenNow = false
    /// Lakh rupees a year, when the source gives one number.
    var packageLPA: Double?
    /// The package as written, when it's a range or has notes ("₹4–4.5L").
    var packageText: String?
    var isValid = true

    enum CodingKeys: String, CodingKey {
        case id, route, role, location, batch, url, confidence
        case companyID = "company_id"
        case ledgerID = "ledger_id"
        case sourceCode = "source_code"
        case sourceLabel = "source_label"
        case proofURL = "proof_url"
        case postedOn = "posted_on"
        case isOpenNow = "open_now"
        case packageLPA = "package_lpa"
        case packageText = "package_text"
        case isValid = "is_valid"
    }

    init(companyID: String) {
        self.companyID = companyID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        companyID = try c.decode(String.self, forKey: .companyID)
        ledgerID = try c.decodeIfPresent(String.self, forKey: .ledgerID)
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? HiringRoute.routeUnclear.rawValue
        role = try c.decodeIfPresent(String.self, forKey: .role)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        batch = try c.decodeIfPresent(String.self, forKey: .batch)
        sourceCode = try c.decodeIfPresent(String.self, forKey: .sourceCode)
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        proofURL = try c.decodeIfPresent(String.self, forKey: .proofURL)
        postedOn = try c.decodeIfPresent(String.self, forKey: .postedOn)
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence)
        isOpenNow = try c.decodeIfPresent(Bool.self, forKey: .isOpenNow) ?? false
        // `numeric` comes back as a JSON number, or as a string from some
        // PostgREST settings — take either.
        if let number = try? c.decodeIfPresent(Double.self, forKey: .packageLPA) {
            packageLPA = number
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .packageLPA) {
            packageLPA = Double(text)
        }
        packageText = try c.decodeIfPresent(String.self, forKey: .packageText)
        isValid = try c.decodeIfPresent(Bool.self, forKey: .isValid) ?? true
    }

    var hiringRoute: HiringRoute? { HiringRoute(rawValue: route) }

    /// What this source is, on screen: the role, else the route.
    var title: String {
        let role = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return role.isEmpty ? (hiringRoute?.title ?? "Hiring evidence") : role
    }

    /// Where it was found: the label, else the link's host.
    var origin: String {
        if let label = sourceLabel?.trimmingCharacters(in: .whitespaces), !label.isEmpty { return label }
        return link?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Added by hand"
    }

    var link: URL? { CompanyLink.url(url) }
    var proofLink: URL? { CompanyLink.url(proofURL) }

    /// The stated package, formatted: "₹16.5 LPA", or the text as written.
    var package: String? {
        if let packageLPA { return PackageFormat.lpa(packageLPA) }
        let text = packageText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// The package in lakhs a year, as a range: the number when there is one,
    /// else the figures in the written package ("₹7–21L by band" is 7…21,
    /// "₹15L base" is 15). Nil when neither says.
    var packageRange: ClosedRange<Double>? {
        if let packageLPA { return packageLPA...packageLPA }
        guard let text = packageText, PackageFormat.isLakhs(text) else { return nil }
        let figures = PackageFormat.figures(in: text)
        guard let low = figures.min(), let high = figures.max() else { return nil }
        return low...high
    }

    /// The posting date as a day, when the source gives one.
    var date: Date? { PostedDate.parse(postedOn) }

    /// "12 Mar 2026", "Mar 2026", or nil.
    var dateLabel: String? { PostedDate.label(postedOn) }

    /// Whether this answers a (trimmed, non-empty) search.
    func matches(_ query: String) -> Bool {
        [role, location, batch, sourceLabel, url, packageText, hiringRoute?.title]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension Array where Element == CompanySource {
    /// Open postings first, then newest first; undated ones last.
    func sortedForDisplay() -> [CompanySource] {
        sorted { a, b in
            if a.isOpenNow != b.isOpenNow { return a.isOpenNow }
            switch (a.postedOn, b.postedOn) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }
}

/// What a company's valid sources say it pays.
struct StatedPackage {
    /// Every valid source that states a package, highest first.
    let sources: [CompanySource]
    /// The range of the single-number packages, in LPA.
    let low: Double?
    let high: Double?

    init(_ all: [CompanySource]) {
        let stated = all.filter { $0.isValid && $0.package != nil }
        sources = stated.sorted { ($0.packageRange?.upperBound ?? -1) > ($1.packageRange?.upperBound ?? -1) }
        let ranges = stated.compactMap(\.packageRange)
        low = ranges.map(\.lowerBound).min()
        high = ranges.map(\.upperBound).max()
    }

    var isEmpty: Bool { sources.isEmpty }

    /// "₹16.5 LPA", "₹6.6–28.8 LPA", or the one written package when none is a number.
    var headline: String? {
        if let low, let high {
            return low == high ? PackageFormat.lpa(high) : PackageFormat.range(low, high)
        }
        return sources.first?.package
    }
}

enum PackageFormat {
    /// "₹16.5 LPA" — one decimal at most, none when it's whole.
    static func lpa(_ value: Double) -> String { "₹\(number(value)) LPA" }

    static func range(_ low: Double, _ high: Double) -> String { "₹\(number(low))–\(number(high)) LPA" }

    /// Whether written package text is in lakhs ("₹4–4.5L", "₹12 LPA", "16
    /// lakh") rather than something else (a monthly stipend, a dollar figure).
    static func isLakhs(_ text: String) -> Bool {
        text.range(of: #"\d\s*(L\b|LPA|lakh|lac)"#, options: [.regularExpression, .caseInsensitive]) != nil
            && text.range(of: #"(\$|USD|per month|/month|pm\b|stipend)"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// The plausible yearly figures in lakh text: 0.5 to 200.
    static func figures(in text: String) -> [Double] {
        let pattern = #"\d+(?:\.\d+)?"#
        var out: [Double] = []
        var rest = text[...]
        while let r = rest.range(of: pattern, options: .regularExpression) {
            if let value = Double(rest[r]), (0.5...200).contains(value) { out.append(value) }
            rest = rest[r.upperBound...]
        }
        return out
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

/// The dates sources carry: a day, or only a month.
enum PostedDate {
    /// A day as stored: "2026-03-12".
    static func string(from date: Date) -> String { day.string(from: date) }

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return day.date(from: raw) ?? month.date(from: raw)
    }

    static func label(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let date = day.date(from: raw) {
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if let date = month.date(from: raw) {
            return date.formatted(.dateTime.month(.abbreviated).year())
        }
        return raw.isEmpty ? nil : raw
    }

    private static let day = formatter("yyyy-MM-dd")
    private static let month = formatter("yyyy-MM")

    /// In the phone's own time zone, as the date picker that edits them is:
    /// a posting date is a calendar day, not an instant.
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        f.isLenient = false
        return f
    }
}

/// Website and careers links: tidied when typed, checked before they're saved.
enum CompanyLink {
    /// A link as an `https` URL with a real host, or nil. "stripe.com" becomes
    /// "https://stripe.com"; anything that isn't a web address is rejected.
    static func url(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host(), MailDomain.isWellFormed(host.lowercased()) else { return nil }
        return url
    }

    /// What's stored: the tidied link, or nil for an empty field.
    static func normalized(_ raw: String) -> String? {
        url(raw)?.absoluteString
    }

    /// "careers.stripe.com/jobs", for a link's label: no scheme, no "www.",
    /// no trailing slash.
    static func display(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.lowercased().hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// How a company's website or careers page was found, in words.
enum LinkProvenance {
    static func label(_ source: String?) -> String? {
        switch source {
        case "wikidata": "Wikidata"
        case "verified_lookup": "Verified lookup"
        case "careers_page": "Its careers page"
        case "manual": "Checked by hand"
        case "evidence_link", "evidence": "A hiring source"
        case "mail_domain": "Its mail domain"
        case "website": "Its website"
        case "ledger": "Fresher Hiring Ledger"
        case "edited": "Edited in Aurora"
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: nil
        }
    }
}
