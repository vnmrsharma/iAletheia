import AppKit
import SwiftUI

struct InlineCitationText: View {
    let text: String
    let citations: [ChatCitation]

    var body: some View {
        if citations.isEmpty {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        } else if let attributed = try? AttributedString(
            markdown: CitationBuilder.linkifiedMarkdown(text: text, citations: citations),
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.callout)
                .tint(AppTheme.blue)
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    NSWorkspace.shared.open(url)
                    return .handled
                })
        } else {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

struct CitationFooter: View {
    let citations: [ChatCitation]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(citations) { citation in
                HStack(alignment: .top, spacing: 6) {
                    Text("[\(citation.id)]")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppTheme.blue)
                    if let url = citation.url {
                        Link(citation.title, destination: url)
                            .font(.caption2)
                            .lineLimit(2)
                    } else {
                        Text(citation.title)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(citation.kind == .web ? "Web" : "Memory")
                        .font(.caption2)
                        .foregroundStyle(citation.kind == .web ? AppTheme.green : AppTheme.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(citation.kind == .web ? AppTheme.greenLight : AppTheme.blueLight)
                        )
                }
            }
        }
        .padding(.top, 4)
    }
}
