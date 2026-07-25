import SwiftUI

/// The staged pairing surface (ux-update §1, mocks 1b–1d): the same nebula void
/// full-screen — not a form, not a sheet with chrome. One capsule field under a
/// waiting node; state is expressed through light. Screens:
///
/// - 1b  address: dim node above the field, ghost `radiant.tailnet.ts.net`;
///        submit → the node pulses ~1/s while probing (no spinner exists).
/// - 1b2 unreachable: field border warms to ember, node dims, one line fades in
///        below — `the radiant is beyond reach`. Editing the field is the retry.
/// - 1b3 credentials (plain-sshd only): address locked, `user` + password,
///        whisper `used once, then discarded`.
/// - 1c2 provisioning: condensing node above three stage lines driven by the
///        provision script's ##stage markers; ##fail halts with the sentence
///        verbatim; tap resumes (idempotent).
/// - 1c  code fallback: six cells, cyan caret, `code shown by your server`.
/// - 1d  paired: node ignites, two rings expand (~700ms, success haptic), the
///        address glows gold beneath; <1s then the flight home.
struct PairingFlowView: View {
    @Bindable var controller: PairingController
    /// The persistent world scene renders the nebula void behind everything.
    let radiant: RadiantScene?
    /// Frozen debug state (`-PRDebugPairingState=`): never auto-advances.
    var frozen = false

    @FocusState private var focusedField: Field?

