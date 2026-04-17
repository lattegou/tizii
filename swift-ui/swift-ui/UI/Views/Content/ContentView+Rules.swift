import SwiftUI

extension ContentView {

    // MARK: - Rule Groups

    var ruleGroupData: [(name: String, color: Color, count: Int, rules: [AppService.RuleItem])] {
        var rejectRules: [AppService.RuleItem] = []
        var directRules: [AppService.RuleItem] = []
        var proxyRules: [AppService.RuleItem] = []
        var matchRules: [AppService.RuleItem] = []

        for rule in backend.rules {
            if rule.type == "MATCH" {
                matchRules.append(rule)
            } else if rule.proxy == "REJECT" || rule.proxy == "REJECT-DROP" {
                rejectRules.append(rule)
            } else if rule.proxy == "DIRECT" {
                directRules.append(rule)
            } else {
                proxyRules.append(rule)
            }
        }

        func count(_ rules: [AppService.RuleItem]) -> Int {
            rules.reduce(0) { $0 + (($1.type == "RULE-SET") ? max($1.size, 1) : 1) }
        }

        var groups: [(name: String, color: Color, count: Int, rules: [AppService.RuleItem])] = []
        if !rejectRules.isEmpty { groups.append(("广告拦截", .red, count(rejectRules), rejectRules)) }
        if !directRules.isEmpty { groups.append(("直连规则", .green, count(directRules), directRules)) }
        if !proxyRules.isEmpty { groups.append(("代理规则", .blue, count(proxyRules), proxyRules)) }
        if !matchRules.isEmpty { groups.append(("最终规则", .purple, count(matchRules), matchRules)) }
        return groups
    }

    var ruleGroupsView: some View {
        VStack(spacing: 8) {
            let groups = ruleGroupData
            if groups.isEmpty {
                if backend.isLoadingRules {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("加载中…").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    Text("暂无规则")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let isExpanded = expandedRuleGroups.contains(group.name)
                    let isHovered = hoveredRuleGroup == group.name
                    VStack(spacing: 0) {
                        Button {
                            swiftLog.ui("tap ruleGroup=\(group.name)")
                            withAnimation(.spring(duration: 0.3, bounce: 0)) {
                                if isExpanded {
                                    expandedRuleGroups.remove(group.name)
                                } else {
                                    expandedRuleGroups.insert(group.name)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(group.color)
                                    .frame(width: 10, height: 10)

                                Text(group.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.primary.opacity(0.65))

                                Spacer()

                                Text("\(group.count) 条")
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(.tertiary)

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(isHovered ? .gray.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: isExpanded ? 0 : 10, style: .continuous))
                        .onHover { hovering in
                            if hovering {
                                hoveredRuleGroup = group.name
                            } else if hoveredRuleGroup == group.name {
                                hoveredRuleGroup = nil
                            }
                        }

                        if isExpanded {
                            VStack(spacing: 0) {
                                Divider()

                                if group.rules.isEmpty {
                                    Text("暂无规则")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                } else {
                                    ScrollView {
                                        LazyVStack(spacing: 0) {
                                            ForEach(group.rules) { rule in
                                                ruleRow(rule)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .frame(maxHeight: 260)
                                }
                            }
                            .background(.gray.opacity(0.08))
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.gray.opacity(0.15), lineWidth: 1)
                    )
                }
            }
        }
    }

    func ruleRow(_ rule: AppService.RuleItem) -> some View {
        HStack(spacing: 8) {
            Text(rule.type)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

            Text(rule.payload.isEmpty ? "(empty)" : rule.payload)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if rule.type == "RULE-SET" && rule.size > 0 {
                Text("\(rule.size)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(rule.proxy)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
