import Foundation

protocol GitCommand<Output> {
    associatedtype Output
    var arguments: [String] { get }
    func parse(output: String) throws -> Output
}
