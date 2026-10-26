//
//  OnboardingView.swift
//  Pawtrackr
//
//  Redesigned multi-step onboarding journey.
//

import SwiftUI
import SwiftData

#if os(iOS)
typealias PlatformContentType = UITextContentType
#elseif os(macOS)
typealias PlatformContentType = NSTextContentType
#endif

struct OnboardingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompactPhone: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }
    @Environment(AppSettings.self) private var appSettings
    @Namespace private var animation
    @State private var viewModel: OnboardingViewModel
    @State private var showConfetti = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the Welcome entrance. The only looping motion (the hero float)
    /// runs through `MotionAwareView`, so it pauses off-screen, under Reduce
    /// Motion, Low Power Mode and thermal pressure.
    @State private var welcomeAppeared = false
    /// Clients left on this device by an earlier store (e.g. the 1.0.2
    /// recovery-screen reset). Offered here because the onboarding cover hides
    /// the banner and Settings, and finishing setup would seed sample data first.
    @State private var restoreOffer: StoreBackupRestore.Offer?
    @State private var showStoreRestore = false
    
    // Explicitly define PlatformImage based on platform to ensure availability
    #if canImport(UIKit)
    private typealias PlatformImage = UIImage
    #elseif canImport(AppKit)
    private typealias PlatformImage = NSImage
    #endif
    
    private enum FocusField {
        case pin, confirmPin
    }
    @FocusState private var focusedField: FocusField?

    /// Onboarding reads best as a centered, readable-width column on wide screens
    /// (iPad / Mac) instead of stretching its cards and text edge-to-edge. On
    /// iPhone the screen is already narrower than this, so the cap is a no-op.
    private let readableContentWidth: CGFloat = 600

    var onComplete: () -> Void
    
    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        self._viewModel = State(initialValue: OnboardingViewModel(modelContext: nil, appSettings: nil))
    }
    
    var body: some View {
        @Bindable var viewModel = viewModel
        ZStack {
            DS.ColorToken.background.ignoresSafeArea()

            if viewModel.currentStep == .welcome {
                WelcomeBackdrop()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            if showConfetti {
                confettiView
                    .zIndex(10)
            }

            VStack(spacing: 0) {
                // Header / Progress
                onboardingHeader
                
                // Content
                ZStack {
                    switch viewModel.currentStep {
                    case .welcome: welcomeStep
                    case .businessProfile: businessProfileStep
                    case .regional: regionalStep
                    case .security: securityStep
                    case .permissions: permissionsStep
                    case .loyalty: loyaltyStep
                    case .warmStart: warmStartStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                
                // Footer / Navigation
                onboardingFooter
            }
            // Cap the whole column to a readable width and center it so the cards
            // don't stretch awkwardly on iPad / Mac. The background layer below
            // still fills the window, so the sides stay seamless.
            .frame(maxWidth: readableContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            viewModel.bindIfNeeded(modelContext: modelContext, appSettings: appSettings)
        }
        .animated(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.currentStep)
        .sheet(isPresented: $showStoreRestore) {
            StoreRestoreView(currentClientCount: 0)
        }
        .alert(AppLocalization.localized("onboarding.error.setup_title", value: "Setup Error"), isPresented: Binding(
            get: { viewModel.saveError != nil },
            set: { if !$0 { viewModel.saveError = nil } }
        )) {
            Button(AppLocalization.localized("common.ok")) { viewModel.saveError = nil }
        } message: {
            if let error = viewModel.saveError {
                Text(error)
            }
        }
    }
    
    @ViewBuilder
    private func logoImageView(image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #elseif os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }

    private var confettiView: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(0..<50, id: \.self) { i in
                    ConfettiPiece()
                        .offset(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var onboardingHeader: some View {
        VStack(spacing: DS.Spacing.md) {
            VStack(spacing: DS.Spacing.xs) {
                Text(viewModel.currentStep.title)
                    .font(DS.TypeScale.title)
                    .foregroundStyle(.primary)
                    .id(viewModel.currentStep)
                    .accessibilityIdentifier("onboarding.stepTitle")
                    .transition(.push(from: .top))

                Text(subtitle(for: viewModel.currentStep))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxl)
            }
            
            HStack(spacing: 8) {
                ForEach(OnboardingViewModel.Step.allCases, id: \.self) { step in
                    VStack(spacing: 4) {
                        Capsule()
                            .fill(step.rawValue <= viewModel.currentStep.rawValue ? DS.ColorToken.primary : DS.ColorToken.border)
                            .frame(height: 6)
                        
                        if step == viewModel.currentStep {
                            Circle()
                                .fill(DS.ColorToken.primary)
                                .frame(width: 4, height: 4)
                                .matchedGeometryEffect(id: "activeStepDot", in: animation)
                        } else {
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.goToStep(step)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.xxl)
        }
        .padding(.vertical, DS.Spacing.xl)
    }

    private func subtitle(for step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return AppLocalization.localized("onboarding.subtitle.welcome", value: "Let's configure your workspace.")
        case .businessProfile: return AppLocalization.localized("onboarding.subtitle.business_profile", value: "Tell us about your grooming business.")
        case .regional: return AppLocalization.localized("onboarding.subtitle.regional", value: "Set your local currency and contact details.")
        case .security: return AppLocalization.localized("onboarding.subtitle.security", value: "Secure your business data with a PIN.")
        case .permissions: return AppLocalization.localized("onboarding.subtitle.permissions", value: "Set your app preferences and unlock method.")
        case .loyalty: return AppLocalization.localized("onboarding.subtitle.loyalty", value: "Points build automatically after each completed, paid visit.")
        case .warmStart: return AppLocalization.localized("onboarding.subtitle.finish", value: "You are all set to start grooming!")
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: DS.Spacing.xxl) {
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 60))
                    .foregroundStyle(DS.ColorToken.primary)
                    .symbolEffect(.bounce, value: viewModel.currentStep)
                
                Text(AppLocalization.localized("onboarding.permissions.title", value: "Choose Your Defaults"))
                    .font(.title2.bold())
                
                Text(AppLocalization.localized("onboarding.permissions.message", value: "These preferences can be changed later in Settings, but getting them right now makes the first session smoother."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xl)
            }
            
            VStack(spacing: DS.Spacing.lg) {
                permissionToggle(
                    title: AppLocalization.localized("onboarding.permissions.lock_background.title", value: "Lock When App Closes"),
                    subtitle: AppLocalization.localized("onboarding.permissions.lock_background.subtitle", value: "Require your PIN again whenever Pawtrackr leaves the foreground."),
                    icon: "lock.fill",
                    isOn: $viewModel.lockOnBackgroundEnabled
                )

                permissionToggle(
                    title: AppLocalization.localized("onboarding.permissions.auto_lock.title", value: "Lock After Inactivity"),
                    subtitle: AppLocalization.localized("onboarding.permissions.auto_lock.subtitle", value: "Automatically relock the app after a few idle minutes."),
                    icon: "timer",
                    isOn: $viewModel.autoLockAfterInactivityEnabled
                )
                
                if viewModel.isBiometricsAvailable {
                    permissionToggle(
                        title: viewModel.biometricTitle,
                        subtitle: viewModel.biometricSubtitle,
                        icon: "faceid",
                        isOn: $viewModel.biometricsEnabled
                    )
                } else {
                    biometricUnavailableCard
                }
            }
            .padding(.horizontal, DS.Spacing.xxl)
        }
        .padding(.top, DS.Spacing.xl)
    }

    private func permissionToggle(
        title: String,
        subtitle: String,
        icon: String,
        isOn: Binding<Bool>,
        isDisabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(DS.ColorToken.primary)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        // Interactive card: when ON it lifts to an accent tint + border and
        // settles into a slightly smaller, "pressed-in" footprint for feedback.
        .background(isOn.wrappedValue ? DS.ColorToken.primary.opacity(0.10) : DS.ColorToken.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .hairlineBorder(isOn.wrappedValue ? DS.ColorToken.primary.opacity(0.55) : DS.ColorToken.border, cornerRadius: 12)
        .scaleEffect(isOn.wrappedValue ? 0.99 : 1.0)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isOn.wrappedValue)
    }

    /// Shown in place of the biometric toggle when Face ID / Touch ID isn't
    /// available — a styled, non-interactive disclosure rather than a dead row.
    private var biometricUnavailableCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "faceid")
                .font(.title2)
                .foregroundStyle(DS.ColorToken.warning)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.biometricTitle).font(.headline)
                Text(AppLocalization.localized("onboarding.permissions.biometric_unavailable", value: "Turn on Face ID or Touch ID in your device Settings to speed up checkout unlocks. Your PIN keeps working in the meantime."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .hairlineBorder(DS.ColorToken.warning.opacity(0.4), cornerRadius: 12)
        .accessibilityElement(children: .combine)
    }

    private var businessCardPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let logoData = viewModel.logoData, let uiImage = PlatformImage(data: logoData) {
                    logoImageView(image: uiImage)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .matchedGeometryEffect(id: "businessLogo", in: animation)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DS.ColorToken.primary.opacity(0.1))
                            .frame(width: 60, height: 60)
                        Image(systemName: "pawprint.fill")
                            .foregroundStyle(DS.ColorToken.primary)
                    }
                    .matchedGeometryEffect(id: "businessLogo", in: animation)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.name.trimmed.isEmpty ? AppLocalization.localized("onboarding.business.preview_name", value: "Your Business Name") : viewModel.name)
                        .font(.headline)
                        .foregroundStyle(viewModel.name.isEmpty ? .secondary : .primary)
                    
                    if !viewModel.email.isEmpty {
                        Text(viewModel.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if !viewModel.phone.isEmpty {
                        Text(viewModel.phone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            if !viewModel.address.isEmpty {
                Divider()
                Text(viewModel.address)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(DS.ColorToken.surface)
                .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
        )
        .padding(.horizontal)
        .padding(.bottom, DS.Spacing.lg)
    }
    
    private var welcomeStep: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                welcomeHero
                    .padding(.top, DS.Spacing.md)

                VStack(spacing: DS.Spacing.sm) {
                    if !appVersion.isEmpty {
                        Text(String(format: AppLocalization.localized("onboarding.welcome.version_fmt", value: "Version %@"), appVersion))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DS.ColorToken.primary)
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xxs)
                            .glassSurface(cornerRadius: DS.Radius.pill, tint: DS.ColorToken.primary.opacity(0.12))
                    }
                    Text(AppLocalization.localized("onboarding.welcome.title", value: "Welcome to Pawtrackr"))
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AppLocalization.localized("onboarding.welcome.message", value: "Clients, pets, visits and checkout in one calm workspace.\nSet up your salon in a few minutes."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Spacing.xxl)
                .welcomeEntrance(welcomeAppeared, delay: 0.05, reduceMotion: reduceMotion)

                // Above the feature list so it's visible without scrolling: for
                // someone whose clients vanished, this is the whole point.
                if let restoreOffer {
                    restoreFoundCard(restoreOffer)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: DS.Spacing.md)], spacing: DS.Spacing.md) {
                    ForEach(Array(WelcomeFeature.all.enumerated()), id: \.element.id) { index, feature in
                        welcomeFeatureCard(feature)
                            .welcomeEntrance(welcomeAppeared, delay: 0.16 + Double(index) * 0.06, reduceMotion: reduceMotion)
                    }
                }
                .padding(.horizontal, DS.Spacing.xxl)

                Label(
                    AppLocalization.localized("onboarding.welcome.trust", value: "No account needed · Works offline"),
                    systemImage: "checkmark.seal.fill"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .welcomeEntrance(welcomeAppeared, delay: 0.5, reduceMotion: reduceMotion)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, DS.Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .task {
            guard restoreOffer == nil else { return }
            restoreOffer = await Task.detached(priority: .userInitiated) {
                // Onboarding means there's no set-up store yet, so any backup's
                // clients are all missing. Dismissals don't apply: the banner
                // that records them was never reachable from here.
                StoreBackupRestore.offer(from: StoreBackupRestore.candidates(), liveClientUUIDs: [], dismissed: [])
            }.value
            // Sample clients are never added while this device holds a backup
            // of the user's own clients.
            viewModel.restorableClientCount = restoreOffer?.missingClientCount ?? 0
        }
        .onAppear {
            welcomeAppeared = true
        }
    }

    /// The app mark with four service badges. It floats gently only while
    /// on screen and when `MotionGovernor` allows decorative motion.
    private var welcomeHero: some View {
        MotionAwareView { animates in
            ZStack {
                ForEach(Array(WelcomeHeroBadge.all.enumerated()), id: \.element.symbol) { index, badge in
                    Image(systemName: badge.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(badge.tint)
                        .frame(width: 44, height: 44)
                        .glassSurface(cornerRadius: 22, tint: badge.tint.opacity(0.10))
                        .offset(badge.offset)
                        .scaleEffect(welcomeAppeared || reduceMotion ? 1 : 0.4)
                        .opacity(welcomeAppeared ? 1 : 0)
                        .animation(
                            reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.7).delay(0.25 + Double(index) * 0.08),
                            value: welcomeAppeared
                        )
                }

                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(LinearGradient(
                        colors: [DS.ColorToken.primary, DS.ColorToken.primary.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                    )
                    .frame(width: 112, height: 112)
                    .shadow(color: DS.ColorToken.primary.opacity(0.35), radius: 18, y: 10)

                Image(systemName: "pawprint.fill")
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: welcomeAppeared)
                    .matchedGeometryEffect(id: "businessLogo", in: animation)
            }
            .frame(width: 260, height: 190)
            .keyframeAnimator(initialValue: 0.0, repeating: animates) { content, lift in
                content.offset(y: lift)
            } keyframes: { _ in
                CubicKeyframe(-6, duration: 2.2)
                CubicKeyframe(0, duration: 2.2)
            }
        }
        .accessibilityHidden(true)
    }

    private func welcomeFeatureCard(_ feature: WelcomeFeature) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Image(systemName: feature.icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(feature.tint)
                .frame(width: 44, height: 44)
                .background(feature.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(feature.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface()
        .accessibilityElement(children: .combine)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
    
    private func restoreFoundCard(_ offer: StoreBackupRestore.Offer) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(
                AppLocalization.localized("onboarding.restore.title", value: "Your clients are still on this device"),
                systemImage: "clock.arrow.circlepath"
            )
            .font(.headline)
            Text(String(
                format: AppLocalization.localized("onboarding.restore.message_fmt", value: "A backup here has %d clients. Restore them instead of starting over."),
                offer.missingClientCount
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                showStoreRestore = true
            } label: {
                Text(AppLocalization.localized("onboarding.restore.action", value: "Restore Clients"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("onboarding.restoreClients")
        }
        .padding(DS.Spacing.lg)
        .background(DS.ColorToken.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, DS.Spacing.xl)
    }

    private var businessProfileStep: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                businessCardPreview
                
                VStack(spacing: DS.Spacing.md) {
                    ImagePicker(imageData: $viewModel.logoData) {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text(viewModel.logoData == nil ? AppLocalization.localized("onboarding.business.upload_logo", value: "Upload Business Logo") : AppLocalization.localized("onboarding.business.change_logo", value: "Change Logo"))
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(AppLocalization.localized("onboarding.business.name", value: "Business Name")).font(.headline)
                    TextField(AppLocalization.localized("onboarding.business.name_placeholder", value: "e.g. Bark & Bathe Grooming"), text: $viewModel.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .accessibilityIdentifier("onboarding.businessName")
                        .textLengthLimit($viewModel.name, to: TextInputLimits.name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                }
                .padding(.horizontal, DS.Spacing.xxl)
                
                Text(AppLocalization.localized("onboarding.business.info_message", value: "This information will be used to brand your receipts and reports."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxl)
            }
            .padding(.top, DS.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var regionalStep: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                businessCardPreview
                
                Text(AppLocalization.localized("onboarding.regional.contact_message", value: "Contact details are optional. Add them now if you want them on receipts and exports."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxl)
                
                Card {
                    VStack(spacing: DS.Spacing.md) {
                        onboardingTextField(
                            title: AppLocalization.localized("onboarding.regional.email", value: "Contact Email"),
                            text: $viewModel.email,
                            icon: "envelope",
                            contentType: .emailAddress,
                            maxLength: TextInputLimits.email
                        )
                        onboardingTextField(
                            title: AppLocalization.localized("onboarding.regional.phone", value: "Phone Number"),
                            text: $viewModel.phone,
                            icon: "phone",
                            contentType: .telephoneNumber,
                            maxLength: TextInputLimits.phone
                        )
                            .phoneFieldFormatting($viewModel.phone)
                        onboardingTextField(
                            title: AppLocalization.localized("onboarding.regional.address", value: "Business Address"),
                            text: $viewModel.address,
                            icon: "mappin.and.ellipse",
                            axis: .vertical,
                            contentType: .fullStreetAddress,
                            maxLength: TextInputLimits.address
                        )
                    }
                }
                .padding(.horizontal, DS.Spacing.xxl)
            }
            .padding(.top, DS.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func onboardingTextField(
        title: String,
        text: Binding<String>,
        icon: String,
        axis: Axis = .horizontal,
        contentType: PlatformContentType? = nil,
        maxLength: Int = TextInputLimits.name
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            
            if axis == .vertical {
                TextField(title, text: text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
                    .textContentType(contentType)
                    .textLengthLimit(text, to: maxLength)
            } else {
                if contentType == .emailAddress {
                    TextField(title, text: text)
                        .textFieldStyle(.roundedBorder)
                        .textLengthLimit(text, to: maxLength)
                        .emailFieldInput()
                } else {
                    TextField(title, text: text)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(contentType)
                        .textLengthLimit(text, to: maxLength)
                        #if os(iOS)
                        .keyboardType(keyboardType(for: contentType))
                        #endif
                }
            }
        }
    }
    
    #if os(iOS)
    private func keyboardType(for contentType: PlatformContentType?) -> UIKeyboardType {
        switch contentType {
        case .telephoneNumber: return .phonePad
        default: return .default
        }
    }
    #endif

    
    private var onboardingFooter: some View {
        VStack(spacing: DS.Spacing.sm) {
            if let validationMessage = viewModel.currentValidationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(DS.ColorToken.danger)
            }

            HStack {
                if viewModel.currentStep != .welcome {
                    Button(AppLocalization.localized("common.back", value: "Back")) {
                        viewModel.previousStep()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier("onboarding.back")
                }
                
                if !isCompactPhone || viewModel.currentStep != .welcome {
                    Spacer()
                }

                if viewModel.currentStep != .warmStart {
                    Button {
                        viewModel.nextStep()
                    } label: {
                        HStack {
                            Text(viewModel.primaryActionTitle)
                            Image(systemName: "arrow.right")
                        }
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.md)
                        .frame(maxWidth: isCompactPhone && viewModel.currentStep == .welcome ? .infinity : nil)
                        .frame(minHeight: isCompactPhone ? 44 : 0)
                        .background(viewModel.canGoNext ? DS.ColorToken.primary : DS.ColorToken.primary.opacity(0.5))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                        .shadow(color: viewModel.canGoNext ? DS.ColorToken.primary.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
                    }
                    .disabled(!viewModel.canGoNext || viewModel.isSaving)
                    .pressScaleStyle()
                    .scaleEffect(viewModel.canGoNext ? 1.0 : 0.98)
                    .animation(.spring(), value: viewModel.canGoNext)
                    .accessibilityIdentifier("onboarding.continue")
                }
            }
        }
        .padding(DS.Spacing.xxl)
    }
    
    private var securityStep: some View {
        VStack(spacing: DS.Spacing.xxl) {
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(DS.ColorToken.primary)
                
                Text(AppLocalization.localized("onboarding.security.title", value: "Set Your App PIN"))
                    .font(.title2.bold())
                
                Text(AppLocalization.localized("onboarding.security.message", value: "This 4-digit code will protect your client data."))
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: DS.Spacing.xl) {
                pinEntryView(title: AppLocalization.localized("onboarding.security.enter_pin", value: "Enter PIN"), text: $viewModel.pin, field: .pin)
                pinEntryView(title: AppLocalization.localized("onboarding.security.confirm_pin", value: "Confirm PIN"), text: $viewModel.confirmPin, field: .confirmPin)
                // Validation messages render in the shared footer to avoid duplicates.
            }

            // Optional path: let solo groomers run the app passcode-free.
            Button {
                focusedField = nil
                viewModel.skipPIN()
            } label: {
                Text(AppLocalization.localized("onboarding.security.skip", value: "Skip for now — use without a PIN"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.ColorToken.primary)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving)
            .accessibilityIdentifier("onboarding.skipPin")
        }
        .padding(.top, DS.Spacing.xl)
        .onAppear {
            // Focus the first empty PIN field on entry — but if the user is coming
            // back from a later step with both PINs already filled, leave focus alone.
            if viewModel.pin.filter(\.isNumber).count < 4 {
                focusedField = .pin
            } else if viewModel.confirmPin.filter(\.isNumber).count < 4 {
                focusedField = .confirmPin
            }
        }
    }

    private var loyaltyStep: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.xl) {
                Image(systemName: "giftcard.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DS.ColorToken.primary)
                    .symbolEffect(.pulse, value: viewModel.currentStep)

                VStack(spacing: DS.Spacing.sm) {
                    Text(AppLocalization.localized("onboarding.loyalty.title", value: "Rewards without extra math"))
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(AppLocalization.localized("onboarding.loyalty.message", value: "Care for the pet. Complete the visit. Pawtrackr takes care of the points."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, DS.Spacing.xxl)

                LoyaltyJourneyCard()
                    .padding(.horizontal, DS.Spacing.xxl)
            }
            .padding(.top, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func pinEntryView(title: String, text: Binding<String>, field: FocusField) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            
            ZStack {
                // Hidden TextField that captures input
                TextField("", text: text)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textContentType(.oneTimeCode)
                    .focused($focusedField, equals: field)
                    .opacity(0.01)
                    .accessibilityIdentifier(field == .pin ? "onboarding.pinField" : "onboarding.confirmPinField")
                    .onChange(of: text.wrappedValue) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(4))
                        if filtered != newValue {
                            text.wrappedValue = filtered
                            return
                        }
                        // Auto-advance focus if filling first PIN
                        if field == .pin && text.wrappedValue.count == 4 {
                            focusedField = .confirmPin
                        }
                    }

                // Visible PIN boxes
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.ColorToken.surface)
                            .frame(width: 50, height: 60)
                            .overlay(
                                Text(index < text.wrappedValue.count ? "•" : "")
                                    .font(.title.bold())
                            )
                            .hairlineBorder(
                                (focusedField == field && index == text.wrappedValue.count) ? DS.ColorToken.primary : DS.ColorToken.border,
                                cornerRadius: 8
                            )
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = field
            }
        }
    }
    
    private var warmStartStep: some View {
        ScrollView {
        VStack(spacing: DS.Spacing.xxl) {
            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(DS.ColorToken.primary)
                    .symbolEffect(.bounce, value: viewModel.currentStep)

                Text(AppLocalization.localized("onboarding.finish.title", value: "You're all set!"))
                    .font(.title2.bold())

                Text(AppLocalization.localized("onboarding.finish.message", value: "Choose how you'd like to start."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xl)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(AppLocalization.localized("onboarding.summary.title", value: "Workspace Summary"))
                    .font(.headline)
                Label(viewModel.name.trimmed.isEmpty ? AppLocalization.localized("onboarding.summary.business_pending", value: "Business name will be added in setup") : viewModel.name.trimmed, systemImage: "building.2")
                Label(String(format: AppLocalization.localized("onboarding.summary.currency_fmt", value: "Currency: %@"), viewModel.currencySymbol), systemImage: "dollarsign.circle")
                if viewModel.pinSkipped {
                    Label(AppLocalization.localized("onboarding.summary.pin_disabled", value: "No PIN — open access"), systemImage: "lock.open")
                } else {
                    Label(AppLocalization.localized("onboarding.summary.pin_enabled", value: "PIN protection enabled"), systemImage: "lock.shield")
                }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(DS.ColorToken.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hairlineBorder(DS.ColorToken.border, cornerRadius: 14)
            .padding(.horizontal, DS.Spacing.xxl)

            // Sample clients go into the local store, so they're
            // a choice the user makes, never a default. The rules for when
            // they may be added live in SampleDataSeedPolicy.
            VStack(spacing: DS.Spacing.md) {
                startChoiceButton(
                    title: AppLocalization.localized("onboarding.finish.sample.title", value: "Explore with sample clients"),
                    subtitle: AppLocalization.localized("onboarding.finish.sample.subtitle", value: "Adds 2 practice clients with pets and visits, and example prices for services that have none, so the tour can show check-in and checkout. Remove them anytime in Settings."),
                    systemImage: "wand.and.stars",
                    isProminent: viewModel.sampleDataAvailability == .seed,
                    identifier: "onboarding.explore"
                ) {
                    completeWithCelebration(seed: true)
                }
                .disabled(viewModel.isSaving || viewModel.sampleDataAvailability != .seed)
                .opacity(viewModel.sampleDataAvailability == .seed ? 1 : 0.55)

                if let note = sampleDataUnavailableNote {
                    Label(note, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.sampleUnavailable")
                }

                startChoiceButton(
                    title: AppLocalization.localized("onboarding.finish.real.title", value: "Start with my real business"),
                    subtitle: AppLocalization.localized("onboarding.finish.real.subtitle", value: "Begin with an empty client list. You can load sample clients later in Settings."),
                    systemImage: "building.2",
                    isProminent: viewModel.sampleDataAvailability != .seed,
                    identifier: "onboarding.startReal"
                ) {
                    completeWithCelebration(seed: false)
                }
                .disabled(viewModel.isSaving)
            }
            .padding(.horizontal, DS.Spacing.xxl)

            if viewModel.isSaving {
                ProgressView(AppLocalization.localized("onboarding.saving", value: "Setting up your workspace..."))
                    #if os(iOS)
                    .controlSize(.large)
                    #endif
            }
        }
        .padding(.vertical, DS.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    
    /// Why the sample option is off, in words the groomer can act on.
    private var sampleDataUnavailableNote: String? {
        switch viewModel.sampleDataAvailability {
        case .seed, .skip(.notChosen):
            return nil
        case .skip(.salonHasData):
            return AppLocalization.localized("onboarding.finish.sample.unavailable_salon", value: "Your salon already has data, so sample clients won't be added.")
        case .skip(.backupFound):
            return AppLocalization.localized("onboarding.finish.sample.unavailable_backup", value: "This device has a backup of your clients. Restore it instead of adding sample clients.")
        }
    }

    private func startChoiceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isProminent: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.footnote)
                        .opacity(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .multilineTextAlignment(.leading)
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isProminent ? DS.ColorToken.primary : DS.ColorToken.surface)
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .hairlineBorder(isProminent ? Color.clear : DS.ColorToken.border, cornerRadius: DS.Radius.md)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func completeWithCelebration(seed: Bool) {
        Task {
            withAnimation(.spring()) {
                showConfetti = true
            }

            // Run the confetti pop and the persistence work concurrently so demo
            // seeding can begin immediately rather than waiting 1.5s of dead time.
            async let pop: Void = Task.sleep(for: .seconds(1.5))
            await viewModel.finish(seedSampleData: seed, onComplete: onComplete)
            try? await pop

            // Tear the confetti down whether we succeeded or failed so it does not
            // hang in the view tree while the alert / parent re-renders.
            withAnimation(.easeOut(duration: 0.2)) {
                showConfetti = false
            }
        }
    }
}

private struct ConfettiPiece: View {
    @State private var x: CGFloat = 0
    @State private var y: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var color: Color = [.blue, .purple, .pink, .orange, .yellow, .green].randomElement()!
    @State private var opacity: Double = 1.0
    
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
            .opacity(opacity)
            .onAppear {
                let angle = Double.random(in: 0...(2 * .pi))
                let distance = CGFloat.random(in: 100...400)
                
                withAnimation(.easeOut(duration: 1.5)) {
                    x = cos(angle) * distance
                    y = sin(angle) * distance
                    rotation = Double.random(in: 0...720)
                    opacity = 0
                }
            }
    }
}

// MARK: - Welcome building blocks

/// One thing Pawtrackr does today, shown on the Welcome screen.
private struct WelcomeFeature: Identifiable {
    let id: String
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    /// Only features that ship in the current version belong here.
    static var all: [WelcomeFeature] {
        [
            WelcomeFeature(
                id: "pets", icon: "pawprint.fill", tint: DS.ColorToken.primary,
                title: AppLocalization.localized("onboarding.feature.pets.title", value: "Every Pet, One Profile"),
                detail: AppLocalization.localized("onboarding.feature.pets.subtitle", value: "Photos, behavior notes, safety alerts and visit history for each pet.")
            ),
            WelcomeFeature(
                id: "checkout", icon: "creditcard.fill", tint: DS.ColorToken.success,
                title: AppLocalization.localized("onboarding.feature.checkout.title", value: "Checkout in Seconds"),
                detail: AppLocalization.localized("onboarding.feature.checkout.subtitle", value: "Enter what you charge and share a PDF receipt by AirDrop, Messages or Mail.")
            ),
            WelcomeFeature(
                id: "loyalty", icon: "gift.fill", tint: DS.ColorToken.warning,
                title: AppLocalization.localized("onboarding.feature.loyalty.title", value: "Loyalty That Runs Itself"),
                detail: AppLocalization.localized("onboarding.feature.loyalty.subtitle", value: "Points are added after every paid visit. Clients choose rewards at checkout.")
            ),
            WelcomeFeature(
                id: "celebrations", icon: "birthday.cake.fill", tint: DS.ColorToken.genderFemale,
                title: AppLocalization.localized("onboarding.feature.celebrations.title", value: "Birthdays & Anniversaries"),
                detail: AppLocalization.localized("onboarding.feature.celebrations.subtitle", value: "Pet birthdays and salon anniversaries are flagged so you can celebrate them.")
            ),
            WelcomeFeature(
                id: "insights", icon: "chart.bar.fill", tint: DS.ColorToken.info,
                title: AppLocalization.localized("onboarding.feature.insights.title", value: "Business Insights"),
                detail: AppLocalization.localized("onboarding.feature.insights.subtitle", value: "Revenue, trends and reports you can open in Excel and Numbers.")
            ),
            WelcomeFeature(
                id: "privacy", icon: "lock.shield.fill", tint: DS.ColorToken.primary,
                title: AppLocalization.localized("onboarding.feature.privacy.title", value: "Privacy First"),
                detail: AppLocalization.localized("onboarding.feature.privacy.subtitle_device", value: "Your clients are saved on your device. You can lock the app with a PIN and Face ID or Touch ID.")
            )
        ]
    }
}

/// A small service badge orbiting the Welcome app mark.
private struct WelcomeHeroBadge {
    let symbol: String
    let tint: Color
    let offset: CGSize

    static var all: [WelcomeHeroBadge] {
        [
            WelcomeHeroBadge(symbol: "scissors", tint: DS.ColorToken.primary, offset: CGSize(width: -96, height: -38)),
            WelcomeHeroBadge(symbol: "heart.fill", tint: DS.ColorToken.genderFemale, offset: CGSize(width: 98, height: -48)),
            WelcomeHeroBadge(symbol: "sparkles", tint: DS.ColorToken.warning, offset: CGSize(width: 90, height: 50)),
            WelcomeHeroBadge(symbol: "drop.fill", tint: DS.ColorToken.info, offset: CGSize(width: -86, height: 54))
        ]
    }
}

/// A static brand glow behind the Welcome screen. It never animates, so it
/// costs nothing per frame and stays put under Reduce Motion.
private struct WelcomeBackdrop: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [DS.ColorToken.primary.opacity(0.22), .clear],
                center: .top, startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [DS.ColorToken.info.opacity(0.10), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 380
            )
            RadialGradient(
                colors: [DS.ColorToken.genderFemale.opacity(0.08), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 340
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Fades and lifts a Welcome element into place once; Reduce Motion keeps the fade only.
    func welcomeEntrance(_ appeared: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82).delay(delay),
                value: appeared
            )
    }
}
