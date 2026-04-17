import SwiftUI

extension ContentView {

    // MARK: - Subscription Management

    var subscriptionManagementView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                swiftLog.ui("tap toggleSubscriptions")
                isSubscriptionsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("订阅管理")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("已导入 \(backend.subscriptions.count) 个订阅")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    if backend.isLoadingSubscriptions {
                        ProgressView().controlSize(.small)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isSubscriptionsExpanded ? 180 : 0))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(
                    Color.primary.opacity(isHoveringSubscriptions ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(isHoveringSubscriptions ? 0.06 : 0), radius: isHoveringSubscriptions ? 3 : 0, y: 1)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHoveringSubscriptions = hovering
                }
            }

            if isSubscriptionsExpanded {
                let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(backend.subscriptions) { item in
                        subscriptionCard(item)
                    }
                    addSubscriptionCard
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        }
        .alert("确认删除", isPresented: $showDeleteSubscriptionAlert) {
            Button("取消", role: .cancel) {
                subscriptionToDelete = nil
            }
            Button("删除", role: .destructive) {
                if let item = subscriptionToDelete {
                    deleteSubscription(item)
                }
                subscriptionToDelete = nil
            }
        } message: {
            Text("确定要删除订阅「\(subscriptionToDelete?.name ?? "")」吗？删除后无法恢复。")
        }
    }

    func subscriptionCard(_ item: AppService.SubscriptionItem) -> some View {
        Button {
            swiftLog.ui("tap switchSubscription=\(item.name)")
            switchSubscription(item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if item.isCurrent {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text("使用中")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.type == "remote" ? "远程订阅" : "本地配置")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let extra = item.extra, let total = extra.total, total > 0 {
                            let used = max((extra.upload ?? 0) + (extra.download ?? 0), 0)
                            let remaining = max(total - used, 0)
                            Text(AppService.formatBytes(remaining) + " 剩余")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(item.type == "remote" ? "流量未知" : "本地文件")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 10) {
                        Button {
                            swiftLog.ui("tap refreshSubscription=\(item.name)")
                            Task {
                                if item.type == "remote" {
                                    await backend.refreshRemoteSubscription(id: item.id)
                                } else {
                                    await backend.fetchSubscriptions()
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(item.type == "remote" ? "重新拉取远程订阅" : "刷新订阅")

                        Button {
                            swiftLog.ui("tap viewSubscription=\(item.name)")
                            openSubscription(item)
                        } label: {
                            Image(systemName: "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("查看配置")

                        Button {
                            swiftLog.ui("tap deleteSubscription=\(item.name)")
                            subscriptionToDelete = item
                            showDeleteSubscriptionAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("删除订阅")
                    }
                }
            }
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(
                item.isCurrent
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        item.isCurrent ? Color.accentColor.opacity(0.19) : Color.secondary.opacity(0.08),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("刷新订阅") {
                swiftLog.ui("ctx refreshSubscription=\(item.name)")
                Task {
                    if item.type == "remote" {
                        await backend.refreshRemoteSubscription(id: item.id)
                    } else {
                        await backend.fetchSubscriptions()
                    }
                }
            }
            Button("查看配置") { swiftLog.ui("ctx viewSubscription=\(item.name)"); openSubscription(item) }
            Divider()
            Button("删除订阅", role: .destructive) {
                swiftLog.ui("ctx deleteSubscription=\(item.name)")
                subscriptionToDelete = item
                showDeleteSubscriptionAlert = true
            }
        }
    }

    var addSubscriptionCard: some View {
        Button {
            swiftLog.ui("tap addSubscription")
            showImportSubscriptionSheet = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isAddSubscriptionBlinking ? Color.accentColor : .secondary)
                Text("添加订阅")
                    .font(.system(size: 12))
                    .foregroundStyle(isAddSubscriptionBlinking ? Color.accentColor : .secondary)
            }
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .foregroundStyle(
                        isAddSubscriptionBlinking
                            ? Color.accentColor.opacity(0.6)
                            : Color.secondary.opacity(0.3)
                    )
            )
            .opacity(isAddSubscriptionBlinking ? 0.5 : 1.0)
            .animation(
                isAddSubscriptionBlinking
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isAddSubscriptionBlinking
            )
        }
        .buttonStyle(.plain)
    }

    var importSubscriptionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("添加订阅")
                    .font(.headline)

                Text(backend.subscriptions.isEmpty ? "添加订阅后即可开启代理" : "自动从远程拉取并导入配置")
                    .font(.caption)
                    .foregroundStyle(backend.subscriptions.isEmpty ? .orange : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("订阅链接").font(.caption).foregroundStyle(.secondary)
                TextField("https://...", text: $subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { importSubscription() }
            }

            if let error = backend.connectionError, !error.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .foregroundStyle(.red)
                }
                .font(.caption)
            }

            HStack {
                Button("取消") {
                    swiftLog.ui("tap importSubscription.cancel")
                    showImportSubscriptionSheet = false
                    subscriptionURL = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    swiftLog.ui("tap importSubscription.manualInput")
                    showImportSubscriptionSheet = false
                    subscriptionURL = ""
                    showYamlInputSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("手动输入")
                    }
                }

                Button(action: { importSubscription() }) {
                    HStack(spacing: 4) {
                        if backend.isImportingSubscription {
                            ProgressView().controlSize(.small)
                        }
                        Text(backend.isImportingSubscription ? "导入中…" : "导入")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImportSubscription)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    var yamlInputSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("手动输入配置")
                    .font(.headline)

                Text("粘贴或编写 YAML 配置内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("配置名称（可选）").font(.caption).foregroundStyle(.secondary)
                TextField("My Config", text: $yamlConfigName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("YAML 配置内容").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $yamlConfigContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 240)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            if let error = backend.connectionError, !error.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .foregroundStyle(.red)
                }
                .font(.caption)
            }

            HStack {
                Button("取消") {
                    swiftLog.ui("tap yamlInput.cancel")
                    showYamlInputSheet = false
                    yamlConfigName = ""
                    yamlConfigContent = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: { importYamlConfig() }) {
                    HStack(spacing: 4) {
                        if backend.isImportingSubscription {
                            ProgressView().controlSize(.small)
                        }
                        Text(backend.isImportingSubscription ? "导入中…" : "导入配置")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImportYamlConfig)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }

    private var isRemoteSubscription: Bool {
        selectedSubscription?.type == "remote"
    }

    var subscriptionViewerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedSubscription?.name ?? "配置内容")
                    .font(.headline)
                Spacer()

                if !isLoadingSubscriptionContent {
                    if isEditingSubscription {
                        Button {
                            swiftLog.ui("tap subscriptionViewer.cancelEdit")
                            isEditingSubscription = false
                            editedSubscriptionContent = ""
                        } label: {
                            Text("取消编辑")
                        }

                        Button {
                            swiftLog.ui("tap subscriptionViewer.save")
                            saveSubscriptionContent()
                        } label: {
                            HStack(spacing: 4) {
                                if isSavingSubscriptionContent {
                                    ProgressView().controlSize(.small)
                                }
                                Text(isSavingSubscriptionContent ? "保存中…" : "保存")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSavingSubscriptionContent)
                    } else {
                        Button {
                            swiftLog.ui("tap subscriptionViewer.edit")
                            editedSubscriptionContent = subscriptionContent
                            isEditingSubscription = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("编辑")
                            }
                        }
                    }
                }

                Button("关闭") {
                    swiftLog.ui("tap subscriptionViewer.close")
                    showSubscriptionViewer = false
                    isEditingSubscription = false
                    editedSubscriptionContent = ""
                }
            }

            if isEditingSubscription && isRemoteSubscription {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("此配置为远程订阅，下一次订阅刷新将覆盖本次的编辑")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if isLoadingSubscriptionContent {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("加载中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            } else if isEditingSubscription {
                TextEditor(text: $editedSubscriptionContent)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
                    )
            } else {
                ScrollView {
                    Text(subscriptionContent.isEmpty ? "配置为空" : subscriptionContent)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }

    func saveSubscriptionContent() {
        guard let item = selectedSubscription, !isSavingSubscriptionContent else { return }
        isSavingSubscriptionContent = true
        Task {
            do {
                try await backend.saveSubscriptionContent(id: item.id, content: editedSubscriptionContent)
                subscriptionContent = editedSubscriptionContent
                isEditingSubscription = false
                editedSubscriptionContent = ""
            } catch {
                swiftLog.error("saveSubscriptionContent failed: \(error.localizedDescription)")
            }
            isSavingSubscriptionContent = false
        }
    }

    func openSubscription(_ item: AppService.SubscriptionItem) {
        selectedSubscription = item
        subscriptionContent = ""
        isEditingSubscription = false
        editedSubscriptionContent = ""
        showSubscriptionViewer = true
        isLoadingSubscriptionContent = true
        Task {
            do {
                subscriptionContent = try await backend.loadSubscriptionContent(id: item.id)
            } catch {
                subscriptionContent = "读取配置失败：\(error.localizedDescription)"
            }
            isLoadingSubscriptionContent = false
        }
    }

    func switchSubscription(_ item: AppService.SubscriptionItem) {
        guard !item.isCurrent, !backend.isBusy else { return }
        Task {
            await backend.changeCurrentSubscription(id: item.id)
            await backend.testActiveProxyDelays()
        }
    }

    func deleteSubscription(_ item: AppService.SubscriptionItem) {
        guard !backend.isBusy else { return }
        Task {
            await backend.removeSubscription(id: item.id)
        }
    }
}
