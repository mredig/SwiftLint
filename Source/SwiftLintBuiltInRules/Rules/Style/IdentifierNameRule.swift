import Foundation
import SwiftSyntax

struct IdentifierNameRule: SwiftSyntaxRule, ConfigurationProviderRule {
    var configuration = NameConfiguration<Self>(
        minLengthWarning: 3,
        minLengthError: 2,
        maxLengthWarning: 40,
        maxLengthError: 60,
        excluded: ["id"])

    static let description = RuleDescription(
        identifier: "identifier_name",
        name: "Identifier Name",
        description: """
           Identifier names should only contain alphanumeric characters and \
           start with a lowercase character or should only contain capital letters. \
           In an exception to the above, variable names may start with a capital letter \
           when they are declared as static. Variable names should not be too \
           long or too short
           """,
        kind: .style,
        nonTriggeringExamples: IdentifierNameRuleExamples.nonTriggeringExamples,
        triggeringExamples: IdentifierNameRuleExamples.triggeringExamples,
        deprecatedAliases: ["variable_name"]
    )

	func makeVisitor(file: SwiftLintFile) -> ViolationsSyntaxVisitor {
		Visitor(configuration: configuration, sourceLocationConverter: file.locationConverter)
	}
}

extension IdentifierNameRule {
    final class Visitor: ViolationsSyntaxVisitor {
        typealias Parent = IdentifierNameRule
        private var configuration: NameConfiguration<Parent>
        private var configurationStack: [NameConfiguration<Parent>] = []

        static private let maximumClosureLineCount = 10

        let sourceLocationConverter: SourceLocationConverter

        init(
            configuration: NameConfiguration<Parent>,
            sourceLocationConverter: SourceLocationConverter) {
                self.sourceLocationConverter = sourceLocationConverter
                self.configuration = configuration
                super.init(viewMode: .sourceAccurate)
            }

        override func visitPost(_ node: EnumCaseElementSyntax) {
            let identifier = node.identifier
            let name = identifier.text

            validateIdentifierNode(identifier, withName: name, andIdentifierType: .enumElement)
        }

        override func visitPost(_ node: FunctionDeclSyntax) {
            let identifier = node.identifier
            let name = identifier.text

            switch node.identifier.tokenKind {
            case .binaryOperator, .prefixOperator, .postfixOperator:
                return
            default: break
            }

            validateIdentifierNode(identifier, withName: name, andIdentifierType: .function)
        }

        override func visitPost(_ node: IdentifierPatternSyntax) {
            let identifier = node.identifier
            let name = identifier.text

            validateIdentifierNode(identifier, withName: name, andIdentifierType: .variable)
        }

        private func validateIdentifierNode(
            _ identifier: TokenSyntax,
            withName name: String,
            andIdentifierType identifierType: IdentifierType) {
                // confirm this node isn't in the exclusion list
                // and that it has at least one character
                guard
                    let firstCharacter = name.first.map(String.init),
                    configuration.shouldExclude(name: name) == false
                else { return }

                // confirm this isn't an override
                let previousNodes = lastThreeNodes(identifier: identifier)
                guard nodeIsOverridden(previousNodes: previousNodes) == false else { return }
                guard
                    let previousNode = previousNodes.first
                else { queuedFatalError("No declaration node") }

                // alphanumeric characters
                let validationName = nodeIsPrivate(previousNodes: previousNodes) ? privateName(name) : name
                guard
                    validate(name: validationName, isValidWithin: configuration.allowedSymbolsAndAlphanumerics)
                else {
                    let reason = "\(identifierType.rawValue.localizedCapitalized) name '\(name)' should only contain alphanumeric and other allowed characters"
                    let violation = ReasonedRuleViolation(
                        position: previousNode.positionAfterSkippingLeadingTrivia,
                        reason: reason,
                        severity: configuration.unallowedSymbolsSeverity.severity)
                    violations.append(violation)
                    return
                }

                // identifier length
                if let severity = configuration.severity(forLength: name.count) {
                    let reason = """
                    \(identifierType.rawValue.localizedCapitalized) name '\(name)' should be between \
                    \(configuration.minLengthThreshold) and \
                    \(configuration.maxLengthThreshold) characters long
                    """
                    let violation = ReasonedRuleViolation(
                        position: previousNode.positionAfterSkippingLeadingTrivia,
                        reason: reason,
                        severity: severity)
                    violations.append(violation)
                    return
                }

                // at this point, the characters are all valid, it's just a matter of checking
                // specifics regarding conditions on character positioning

                // allowed starter symbols
                guard
                    configuration.allowedSymbols.contains(firstCharacter) == false
                else { return }

                // nix CamelCase values.
                if
                    identifier.text.first?.isUppercase == true,
                    nameIsViolatingCase(name) {

                    let locationOffset: Int
                    switch identifierType {
                    case .enumElement:
                        locationOffset = sourceLocationConverter
                            .location(for: identifier.positionAfterSkippingLeadingTrivia)
                            .offset
                    default:
                        locationOffset = sourceLocationConverter
                            .location(for: previousNode.positionAfterSkippingLeadingTrivia)
                            .offset
                    }
                    let reasoned = ReasonedRuleViolation(
                        position: AbsolutePosition(utf8Offset: locationOffset),
                        reason: "\(identifierType.rawValue.localizedCapitalized) shouldn't suck so much",
                        severity: .warning)

                    // make an exeption for CamelCase static var/let
                    if nodeIsStaticVariable(previousNodes) == false {
                        violations.append(reasoned)
                    }
                }
            }

