//
//  BalancePopoverView.swift
//  deepseek launcher
//

import SwiftUI

struct BalancePopoverView: View {
    @ObservedObject var balance: BalanceService

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Account balance")
                    .font(.headline)
                Spacer()
                availabilityLabel
            }

            if balance.balances.isEmpty {
                ContentUnavailableView(
                    "Balance unavailable",
                    systemImage: "creditcard",
                    description: Text(balance.errorMessage ?? "Refresh to check the managed DeepSeek account.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(balance.balances) { item in
                    balanceSection(item)
                }
            }

            if balance.isStale, let error = balance.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Stale balance. \(error)")
            }

            Divider()

            HStack {
                if let lastUpdated = balance.lastUpdated {
                    Text("Last updated \(lastUpdated, format: .dateTime.hour().minute().second())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not updated yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: balance.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(balance.isRefreshing)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task { balance.refresh() }
    }

    private var availabilityLabel: some View {
        HStack(spacing: 5) {
            if balance.isRefreshing { ProgressView().controlSize(.small) }
            Text(availabilityText)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(availabilityColor)
        .accessibilityLabel("Account status: \(availabilityText)")
    }

    private func balanceSection(_ item: AccountBalance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.currency)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(BalanceFormatter.amount(item.total, currency: item.currency))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .accessibilityLabel("Total balance \(BalanceFormatter.amount(item.total, currency: item.currency))")
            HStack(spacing: 18) {
                balanceDetail("Topped up", value: item.toppedUp, currency: item.currency)
                balanceDetail("Granted", value: item.granted, currency: item.currency)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func balanceDetail(_ title: String, value: Decimal, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(BalanceFormatter.amount(value, currency: currency))
                .font(.subheadline.weight(.medium))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(BalanceFormatter.amount(value, currency: currency))")
    }

    private var availabilityText: String {
        switch balance.state {
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        case .loading: return "Refreshing"
        case .failed: return "Unavailable"
        case .idle: return "Not checked"
        }
    }

    private var availabilityColor: Color {
        switch balance.state {
        case .available: return .green
        case .unavailable, .failed: return .orange
        case .loading, .idle: return .secondary
        }
    }
}
