import Foundation
import Observation
import Security

// MARK: - API Response Models

struct LoginResponse: Decodable {
    let token: String
    let user: LoginUser
    let isNewUser: Bool
}

struct LoginUser: Decodable {
    let id: String
    let email: String
}

struct MembershipInfo: Decodable {
    let plan_type: String
    let status: String
    let expires_at: String?
}

struct UserMeResponse: Decodable {
    let id: String
    let email: String
    let membership: MembershipInfo
}

struct APIErrorResponse: Decodable {
    let error: String
}

// MARK: - AuthService

@Observable
@MainActor
final class AuthService {
    var isLoggedIn = false
    var userEmail: String?
    var membership: MembershipInfo?
    var isLoading = false
    var errorMessage: String?

    private var sessionToken: String?
    private let baseURL = "https://airtiz-cfnode.qaq-littlewhite.workers.dev"
    private let logger = SwiftLogger.shared

    // MARK: - Public API

    /// Send verification code to email
    func sendCode(email: String) async -> Bool {
        errorMessage = nil
        let url = URL(string: "\(baseURL)/auth/send-code")!
        let emailForLog = Self.maskedEmail(email)
        logger.info("[Auth] HTTP POST \(url.path) 开始 email=\(emailForLog)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["email": email])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logger.error("[Auth] HTTP POST \(url.path) 失败: 响应非 HTTPURLResponse")
                return false
            }
            if http.statusCode == 200 {
                logger.info("[Auth] HTTP POST \(url.path) 成功 status=200 email=\(emailForLog)")
                return true
            } else {
                let parsedError = parseError(data)
                errorMessage = parsedError ?? "发送失败 (\(http.statusCode))"
                logger.warn("[Auth] HTTP POST \(url.path) 失败 status=\(http.statusCode) email=\(emailForLog) error=\(errorMessage ?? "<nil>")")
                return false
            }
        } catch {
            errorMessage = "网络错误: \(error.localizedDescription)"
            logger.error("[Auth] HTTP POST \(url.path) 异常 email=\(emailForLog): \(error.localizedDescription)")
            return false
        }
    }

    /// Login with email + verification code
    func login(email: String, code: String) async -> Bool {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/auth/login")!
        let emailForLog = Self.maskedEmail(email)
        logger.info("[Auth] HTTP POST \(url.path) 开始 email=\(emailForLog)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "email": email,
            "code": code,
            "deviceName": Host.current().localizedName ?? "Mac",
            "deviceType": "macos"
        ]
        request.httpBody = try? JSONEncoder().encode(body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logger.error("[Auth] HTTP POST \(url.path) 失败: 响应非 HTTPURLResponse")
                return false
            }
            if http.statusCode == 200 {
                let loginResp = try JSONDecoder().decode(LoginResponse.self, from: data)
                sessionToken = loginResp.token
                KeychainHelper.save(token: loginResp.token)
                userEmail = loginResp.user.email
                isLoggedIn = true
                logger.info("[Auth] HTTP POST \(url.path) 成功 status=200 email=\(emailForLog) isNewUser=\(loginResp.isNewUser)")
                // Fetch membership info
                await fetchMe()
                return true
            } else {
                let parsedError = parseError(data)
                errorMessage = parsedError ?? "登录失败 (\(http.statusCode))"
                logger.warn("[Auth] HTTP POST \(url.path) 失败 status=\(http.statusCode) email=\(emailForLog) error=\(errorMessage ?? "<nil>")")
                return false
            }
        } catch {
            errorMessage = "网络错误: \(error.localizedDescription)"
            logger.error("[Auth] HTTP POST \(url.path) 异常 email=\(emailForLog): \(error.localizedDescription)")
            return false
        }
    }

    /// Logout current session
    func logout() async {
        guard let token = sessionToken else {
            logger.info("[Auth] HTTP POST /auth/logout 跳过: sessionToken 不存在")
            clearSession()
            return
        }
        isLoading = true
        defer { isLoading = false }

        let url = URL(string: "\(baseURL)/auth/logout")!
        let emailForLog = Self.maskedEmail(userEmail ?? "")
        logger.info("[Auth] HTTP POST \(url.path) 开始 email=\(emailForLog)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                logger.info("[Auth] HTTP POST \(url.path) 完成 status=\(http.statusCode) email=\(emailForLog)")
            } else {
                logger.warn("[Auth] HTTP POST \(url.path) 完成但响应非 HTTPURLResponse")
            }
        } catch {
            logger.warn("[Auth] HTTP POST \(url.path) 异常 email=\(emailForLog): \(error.localizedDescription)")
        }
        clearSession()
    }

    /// Fetch current user info and membership
    func fetchMe() async {
        guard let token = sessionToken else {
            logger.info("[Auth] HTTP GET /user/me 跳过: sessionToken 不存在")
            return
        }

        let url = URL(string: "\(baseURL)/user/me")!
        let emailForLog = Self.maskedEmail(userEmail ?? "")
        logger.info("[Auth] HTTP GET \(url.path) 开始 email=\(emailForLog)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                logger.error("[Auth] HTTP GET \(url.path) 失败: 响应非 HTTPURLResponse")
                return
            }
            if http.statusCode == 200 {
                let me = try JSONDecoder().decode(UserMeResponse.self, from: data)
                userEmail = me.email
                membership = me.membership
                isLoggedIn = true
                logger.info("[Auth] HTTP GET \(url.path) 成功 status=200 email=\(Self.maskedEmail(me.email)) plan=\(me.membership.plan_type) membership=\(me.membership.status)")
            } else if http.statusCode == 401 {
                // Token expired
                logger.warn("[Auth] HTTP GET \(url.path) 失败 status=401: token 已过期")
                clearSession()
            } else {
                let parsedError = parseError(data)
                logger.warn("[Auth] HTTP GET \(url.path) 失败 status=\(http.statusCode) error=\(parsedError ?? "<nil>")")
            }
        } catch {
            // Network error — keep current state, don't log out
            logger.warn("[Auth] HTTP GET \(url.path) 异常 email=\(emailForLog): \(error.localizedDescription)")
        }
    }

    /// Restore session from Keychain on app launch
    func restoreSession() async {
        guard let token = KeychainHelper.loadToken() else {
            logger.info("[Auth] restoreSession 跳过: Keychain 无 token")
            return
        }
        logger.info("[Auth] restoreSession 开始: Keychain 已命中 token")
        sessionToken = token
        await fetchMe()
    }

    // MARK: - Helpers

    private func clearSession() {
        sessionToken = nil
        isLoggedIn = false
        userEmail = nil
        membership = nil
        KeychainHelper.deleteToken()
    }

    private func parseError(_ data: Data) -> String? {
        try? JSONDecoder().decode(APIErrorResponse.self, from: data).error
    }

    /// Mask email for display: "abc***@example.com"
    static func maskedEmail(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return email }
        let local = email[email.startIndex..<atIndex]
        let domain = email[atIndex...]
        if local.count <= 3 {
            return "\(local)***\(domain)"
        }
        let prefix = local.prefix(3)
        return "\(prefix)***\(domain)"
    }

    /// Display text for plan type
    static func planDisplayName(_ planType: String) -> String {
        switch planType {
        case "monthly": return "月度会员"
        case "lifetime": return "终身会员"
        default: return "免费版"
        }
    }

    /// Display text for membership status
    static func statusDisplayName(_ status: String) -> String {
        switch status {
        case "active": return "生效中"
        case "expired": return "已过期"
        case "paused": return "已暂停"
        case "past_due": return "欠费"
        case "canceled": return "已取消"
        default: return status
        }
    }

    /// Format ISO 8601 date string to readable format
    static func formatExpiryDate(_ isoString: String?) -> String? {
        guard let raw = isoString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()

        var parsedDate: Date? = isoWithFractional.date(from: raw) ?? iso.date(from: raw)
        if parsedDate == nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            let inputFormats = [
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd HH:mm",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy/MM/dd HH:mm:ss",
                "yyyy-MM-dd"
            ]
            for inputFormat in inputFormats {
                formatter.dateFormat = inputFormat
                if let date = formatter.date(from: raw) {
                    parsedDate = date
                    break
                }
            }
        }

        if let date = parsedDate {
            let display = DateFormatter()
            display.locale = Locale(identifier: "en_US_POSIX")
            display.timeZone = .current
            display.dateFormat = "yyyy-MM-dd"
            return display.string(from: date)
        }

        if raw.count >= 10 {
            let datePrefix = String(raw.prefix(10))
            if datePrefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                return datePrefix
            }
        }

        return raw
    }
}

// MARK: - Keychain Helper

private enum KeychainHelper {
    private static let service = "com.airtiz.session-token"
    private static let account = "session"

    static func save(token: String) {
        deleteToken()
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
