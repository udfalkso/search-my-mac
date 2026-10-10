#if SMM_APP_STORE
import Foundation
import StoreKit
import SwiftUI

@MainActor
final class StorePurchaseController: ObservableObject {
    @Published private(set) var access = StoreAccessState.notStarted
    @Published private(set) var hasCheckedAccess = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var isBusy = false
    @Published private(set) var model: AppModel?
    @Published var message: String?

    private var transactionTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var refreshRevision = 0
    private let productIDs = [StoreAccessPolicy.trialProductID, StoreAccessPolicy.unlockProductID]

    init() {
        transactionTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result,
                      productIDs.contains(transaction.productID) else { continue }
                await refreshAccess()
                await transaction.finish()
            }
        }
        expiryTask = Task { [weak self] in
            await self?.refreshAccess()
            await self?.loadProducts()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                await self?.refreshAccess()
            }
        }
    }

    var unlockPrice: String? {
        products.first { $0.id == StoreAccessPolicy.unlockProductID }?.displayPrice
    }

    func productAvailable(_ id: String) -> Bool { products.contains { $0.id == id } }

    func loadProducts() async {
        do {
            products = try await Product.products(for: productIDs).filter { $0.type == .nonConsumable }
            if products.count != productIDs.count {
                message = "Purchases are unavailable right now. Try again later or restore an existing purchase."
            }
        } catch { message = error.localizedDescription }
    }

    func refreshAccess() async {
        refreshRevision += 1
        let revision = refreshRevision
        var purchases: [StoreAccessPolicy.Purchase] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.productType == .nonConsumable else { continue }
            purchases.append(.init(
                productID: transaction.productID,
                originalPurchaseDate: transaction.originalPurchaseDate,
                isRevoked: transaction.revocationDate != nil
            ))
        }
        guard revision == refreshRevision else { return }
        access = StoreAccessPolicy.evaluate(purchases, now: .now)
        hasCheckedAccess = true
        reconcileSession()
    }

    /// Keep the model resident when windows close. On expiry/refund, stop its
    /// workers before opening another session, leaving the local index intact.
    private func reconcileSession() {
        guard sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            guard let self else { return }
            while true {
                if access.allowsSearch {
                    if model == nil { model = AppModel() }
                    break
                }
                guard let activeModel = model else { break }
                await activeModel.shutdown()
                model = nil
            }
            sessionTask = nil
        }
    }

    func purchase(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        if !productAvailable(id) { await loadProducts() }
        guard let product = products.first(where: { $0.id == id }) else { return }
        guard id != StoreAccessPolicy.trialProductID || product.price == 0 else {
            message = "The free trial is temporarily unavailable. No purchase was started."
            return
        }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "Apple could not verify this purchase. Try Restore Purchases."
                    return
                }
                await refreshAccess()
                await transaction.finish()
            case .pending:
                message = "Your purchase is awaiting approval. Access will update when Apple confirms it."
            case .userCancelled: break
            @unknown default:
                message = "The purchase could not be completed. Try again."
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            await refreshAccess()
            if !access.allowsSearch {
                message = access == .expired
                    ? "Your previous trial has ended. A full unlock restores access."
                    : "No full unlock or active trial was found for this Apple account."
            }
        } catch { message = error.localizedDescription }
    }
}

struct StoreAccessView: View {
    @ObservedObject var purchases: StorePurchaseController

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(purchases.access == .expired ? "Your trial has ended" : "Search inside your documents")
                .font(.largeTitle.bold())
            Text("Find matching passages and preview your files, privately on your Mac.")
                .foregroundStyle(.secondary)
            if !purchases.hasCheckedAccess {
                ProgressView("Checking purchases…")
            } else {
                Text(purchases.access == .expired
                     ? "Unlock Search My Mac to continue searching and indexing. Your documents and local index have been preserved."
                     : "Try all features for seven days. When the trial ends, searching and indexing pause until you choose a one-time unlock. Your documents and local index are preserved.")
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    if purchases.access == .notStarted {
                        Button("Start 7-day Free Trial") {
                            Task { await purchases.purchase(StoreAccessPolicy.trialProductID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(purchases.isBusy || !purchases.productAvailable(StoreAccessPolicy.trialProductID))
                        .keyboardShortcut(.defaultAction)
                    }
                    Button(purchases.unlockPrice.map { "Unlock for \($0)" } ?? "Unlock Search My Mac") {
                        Task { await purchases.purchase(StoreAccessPolicy.unlockProductID) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(purchases.isBusy || !purchases.productAvailable(StoreAccessPolicy.unlockProductID))
                }
                Text("One-time purchase. No subscription. The trial does not charge you automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Restore Purchases") { Task { await purchases.restore() } }
                    Button("Retry") { Task { await purchases.loadProducts(); await purchases.refreshAccess() } }
                }
                .disabled(purchases.isBusy)
                Link("Privacy Policy", destination: URL(string: "https://github.com/udfalkso/search-my-mac/blob/main/docs/PRIVACY.md")!)
            }
            if purchases.isBusy { ProgressView().controlSize(.small) }
            if let message = purchases.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).accessibilityLabel(message)
            }
        }
        .frame(maxWidth: 560)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