		private func lastThreeNodes(identifier node: TokenSyntax) -> [TokenSyntax] {
			var out: [TokenSyntax] = []

			var current: TokenSyntax? = node
			while
				let previous = current?.previousToken(viewMode: .sourceAccurate),
				out.count < 3 {

				defer { current = current?.previousToken(viewMode: .sourceAccurate) }
				out.append(previous)
			}

			return out
		}

		private func nodeIsPrivate(previousNodes: [TokenSyntax]) -> Bool {
			previousNodes.contains(where: { $0.tokenKind == .keyword(.private)} )
		}

        private func privateName(_ name: String) -> String {
            guard name.first == "_" else { return name }
            return String(name[name.index(after: name.startIndex)...])
        }

        private func nodeIsStaticVariable(_ previousNodes: [TokenSyntax]) -> Bool {
            nodeIsStatic(previousNodes: previousNodes) && nodeIsVariable(previousNodes: previousNodes)
        }

        private func nodeIsVariable(previousNodes: [TokenSyntax]) -> Bool {
            previousNodes.contains(where: { $0.tokenKind == .keyword(.let)} ) ||
            previousNodes.contains(where: { $0.tokenKind == .keyword(.var)} )
        }

		private func nodeIsStatic(previousNodes: [TokenSyntax]) -> Bool {
			previousNodes.contains(where: { $0.tokenKind == .keyword(.static)} )
		}

		private func nodeIsOverridden(previousNodes: [TokenSyntax]) -> Bool {
			previousNodes.contains(where: { $0.tokenKind == .keyword(.override) } )
		}

		private func closureLineCount(_ node: ClosureExprSyntax) -> Int {
			let startLine = node.startLocation(converter: sourceLocationConverter).line
			let endLine = node.endLocation(converter: sourceLocationConverter).line
			return endLine - startLine
		}

		private func nameIsViolatingCase(_ name: String) -> Bool {
			guard
				let firstCharacter = name.first
			else {
				return true // Empty Identifier - should be impossible
			}
			if firstCharacter.isLowercase {
				return false
			}

			guard
				let secondIndex = name.index(
                    name.startIndex,
                    offsetBy: 1,
                    limitedBy: name.endIndex)
			else { return true }
			let secondCharacter = name[secondIndex]
			return secondCharacter.isLowercase
		}

		private func validate(name: String, isValidWithin characterSet: CharacterSet) -> Bool {
			characterSet.isSuperset(of: CharacterSet(charactersIn: name))
		}
	}
}

extension IdentifierNameRule {
    enum IdentifierType: String {
        case variable
        case function
        case enumElement = "enum element"
    }
}

private extension String {
    var isViolatingCase: Bool {
        let firstCharacter = String(self[startIndex])
        guard firstCharacter.isUppercase() else {
            return false
        }
        guard count > 1 else {
            return true
        }
        let secondCharacter = String(self[index(after: startIndex)])
        return secondCharacter.isLowercase()
    }

    var isOperator: Bool {
        let operators = ["/", "=", "-", "+", "!", "*", "|", "^", "~", "?", ".", "%", "<", ">", "&"]
        return operators.contains(where: hasPrefix)
    }

    func nameStrippingLeadingUnderscoreIfPrivate(_ dict: SourceKittenDictionary) -> String {
        if let acl = dict.accessibility,
            acl.isPrivate && first == "_" {
            return String(self[index(after: startIndex)...])
        }
        return self
    }
}
