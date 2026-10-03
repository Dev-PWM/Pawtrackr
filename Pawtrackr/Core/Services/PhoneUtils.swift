//
//  PhoneUtils.swift
//  Pawtrackr
//
//  Created by mac on 8/14/25.
//  Upgraded by Assistant on 8/28/25.
//

import Foundation

/// Utility methods for working with United States (NANP) phone numbers.
/// This enum provides a single source of truth for normalizing, validating, formatting, and converting US phone numbers.
public enum PhoneUtils {

    // MARK: - Private Properties
    private static let vanityMap: [Character: Character] = [
        "A":"2", "B":"2", "C":"2", "D":"3", "E":"3", "F":"3", "G":"4", "H":"4", "I":"4",
        "J":"5", "K":"5", "L":"5", "M":"6", "N":"6", "O":"6", "P":"7", "Q":"7",
        "R":"7", "S":"7", "T":"8", "U":"8", "V":"8", "W":"9", "X":"9", "Y":"9", "Z":"9"
    ]

    // Static patterns; force-try is intentional. If they ever fail to compile,
    // crash at launch rather than silently degrading validation to "accept all".
    private static let nanpRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^[2-9]\d{2}[2-9]\d{6}$"#)
    }()

    private static let extRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\s*(x|ext\.?|extension|#)\s*(\d{1,10})\s*$"#)
    }()

    // MARK: - Public API

    /// Normalizes a phone number string by mapping vanity letters (e.g., "FLOWERS") to digits and stripping all non-numeric characters.
    /// - Parameter input: The raw string to normalize.
    /// - Returns: A string containing only digits.
    public static func normalize(_ input: String) -> String {
        let mapped = input.uppercased().map { vanityMap[$0] ?? $0 }
        return String(mapped.filter(\.isNumber))
    }

    /// Returns the digit-only lookup key, excluding extensions and the optional
    /// NANP country code. Keeps partial/legacy numbers searchable without changing them.
    public static func searchKey(_ input: String) -> String {
        let (main, _) = splitExtension(from: input)
        let digits = normalize(main)
        return digits.count == 11 && digits.first == "1" ? String(digits.dropFirst()) : digits
    }

    /// Performs a plausibility check for a US (NANP) phone number.
    /// It accepts 10 digits, or 11 digits starting with "1". It enforces NANP rules where the area and exchange codes cannot start with 0 or 1.
    /// - Parameter input: The phone number string to validate.
    /// - Returns: `true` if the number is a plausible US phone number.
    public static func isValidUS(_ input: String) -> Bool {
        guard let digits = tenDigits(from: input) else { return false }
        
        // Reject N11 service codes
        let area = digits.prefix(3)
        let exchange = digits.dropFirst(3).prefix(3)
        if area.hasSuffix("11") || exchange.hasSuffix("11") { return false }
        
        // Use regex to enforce NANP rules ([2-9]XX [2-9]XX XXXX)
        let range = NSRange(location: 0, length: digits.utf16.count)
        return nanpRegex.firstMatch(in: digits, options: [], range: range) != nil
    }

    /// Converts any valid US phone number string into the canonical E.164 format.
    /// - Parameter input: The raw phone number string (e.g., "(555) 123-4567 x123").
    /// - Returns: The number in "+1##########" format, or `nil` if the input is invalid. The extension is ignored.
    public static func toE164(_ input: String) -> String? {
        guard isValidUS(input), let digits = tenDigits(from: input) else { return nil }
        return "+1" + digits
    }

    /// Formats a valid US phone number for display.
    /// - Parameter input: The raw phone number string.
    /// - Parameter includeExtension: If `true`, any parsed extension will be appended.
    /// - Returns: A formatted string like "(555) 123-4567 x123", or `nil` if the input is invalid.
    public static func display(_ input: String, includeExtension: Bool = true) -> String? {
        guard isValidUS(input) else { return nil }
        let (main, ext) = splitExtension(from: input)
        guard let digits = tenDigits(from: main) else { return nil }
        
        let area = digits.prefix(3)
        let mid = digits.dropFirst(3).prefix(3)
        let last = digits.suffix(4)
        var formatted = "(\(area)) \(mid)-\(last)"
        
        if includeExtension, let ext = ext, !ext.isEmpty {
            formatted += " x\(ext)"
        }
        return formatted
    }

    /// Formats a phone number string progressively as a user types.
    /// - Parameters:
    ///   - input: Raw user input which may include spaces, punctuation, letters.
    ///   - includeExtension: When true, digits beyond 10 are appended as an "x123" extension.
    ///                        When false, the formatted output is clamped to the core 10 digits only.
    public static func formatAsYouType(_ input: String, includeExtension: Bool = true) -> String {
        let normalizedDigits = normalize(input)
        let digits: String
        if normalizedDigits.count >= 11, normalizedDigits.first == "1" {
            digits = String(normalizedDigits.dropFirst())
        } else {
            digits = normalizedDigits
        }
        if digits.isEmpty { return "" }
        
        let ten = String(digits.prefix(10))
        var formatted: String
        
        if ten.count <= 3 {
            formatted = "(\(ten)"
        } else if ten.count <= 6 {
            formatted = "(\(ten.prefix(3))) \(ten.dropFirst(3))"
        } else {
            formatted = "(\(ten.prefix(3))) \(ten.dropFirst(3).prefix(3))-\(ten.dropFirst(6))"
        }
        
        let ext = String(digits.dropFirst(10))
        if includeExtension, !ext.isEmpty {
            formatted += " x\(ext)"
        }

        return formatted
    }

    /// Formats complete phone numbers for text-field editing while leaving
    /// partial input untouched. SwiftUI can move the insertion point when the
    /// bound text is rewritten on every keystroke; waiting for a complete number
    /// avoids dropped/reordered digits during fast typing and paste operations.
    /// - Parameters:
    ///   - input: Raw user input to format for text-field editing.
    ///   - includeExtension: When true, digits beyond 10 are appended as an "x123" extension.
    /// - Returns: A formatted string suitable for text-field editing.
    public static func formatForEditing(_ input: String, includeExtension: Bool = true) -> String {
        let digits = normalize(input)
        let minimumCompleteDigitCount = digits.first == "1" ? 11 : 10
        guard digits.count >= minimumCompleteDigitCount else { return input }
        return formatAsYouType(input, includeExtension: includeExtension)
    }

    /// Masks a phone number for privacy, showing only the last 4 digits.
    /// - Returns: A formatted string like "(555) BBB-••••", or `nil` if the input is invalid.
    public static func displayMasked(_ input: String) -> String? {
        guard isValidUS(input), let ten = tenDigits(from: input) else { return nil }
        let area = ten.prefix(3)
        let last = ten.suffix(4)
        return "(\(area)) •••-\(last)"
    }
    
    /// Generates a `tel:` URL string from a valid phone number.
    public static func telURLString(_ input: String) -> String? {
        guard let e164 = toE164(input) else { return nil }
        return "tel:\(e164)"
    }

    /// Generates an `sms:` URL string from a valid phone number, optionally with a message body.
    public static func smsURLString(_ input: String, body: String? = nil) -> String? {
        guard let e164 = toE164(input) else { return nil }
        var components = URLComponents()
        components.scheme = "sms"
        components.path = e164
        
        if let body = body, !body.isEmpty {
            components.queryItems = [URLQueryItem(name: "body", value: body)]
        }
        
        return components.string
    }

    /// Generates a WhatsApp URL string from a valid phone number, optionally with a message body.
    public static func whatsappURLString(_ input: String, body: String? = nil) -> String? {
        guard isValidUS(input), let digits = tenDigits(from: input) else { return nil }
        // WhatsApp uses international format without the + (1##########)
        let phone = "1" + digits
        var components = URLComponents()
        components.scheme = "https"
        components.host = "wa.me"
        components.path = "/\(phone)"
        
        if let body = body, !body.isEmpty {
            components.queryItems = [URLQueryItem(name: "text", value: body)]
        }
        
        return components.string
    }

    // MARK: - Private Helpers

    /// Extracts the core 10 digits from a raw string, handling a leading "1".
    private static func tenDigits(from input: String) -> String? {
        let (main, _) = splitExtension(from: input)
        let digits = normalize(main)
        if digits.count == 11 && digits.first == "1" {
            return String(digits.dropFirst())
        } else if digits.count == 10 {
            return digits
        }
        return nil
    }

    /// Separates the main number from its extension.
    private static func splitExtension(from input: String) -> (main: String, ext: String?) {
        let lowercasedInput = input.lowercased()
        let fullRange = NSRange(location: 0, length: lowercasedInput.utf16.count)
        
        if let match = extRegex.firstMatch(in: lowercasedInput, options: [], range: fullRange) {
            if let extRange = Range(match.range(at: 2), in: lowercasedInput) {
                let extDigits = String(lowercasedInput[extRange])
                // Convert the whole match range from `lowercasedInput` to the corresponding prefix in the original `input` string.
                if let wholeRange = Range(match.range(at: 0), in: lowercasedInput) {
                    let prefixCount = lowercasedInput.distance(from: lowercasedInput.startIndex, to: wholeRange.lowerBound)
                    let cutoff = input.index(input.startIndex, offsetBy: prefixCount)
                    let mainPart = String(input[..<cutoff])
                    return (mainPart.trimmingCharacters(in: .whitespacesAndNewlines), extDigits)
                }
            }
        }
        return (input.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
    
    // MARK: - Deprecations
    @available(*, deprecated, renamed: "isValidUS", message: "Use the more specific 'isValidUS'.")
    public static func isValid(_ input: String) -> Bool { isValidUS(input) }
}
