import AppKit
import SwiftUI

extension ContentView {

    // MARK: - Proxy Mode Layout

    var proxyModeView: some View {
        HStack(spacing: 0) {
            sidebarNav
            Divider()
            if showSettings {
                settingsPanel
            } else {
                tabContentPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if toastVisible, let message = toastMessage {
                toastBanner(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toastVisible)
        .onChange(of: backend.connectionError) { _, newError in
            if let error = newError, !error.isEmpty {
                showToast(error)
            }
        }
    }

    func showToast(_ message: String) {
        toastMessage = message
        withAnimation { toastVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard toastMessage == message else { return }
            withAnimation { toastVisible = false }
            try? await Task.sleep(for: .milliseconds(400))
            if toastMessage == message {
                toastMessage = nil
                backend.connectionError = nil
            }
        }
    }

    func toastBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 4)

            Button {
                withAnimation { toastVisible = false }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    toastMessage = nil
                    backend.connectionError = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Sidebar Navigation

    var sidebarNav: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach([SidebarTab.mode, .nodes], id: \.self) { tab in
                    sidebarTabButton(tab)
                }

                if developerMode {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 0.5)
                        Text("开发者")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange.opacity(0.55))
                            .tracking(0.3)
                            .fixedSize()
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 0.5)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                    ForEach([SidebarTab.connections, .logs, .dns, .sniffing], id: \.self) { tab in
                        sidebarTabButton(tab)
                    }
                }