    enum Field { case address, username, password, code }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Tokens.Role.background.ignoresSafeArea()
                if let radiant {
                    // Interactive so the render delegate drives advance() (the
                    // nebula breathes); hit-testing off — the flow owns touch.
                    CanvasView(radiant: radiant, interactive: true)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                content(in: geometry.size)
            }
        }
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.3), value: controller.stage)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch controller.stage {
        case .address:
            addressScreen(in: size)
        case .credentials:
            credentialsScreen(in: size)
        case .provisioning:
            provisioningScreen(in: size)
        case .code:
            codeScreen(in: size)
        case .paired:
            pairedScreen(in: size)
        }
    }

    // MARK: - 1b / 1b2: address (+ inline unreachable state)

    private func addressScreen(in size: CGSize) -> some View {
        ZStack {
            PairingNodeView(
                style: controller.probing
                    ? .probing
                    : (controller.unreachable ? .dimmed : .waiting))
                .position(x: size.width / 2, y: size.height * 0.354)

            capsuleField(
                text: $controller.address,
                ghost: "radiant.tailnet.ts.net",
                ember: controller.unreachable,
                identifier: "pairing.address",
                width: fieldWidth(size))
                .focused($focusedField, equals: .address)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { controller.submitAddress() }
                .onChange(of: controller.address) { controller.addressEdited() }
                .position(x: size.width / 2, y: size.height * 0.5377)

            // 1b2: one line fades in below (~400ms); fades out as typing resumes.
            whisper("the radiant is beyond reach", color: Tokens.Palette.ember.opacity(0.9))
                .opacity(controller.unreachable ? 1 : 0)
                .animation(
                    Motion.isReduced
                        ? nil
                        : .easeInOut(duration: Tokens.Motion.unreachableFadeSeconds),
                    value: controller.unreachable)
                .accessibilityIdentifier("pairing.unreachable")
                .accessibilityHidden(!controller.unreachable)
                .position(x: size.width / 2, y: size.height * 0.5985)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !frozen { focusedField = .address }
        }
        .onAppear {
            if !frozen { focusedField = .address }
        }
    }

    // MARK: - 1b3: credentials (plain-sshd path only)

    private func credentialsScreen(in size: CGSize) -> some View {
        ZStack {
            PairingNodeView(style: controller.probing ? .probing : .waiting)
                .position(x: size.width / 2, y: size.height * 0.2986)

            // Address locked at the top — parchment, no editing.
            lockedCapsule(controller.address, width: fieldWidth(size))
                .position(x: size.width / 2, y: size.height * 0.4656)

            capsuleField(
                text: $controller.username,
                ghost: "user",
                ember: false,
                identifier: "pairing.user",
                width: fieldWidth(size))
                .focused($focusedField, equals: .username)
                .submitLabel(.next)
                .onSubmit { focusedField = .password }
                .position(x: size.width / 2, y: size.height * 0.5391)

            secureCapsuleField(width: fieldWidth(size))
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { controller.submitCredentials() }
                .position(x: size.width / 2, y: size.height * 0.6137)

            whisper(
                controller.credentialLine ?? "used once, then discarded",
                color: controller.credentialLine == nil
                    ? Tokens.Role.displayText.opacity(0.45)
                    : Tokens.Palette.ember.opacity(0.9))
                .accessibilityIdentifier("pairing.credentials.whisper")
                .position(x: size.width / 2, y: size.height * 0.6754)
        }
        .contentShape(Rectangle())
        .onAppear {
            if !frozen { focusedField = .username }
        }
    }

    // MARK: - 1c2: provisioning

    private func provisioningScreen(in size: CGSize) -> some View {
        ZStack {
            PairingNodeView(style: .condensing)
                .position(x: size.width / 2, y: size.height * 0.391)

            VStack(spacing: 13) {
                stageLine("reaching the box", state: controller.reach, id: "pairing.stage.reach")
                stageLine("planting the radiant", state: controller.plant, id: "pairing.stage.plant")
                stageLine("waking the engine", state: controller.wake, id: "pairing.stage.wake")
            }
            .position(x: size.width / 2, y: size.height * 0.5427)

            if let sentence = failSentence {
                whisper(sentence, color: Tokens.Palette.ember.opacity(0.9))
                    .accessibilityIdentifier("pairing.fail")
                    .frame(width: fieldWidth(size))
                    .position(x: size.width / 2, y: size.height * 0.645)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Retry resumes — the script is idempotent (1c2). No buttons.
            if !frozen { controller.retryProvisioning() }
        }
    }

    private var failSentence: String? {
        for state in [controller.reach, controller.plant, controller.wake] {
            if case .failed(let sentence) = state { return sentence }
        }
        return nil
    }

    private func stageLine(
        _ label: String, state: PairingController.StageLineState, id: String
    ) -> some View {
        let labelOpacity: Double
        var glyph: String?
        var glyphColor = Tokens.Role.selectedPath
        var isFailed = false
        switch state {
        case .pending:
            labelOpacity = 0.3
        case .active:
            labelOpacity = 1.0
            glyph = "●"
            glyphColor = Tokens.Role.secondaryInfo
        case .done:
            labelOpacity = 0.55
            glyph = "✓"
            glyphColor = Tokens.Role.selectedPath
        case .failed:
            labelOpacity = 0.9
            glyph = "✕"
            glyphColor = Tokens.Palette.ember
            isFailed = true
        }
        return ZStack {
            // Mock 1c2: the label column rides ~15pt left of center; the
            // glyph column sits at ~x=320 of 390.
            Text(label)
                .font(Tokens.Fonts.mono(9, medium: state == .active))
                .tracking(1.0)
                .foregroundStyle(
                    (isFailed ? Tokens.Palette.ember : Tokens.Role.displayText)
                        .opacity(labelOpacity))
                .frame(width: 220)
                .offset(x: -15)
            if let glyph {
                Text(glyph)
                    .font(Tokens.Fonts.mono(state == .active ? 8 : 10))
                    .foregroundStyle(glyphColor)
                    .frame(width: 250, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
        .accessibilityLabel(label)
    }

    // MARK: - 1c: pairing code (hand-installed fallback)

    private func codeScreen(in size: CGSize) -> some View {
        ZStack {
            whisper(
                controller.address.trimmingCharacters(in: .whitespacesAndNewlines),
                color: Tokens.Role.secondaryInfo.opacity(0.45))
                .position(x: size.width / 2, y: size.height * 0.3137)

            PairingNodeView(style: .brightening)
                .position(x: size.width / 2, y: size.height * 0.388)

            codeCells
                .position(x: size.width / 2, y: size.height * 0.5234)

            whisper("code shown by your server", color: Tokens.Role.displayText.opacity(0.4))
                .accessibilityIdentifier("pairing.code.caption")
                .position(x: size.width / 2, y: size.height * 0.5853)

            // The invisible input carrying the six characters.
            TextField("", text: $controller.code)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .code)
                .onChange(of: controller.code) { controller.codeEdited() }
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .opacity(0.05)
                .accessibilityIdentifier("pairing.code")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !frozen { focusedField = .code }
        }
        .onAppear {
            if !frozen { focusedField = .code }
        }
        .sensoryFeedback(.error, trigger: controller.codeRejections) { _, new in new > 0 }
    }

    private var codeCells: some View {
        let entered = Array(controller.code)
        return HStack(spacing: 7.5) {
            ForEach(0..<6, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: 0x0A0C1A).opacity(0.7))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            index == entered.count
                                ? Tokens.Role.secondaryInfo.opacity(0.45)
                                : Tokens.Role.edgeNeutral.opacity(index < entered.count ? 0.4 : 0.25),
                            lineWidth: 1)
                    if index < entered.count {
                        Text(String(entered[index]))
                            .font(Tokens.Fonts.mono(20))
                            .foregroundStyle(Tokens.Role.displayText)
                    } else if index == entered.count {
                        // Cyan caret in the active cell.
                        CaretBar()
                    }
                }
                .frame(width: 36.5, height: 43.5)
            }
        }
        .modifier(ShakeEffect(shakes: CGFloat(controller.codeRejections)))
        .animation(
            Motion.isReduced ? nil : .linear(duration: 0.35),
            value: controller.codeRejections)
    }

    // MARK: - 1d: paired

    private func pairedScreen(in size: CGSize) -> some View {
        ZStack {
            PairingNodeView(style: .ignited)
                .position(x: size.width / 2, y: size.height * 0.4473)

            whisper(
                controller.pairedAddress,
                color: Tokens.Role.selectedPath.opacity(0.95))
                .accessibilityIdentifier("pairing.paired.address")
                .position(x: size.width / 2, y: size.height * 0.5314)
        }
        .onAppear {
            Haptics.success()
            guard !frozen else { return }
            // The frame lasts under a second, then the flight home.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(950))
                controller.completePairing()
            }
        }
    }

    // MARK: - Shared pieces

    private func fieldWidth(_ size: CGSize) -> CGFloat {
        size.width - 80
    }

    private func capsuleField(
        text: Binding<String>, ghost: String, ember: Bool, identifier: String,
        width: CGFloat
    ) -> some View {
        TextField(
            "", text: text,
            prompt: Text(ghost)
                .font(Tokens.Fonts.mono(12))
                .foregroundStyle(Tokens.Role.displayText.opacity(0.35))
        )
        .font(Tokens.Fonts.mono(12))
        .tracking(1.2)
        .multilineTextAlignment(.center)
        .foregroundStyle(Tokens.Role.displayText)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .frame(width: width - 36, height: 48.5)
        .background(fieldChrome(ember: ember, width: width))
        .accessibilityIdentifier(identifier)
    }

    private func secureCapsuleField(width: CGFloat) -> some View {
        SecureField("", text: $controller.password)
            .font(Tokens.Fonts.mono(14))
            .tracking(3)
            .multilineTextAlignment(.center)
            .foregroundStyle(Tokens.Role.displayText.opacity(0.75))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(width: width - 36, height: 48.5)
            .background(fieldChrome(ember: false, width: width))
            .accessibilityIdentifier("pairing.password")
    }

    private func lockedCapsule(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(Tokens.Fonts.mono(12))
            .tracking(1.2)
            .foregroundStyle(Tokens.Role.displayText)
            .frame(width: width - 36, height: 48.5)
            .background(fieldChrome(ember: false, width: width))
            .accessibilityIdentifier("pairing.address.locked")
    }

    private func fieldChrome(ember: Bool, width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(hex: 0x0A0C1A).opacity(0.7))
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    ember
                        ? Tokens.Palette.ember.opacity(0.75)
                        : Tokens.Role.edgeNeutral.opacity(0.55),
                    lineWidth: 1)
        }
        .frame(width: width, height: 48.5)
        .animation(.easeInOut(duration: 0.25), value: ember)
    }

    private func whisper(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Tokens.Fonts.mono(9))
            .tracking(0.9)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }
}

