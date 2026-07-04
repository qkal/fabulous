import Foundation

/// Node abstraction over the AX tree so the walk's bounding logic
/// (depth, chars, nodes, secure-field skip, time-box) unit-tests
/// without live Accessibility.
public protocol TextHarvestNode {
    var subrole: String? { get }
    var title: String? { get }
    var textValue: String? { get }
    var children: [Self] { get }
}

/// Depth-first text collection with hard bounds — a misbehaving or
/// enormous window must cost bounded work, never a hang.
public enum TextHarvester {
    public static let defaultMaxDepth = 12
    public static let defaultCharCap = 20_000
    public static let defaultNodeCap = 2_000
    /// Password fields and anything inside them are never read.
    public static let secureSubrole = "AXSecureTextField"

    public static func harvest<Node: TextHarvestNode>(
        _ root: Node,
        maxDepth: Int = defaultMaxDepth,
        charCap: Int = defaultCharCap,
        nodeCap: Int = defaultNodeCap,
        shouldContinue: () -> Bool = { true }
    ) -> [String] {
        var pieces: [String] = []
        var chars = 0
        var nodes = 0

        func visit(_ node: Node, depth: Int) {
            guard shouldContinue(), depth <= maxDepth, chars < charCap, nodes < nodeCap
            else { return }
            nodes += 1
            guard node.subrole != secureSubrole else { return }
            for text in [node.title, node.textValue] {
                guard let text, !text.isEmpty, chars < charCap else { continue }
                let piece = String(text.prefix(charCap - chars))
                pieces.append(piece)
                chars += piece.count
            }
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return pieces
    }
}
