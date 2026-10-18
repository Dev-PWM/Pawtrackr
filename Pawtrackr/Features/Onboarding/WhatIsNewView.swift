import SwiftUI

struct WhatIsNewView: View {
    var onDismiss: () -> Void
    
    struct Feature: Identifiable {
        let id = UUID()
        let title: String
        let description: String
        let icon: String
        let color: Color
    }
    
    /// What changed in this version. It shows once per version, on the
    /// first launch after an update. List only what ships in this release.
    let features = [
        Feature(title: AppLocalization.localized("whats_new.celebrations.title", value: "Birthdays & Anniversaries"), description: AppLocalization.localized("whats_new.celebrations.description", value: "On a pet's birthday, its card celebrates with confetti. No birthdate on file? Pawtrackr celebrates each year the client has been with you."), icon: "birthday.cake.fill", color: DS.ColorToken.genderFemale),
        Feature(title: AppLocalization.localized("whats_new.rewards.title", value: "Simpler Rewards"), description: AppLocalization.localized("whats_new.rewards.description", value: "Rewards show the points balance, the next reward and the history. Membership tiers are gone, and points are used only when you confirm payment."), icon: "gift.fill", color: DS.ColorToken.warning),
        Feature(title: AppLocalization.localized("whats_new.search.title", value: "Smarter Client Search"), description: AppLocalization.localized("whats_new.search.description", value: "Search several words at once or any part of a phone number. Type pet:, breed: or email: to narrow the results."), icon: "magnifyingglass", color: DS.ColorToken.info),
        Feature(title: AppLocalization.localized("whats_new.checkout_amount.title", value: "Checkout You Control"), description: AppLocalization.localized("whats_new.checkout_amount.description", value: "Type the amount you charge. Choosing services never changes it, and an unfinished checkout is saved so you can pick up where you left off."), icon: "creditcard.fill", color: DS.ColorToken.success),
        Feature(title: AppLocalization.localized("whats_new.safety.title", value: "Clearer Safety Alerts"), description: AppLocalization.localized("whats_new.safety.description", value: "Pet cards glow by temperament, and an aggressive flag clears only after three recorded visits without aggression."), icon: "exclamationmark.shield.fill", color: DS.ColorToken.danger),
        Feature(title: AppLocalization.localized("whats_new.smoother.title", value: "Smoother Everywhere"), description: AppLocalization.localized("whats_new.smoother.description", value: "A new welcome screen, lighter animations that respect Reduce Motion and Low Power Mode, and an email keyboard with the @ key."), icon: "sparkles", color: DS.ColorToken.primary)
    ]

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Scrolls on small iPhones and at large text sizes, so Continue
            // stays on screen.
            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 10) {
                        if !appVersion.isEmpty {
                            Text(String(format: NSLocalizedString("onboarding.welcome.version_fmt", value: "Version %@", comment: ""), appVersion))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.ColorToken.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .glassSurface(cornerRadius: DS.Radius.pill, tint: DS.ColorToken.primary.opacity(0.12))
                        }
                        Text(AppLocalization.localized("whats_new.title", value: "What's New in Pawtrackr"))
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.top, 40)

                    VStack(alignment: .leading, spacing: 25) {
                        ForEach(features) { feature in
                            HStack(alignment: .top, spacing: 20) {
                                Image(systemName: feature.icon)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(feature.color)
                                    .frame(width: 48, height: 48)
                                    .background(feature.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(feature.title)
                                        .font(.headline)
                                    Text(feature.description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.horizontal, 30)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                onDismiss()
            } label: {
                Text(AppLocalization.localized("whats_new.continue", value: "Continue"))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(DS.ColorToken.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .pressScaleStyle()
            .accessibilityIdentifier("whatsNew.continue")
            .frame(maxWidth: 500)
            .padding(.horizontal, 30)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 680)
        #endif
    }
}