// MARK: - The node (one motif, five states of light)

/// The waiting/probing/condensing/ignited node above the pairing chrome — the
/// birth motif (a radiant taking root IS a birth, ux-update §1). No spinners:
/// probing is a ~1/s pulse; Reduce Motion turns pulses into opacity steps.
struct PairingNodeView: View {
    enum Style {
        case waiting
        case dimmed
        case probing
        case brightening
        case condensing
        case ignited
    }

    var style: Style
    @State private var pulse = false
    @State private var ringsExpanded = false

    var body: some View {
        ZStack {
            if style == .ignited {
                // Two rings expand outward (~700ms) — mock 1d.
                Circle()
                    .strokeBorder(Tokens.Role.selectedPath.opacity(0.55), lineWidth: 1)
                    .frame(width: 34, height: 34)
                    .scaleEffect(ringsExpanded ? 1 : 0.4)
                    .opacity(ringsExpanded ? 1 : 0)
                Circle()
                    .strokeBorder(Tokens.Role.selectedPath.opacity(0.3), lineWidth: 1)
                    .frame(width: 56, height: 56)
                    .scaleEffect(ringsExpanded ? 1 : 0.3)
                    .opacity(ringsExpanded ? 1 : 0)
            }
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.95), Tokens.Role.selectedPath, .clear],
                        center: .center, startRadius: 0, endRadius: glowRadius))
                .frame(width: glowRadius * 2, height: glowRadius * 2)
                .opacity(coreOpacity)
                .scaleEffect(pulseActive && pulse ? 1.18 : 1)
        }
        .animation(
            pulseActive && !Motion.isReduced
                ? .easeInOut(duration: Tokens.Motion.probePulsePeriodSeconds / 2)
                    .repeatForever(autoreverses: true)
                : .default,
            value: pulse)
        .onAppear {
            if pulseActive { pulse = true }
            if style == .ignited {
                if Motion.isReduced {
                    ringsExpanded = true
                } else {
                    withAnimation(.easeOut(duration: Tokens.Motion.pairedRingsSeconds)) {
                        ringsExpanded = true
                    }
                }
            }
        }
        .onChange(of: pulseActive) { _, active in
            pulse = active
        }
    }

    private var pulseActive: Bool {
        style == .probing || style == .condensing
    }

    private var glowRadius: CGFloat {
        switch style {
        case .waiting, .dimmed, .probing: return 11
        case .brightening, .condensing: return 14
        case .ignited: return 14
        }
    }

    private var coreOpacity: Double {
        switch style {
        case .dimmed: return 0.35
        case .waiting: return 0.7
        case .probing: return 0.85
        case .brightening, .condensing: return 0.95
        case .ignited: return 1
        }
    }
}

// MARK: - Small effects

/// Cyan caret bar blinking in the active code cell (1c).
private struct CaretBar: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Tokens.Role.secondaryInfo)
            .frame(width: 2, height: 20)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                guard !Motion.isReduced else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

/// Wrong code: shake-and-clear (1c).
private struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(
            CGAffineTransform(translationX: 9 * sin(shakes * .pi * 6), y: 0))
    }
}