                Spacer()
                Divider().padding(.horizontal, -8)
                sidebarBottom
                    .padding(.bottom, 10)
            }
            .padding(.top, 38)
            .padding(.horizontal, 8)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.965, green: 0.965, blue: 0.97))
    }

    var sidebarBottom: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
            

                Text(authService.isLoggedIn ? AuthService.maskedEmail(authService.userEmail ?? "") : "注册/登录")
                    .font(.system(size: 10))
                    .foregroundStyle(isHoveringAccount ? .primary : .tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isHoveringAccount ? Color(nsColor: .darkGray).opacity(0.1) : Color.clear)
                    )
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            isHoveringAccount = hovering
                        }
                    }
                    .onTapGesture { showAccountPopover.toggle() }
                    .popover(isPresented: $showAccountPopover, arrowEdge: .top) {
                        accountPopoverContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 10) {
              

                Button(action: { swiftLog.ui("tap toggleSettings"); showSettings.toggle() }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(showSettings || isHoveringGear ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(showSettings || isHoveringGear
                                      ? Color(nsColor: .darkGray).opacity(0.15)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.borderless)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringGear = hovering
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10)
    }

    func sidebarTabButton(_ tab: SidebarTab) -> some View {
        let isSelected = selectedTab == tab && !showSettings
        let isHovered = hoveredTab == tab
        return Button {
            swiftLog.ui("tap sidebar=\(tab.title)")
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTab = tab
                showSettings = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor.opacity(0.7) : .secondary)
                    .frame(width: 18, alignment: .center)
                Text(tab.title)
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.9) : Color.secondary.opacity(0.96))
                Spacer(minLength: 0)
                if tab == .mode, masterSwitchOn {
                    Text(backend.proxyMode.displayName)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.gray.opacity(0.55))
                }
                if tab == .nodes, masterSwitchOn {
                    Group {
                        if backend.proxyMode == .direct {
                            // Text("直连")
                            //     .foregroundStyle(Color.gray.opacity(0.55))
                        } else if let group = backend.activeProxyGroup {
                            Text(group.now.strippingEmoji)
                                .foregroundStyle(Color.gray.opacity(0.55))
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 50, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: 9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isSelected
                    ? Color(nsColor: .darkGray).opacity(0.1)
                    : (isHovered ? Color(nsColor: .darkGray).opacity(0.06) : Color.clear),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // .overlay(alignment: .trailing) {
            //     if isSelected {
            //         RoundedRectangle(cornerRadius: 1.5)
            //             .fill(Color.accentColor.opacity(0.55))
            //             .frame(width: 3)
            //             .padding(.vertical, 7)
            //             .padding(.trailing, 6)
            //     }
            // }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredTab = hovering ? tab : nil
            }
        }
    }

    // MARK: - Tab Content Panel

    var tabContentPanel: some View {
        ZStack {
            ScrollView {
                modeTabContent
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .opacity(selectedTab == .mode ? 1 : 0)
            .allowsHitTesting(selectedTab == .mode)

            nodesTabContent
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor))
                .opacity(selectedTab == .nodes ? 1 : 0)
                .allowsHitTesting(selectedTab == .nodes)

            connectionsTabContent
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor))
                .opacity(selectedTab == .connections ? 1 : 0)
                .allowsHitTesting(selectedTab == .connections)

            logsTabContent
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor))
                .opacity(selectedTab == .logs ? 1 : 0)
                .allowsHitTesting(selectedTab == .logs)

            dnsTabContent
                .opacity(selectedTab == .dns ? 1 : 0)
                .allowsHitTesting(selectedTab == .dns)

            snifferTabContent
                .opacity(selectedTab == .sniffing ? 1 : 0)
                .allowsHitTesting(selectedTab == .sniffing)
        }
    }

    // MARK: - Account Popover

    @ViewBuilder
    var accountPopoverContent: some View {
        if authService.isLoggedIn {
            loggedInPopoverContent
        } else {
            loginPopoverContent
        }
    }

    var loggedInPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 邮箱
            HStack(spacing: 6) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text(verbatim: authService.userEmail ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Button {
                    Task { await authService.logout() }
                    showAccountPopover = false
                } label: {
                    Text("退出")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(isHoveringRenew ? Color.primary.opacity(0.62) : Color.secondary.opacity(0.72))
                        .shadow(color: isHoveringRenew ? Color.black.opacity(0.1) : .clear, radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringRenew = hovering
                    }
                }
            }

            Divider()

            // 会员状态
            HStack {
                Text("会员状态")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                let planType = authService.membership?.plan_type ?? "free"
                let isFree = planType == "free"
                let status = authService.membership?.status ?? ""
                let hasActiveMembership = !isFree && status == "active"

                Button {
                    if let subscriptionURL = URL(string: "https://airtiz.net/subscription") {
                        NSWorkspace.shared.open(subscriptionURL)
                    }
                    showAccountPopover = false
                } label: {
                    HStack(spacing: 4) {
                        Text(AuthService.planDisplayName(planType))
                            .font(.system(size: 10, weight: .medium))
                        if hasActiveMembership {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(isFree ? .secondary : Color(red: 1.0, green: 0.45, blue: 0.2))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                isFree
                                    ? Color.gray.opacity(isHoveringMembershipPlan ? 0.18 : 0.1)
                                    : Color(red: 1.0, green: 0.45, blue: 0.2).opacity(isHoveringMembershipPlan ? 0.2 : 0.1)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringMembershipPlan = hovering
                    }
                }
            }

            if !(authService.membership?.plan_type != "free" && authService.membership?.status == "active") {
                Button {
                    if let priceURL = URL(string: "https://airtiz.net/price") {
                        NSWorkspace.shared.open(priceURL)
                    }
                    showAccountPopover = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("解锁Pro版")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(
                        isHoveringUpgrade
                            ? Color(red: 0.95, green: 0.44, blue: 0.16)
                            : Color(red: 0.92, green: 0.48, blue: 0.2)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                isHoveringUpgrade
                                    ? Color(red: 1.0, green: 0.73, blue: 0.5).opacity(0.26)
                                    : Color(red: 1.0, green: 0.78, blue: 0.58).opacity(0.18)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                Color(red: 0.95, green: 0.56, blue: 0.3).opacity(isHoveringUpgrade ? 0.7 : 0.5),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isHoveringUpgrade ? Color(red: 1.0, green: 0.6, blue: 0.35).opacity(0.2) : .clear,
                        radius: 6,
                        y: 2
                    )
                }
                .padding(.vertical, 2)
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHoveringUpgrade = hovering
                    }
                }
            }

            // 到期时间
            if let expiryDate = AuthService.formatExpiryDate(authService.membership?.expires_at) {
                HStack {
                    Text("到期时间")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(expiryDate)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
            }

        }
        .padding(14)
        .frame(width: 236)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    var loginPopoverContent: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("注册&登录")
                    .font(.system(size: 14, weight: .medium))
                Text("内测期间注册，赠送永久Pro会员")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // 邮箱输入
            TextField("邮箱", text: $loginEmail)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            // 验证码输入 + 发送按钮
            HStack(spacing: 8) {
                TextField("验证码", text: $loginCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button {
                    guard !loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    isSendingCode = true
                    Task {
                        let success = await authService.sendCode(email: loginEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                        isSendingCode = false
                        if success {
                            isCodeSent = true
                            codeCooldown = 60
                            startCodeCooldown()
                        } else {
                            loginError = authService.errorMessage
                        }
                    }
                } label: {
                    Group {
                        if isSendingCode {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(codeCooldown > 0 ? "\(codeCooldown)s" : (isCodeSent ? "重新发送" : "发送验证码"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(codeCooldown > 0 ? Color.orange.opacity(0.65) : Color.orange)
                        }
                    }
                    .frame(minWidth: 48)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(codeCooldown > 0 ? Color.orange.opacity(0.1) : Color.orange.opacity(0.14))
                    )
                }
                .buttonStyle(.borderless)
                .disabled(isSendingCode || codeCooldown > 0 || loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 错误提示
            if let error = loginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // 登录按钮
            Button {
                loginError = nil
                Task {
                    let success = await authService.login(
                        email: loginEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                        code: loginCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if success {
                        loginEmail = ""
                        loginCode = ""
                        isCodeSent = false
                        codeCooldown = 0
                        loginError = nil
                        showAccountPopover = false
                    } else {
                        loginError = authService.errorMessage
                    }
                }
            } label: {
                if authService.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                } else {
                    Text("登录")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.22, green: 0.49, blue: 0.98))
                        )
                }
            }
            .buttonStyle(.borderless)
            .disabled(authService.isLoading || loginEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14)
        .frame(width: 260)
    }

    func startCodeCooldown() {
        Task {
            while codeCooldown > 0 {
                try? await Task.sleep(for: .seconds(1))
                codeCooldown -= 1
            }
        }
    }

    func developerTabPlaceholder(_ tab: SidebarTab) -> some View {
        VStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.orange.opacity(0.45))
            Text(tab.title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("开发者调试面板 · 即将推出")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
