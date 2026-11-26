import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

/// Error and exceptional-operation feedback is an inline row below the battery
/// card. Ordinary charging operations instead update their own status pills.
struct OperationFeedbackView: View {
    @ObservedObject var manager: ChargeManager
    @State private var dismissedError: AppText?
    @State private var showDetails = false
    @State private var errorDetails: AppText = ""
    @State private var errorTitle: AppText = "操作未完成"

    private var errorVisible: Bool {
        !manager.isPreparingToQuit && !manager.isBusy && manager.isError && !isRoutineFirmwareReadiness
            && dismissedError != manager.statusMessage
    }

    // The charge-control status pill already communicates readiness.
    // Do not duplicate it with a persistent warning card.
    private var isRoutineFirmwareReadiness: Bool {
        guard firmwareNotReady else { return false }
        let message = manager.statusMessage.source
        return message == "请保持接电，尝试强制重置。若仍未就绪，请重启 Mac。未写入固件。"
            || message == "任务已清除，固件仍未就绪。请保持接电，必要时重启 Mac。"
    }

    private var genericBusy: Bool {
        !manager.isPreparingToQuit && manager.isBusy && manager.activeOperation == nil
    }

    private var firmwareNotReady: Bool {
        manager.currentState?.isInactiveUninitialized == true
            && !manager.backendReady
    }

    private var compactErrorTitle: AppText {
        if manager.statusMessage.source.hasPrefix("重置尚未完成") { return "重置未完成" }
        return firmwareNotReady ? "固件未就绪" : manager.statusMessage
    }

    var body: some View {
        Group {
            if errorVisible || genericBusy {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 7) {
                        if genericBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                        }
                        Text(manager.text(errorVisible ? compactErrorTitle : manager.statusMessage))
                            .font(.caption)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if errorVisible {
                            Button {
                                dismissedError = manager.statusMessage
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel(manager.text("关闭提示"))
                        }
                    }
                    if errorVisible {
                        HStack(spacing: 10) {
                            Button(manager.text("详情")) {
                                errorDetails = manager.statusMessage
                                errorTitle = firmwareNotReady ? "固件未就绪" : "操作未完成"
                                showDetails = true
                            }
                            if manager.canRetryChargeRequest && (!firmwareNotReady || !manager.canForceReset) {
                                Button(manager.text("重试")) { manager.retryChargeRequest() }
                            }
                            if manager.canForceReset {
                                Button(manager.text("强制重置")) { manager.requestForceReset() }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                        .padding(.leading, 20)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: errorVisible)
        .animation(.easeInOut(duration: 0.22), value: genericBusy)
        .onReceive(manager.$isBusy.removeDuplicates().receive(on: RunLoop.main)) { busy in
            if busy { dismissedError = nil }
        }
        .onReceive(manager.$statusMessage.removeDuplicates().receive(on: RunLoop.main)) { message in
            if dismissedError != message { dismissedError = nil }
        }
        .alert(manager.text(errorTitle), isPresented: $showDetails) {
            Button(manager.text("关闭"), role: .cancel) { }
        } message: { Text(manager.text(errorDetails)) }
    }
}
