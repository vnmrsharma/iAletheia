import SwiftUI

// MARK: - Text Fields

struct ThemedTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)

            Group {
                if axis == .vertical {
                    TextField(prompt, text: $text, axis: .vertical)
                        .lineLimit(lineLimit ?? 3...6)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .foregroundStyle(AppTheme.textPrimary)
            .tint(AppTheme.blue)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fieldBackground)
            .focused($isFocused)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AppTheme.surfaceElevated)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isFocused ? AppTheme.borderFocus : AppTheme.border, lineWidth: isFocused ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isFocused ? 0.06 : 0.03), radius: isFocused ? 6 : 2, y: 1)
    }
}

struct ThemedSecureField: View {
    let title: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
            SecureField("Enter API key", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(AppTheme.textPrimary)
                .tint(AppTheme.blue)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(isFocused ? AppTheme.borderFocus : AppTheme.border, lineWidth: isFocused ? 1.5 : 1)
                        }
                )
                .focused($isFocused)
        }
    }
}

// MARK: - Cards & Sections

struct ThemedSectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(AppTheme.surfaceElevated)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct ThemedInfoBanner: View {
    let text: String
    var style: BannerStyle = .info

    enum BannerStyle { case info, success, warning }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(text)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch style {
        case .info: return AppTheme.blue
        case .success: return AppTheme.green
        case .warning: return .orange
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .info: return AppTheme.blueLight
        case .success: return AppTheme.greenLight
        case .warning: return Color.orange.opacity(0.08)
        }
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(AppTheme.primaryButtonGradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: AppTheme.blue.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(AppTheme.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(AppTheme.blueLight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppTheme.blue.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let text: String
    var active: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? AppTheme.greenMid : AppTheme.textTertiary)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? AppTheme.green : AppTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(active ? AppTheme.greenLight : AppTheme.surfaceMuted)
        )
    }
}

struct ThemedChatInput: View {
    @Binding var text: String
    var placeholder: String = "Ask me anything…"
    var isLoading: Bool = false
    var onSend: () -> Void
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(AppTheme.textPrimary)
                .tint(AppTheme.blue)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.surfaceElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isFocused ? AppTheme.borderFocus : AppTheme.border, lineWidth: isFocused ? 1.5 : 1)
                        }
                )
                .focused($isFocused)
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, AppTheme.blue)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
        }
    }
}
