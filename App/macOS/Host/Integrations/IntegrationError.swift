import Foundation

struct IntegrationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
