# Loyalty V2 and Pro Workflow Implementation Plan

> Historical record. ADR-0003/0004 supersede the staged-migration examples, ADR-0005 supersedes CloudKit guidance, and subscriptions are paused. Current implementation rules are in root `AGENTS.md` and scoped subsystem guides.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build configurable client-owned loyalty rewards, add the required SwiftData V2 migration, then add SwiftUI-native Mac/iPad pro windows and insights scrubbing.

**Architecture:** Loyalty remains client-owned and checkout-idempotent. New CloudKit-safe SwiftData models store loyalty configuration and reward templates; background actors own mutations. Pro windows are separate SwiftUI scenes that resolve route values from their own `modelContext` and never duplicate main-window router state.

**Tech Stack:** SwiftUI, SwiftData, StoreKit-gated premium UI, Charts, XCTest, Xcode synchronized root groups.

---

## File Structure

- Create: `Pawtrackr/Core/Storage/Models/LoyaltyConfig.swift`
  - Stores earning mode, earning values, threshold, and catalog flag.
  - Defines `LoyaltyEarnMode`, `LoyaltyConfigSnapshot`, and `LoyaltyConfigResolver`.
- Create: `Pawtrackr/Core/Storage/Models/LoyaltyRewardTemplate.swift`
  - Stores owner-editable reward templates and seed conversion from the built-in catalog.
- Modify: `Pawtrackr/Core/Storage/Migrations.swift`
  - Adds `PawtrackrSchemaV2`, lightweight V1-to-V2 stage, and `ensureLoyaltyDefaults`.
- Modify: `Pawtrackr/App/RootView.swift`
  - Runs loyalty default seeding during startup maintenance.
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyEngine.swift`
  - Computes points from a `LoyaltyConfigSnapshot`.
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyCheckoutProcessor.swift`
  - Accepts a config snapshot while preserving idempotency.
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyService.swift`
  - Adds config and reward-template mutation APIs.
- Modify: `Pawtrackr/Features/Checkout/CheckoutTransactionActor.swift`
  - Passes a config snapshot into loyalty earning during confirm-and-pay.
- Modify: `Pawtrackr/Features/Settings/SettingsView.swift`
  - Adds a Loyalty settings section.
- Create: `Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift`
  - Provides the premium configuration and reward-template editor.
- Modify: `Pawtrackr/Features/Loyalty/RewardsCatalogView.swift`
  - Reads persistent reward templates and falls back to seed templates during migration.
- Create: `Pawtrackr/App/ProWindows/DetachedClientWindow.swift`
  - Resolves and renders detached client and loyalty windows.
- Create: `Pawtrackr/App/ProWindows/DetachedInsightsWindow.swift`
  - Renders detached insights analysis.
- Modify: `Pawtrackr/App/PawtrackrApp.swift`
  - Adds Mac/iPad-capable `WindowGroup` scenes and commands.
- Modify: `Pawtrackr/Features/Clients/ClientDetailView.swift`
  - Adds toolbar/context actions for detached client and loyalty windows.
- Modify: `Pawtrackr/Features/Insights/InsightsView.swift`
  - Adds scrubber state and visible selected metrics where charts are already loaded.
- Create: `PawtrackrTests/LoyaltyConfigTests.swift`
- Create: `PawtrackrTests/LoyaltyServiceConfigTests.swift`
- Modify: `PawtrackrTests/MigrationsTests.swift`
- Modify: `PawtrackrTests/LoyaltyRewardCatalogTests.swift`
- Modify: `PawtrackrTests/CheckoutFlowTests.swift`
- Create: `PawtrackrUITests/ProWorkflowUITests.swift`

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so files placed under `Pawtrackr/`,
`PawtrackrTests/`, or `PawtrackrUITests/` are picked up without manual `.pbxproj` edits.

---

### Task 1: Add Loyalty V2 Model Tests And Models

**Files:**
- Create: `PawtrackrTests/LoyaltyConfigTests.swift`
- Create: `Pawtrackr/Core/Storage/Models/LoyaltyConfig.swift`
- Create: `Pawtrackr/Core/Storage/Models/LoyaltyRewardTemplate.swift`

- [ ] **Step 1: Write failing model tests**

Create `PawtrackrTests/LoyaltyConfigTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Pawtrackr

final class LoyaltyConfigTests: XCTestCase {
    func testDefaultConfigPreservesCurrentBusinessRules() {
        let config = LoyaltyConfig()

        XCTAssertEqual(config.earnMode, .pointsPerDollar)
        XCTAssertEqual(config.pointsPerDollar, Decimal(1))
        XCTAssertEqual(config.pointsPerVisit, 20)
        XCTAssertEqual(config.redemptionThreshold, 100)
        XCTAssertTrue(config.isRewardsCatalogEnabled)
    }

    func testConfigRejectsInvalidValuesByClampingToSafeDefaults() {
        let config = LoyaltyConfig()

        config.setPointsPerDollar(Decimal(string: "-2.5")!)
        config.setPointsPerVisit(-10)
        config.setRedemptionThreshold(0)

        XCTAssertEqual(config.pointsPerDollar, Decimal(0))
        XCTAssertEqual(config.pointsPerVisit, 0)
        XCTAssertEqual(config.redemptionThreshold, 1)
    }

    func testRewardTemplatesSeedFromBuiltInCatalog() {
        let templates = LoyaltyRewardTemplate.seedTemplates()

        XCTAssertEqual(templates.map(\.pointCost), LoyaltyReward.builtInCatalog.map(\.pointCost))
        XCTAssertEqual(templates.first?.title, LoyaltyReward.builtInCatalog.first?.title)
        XCTAssertTrue(templates.allSatisfy(\.isEnabled))
    }

    func testRewardTemplateRequiresPositiveCost() {
        let reward = LoyaltyRewardTemplate(
            title: "Free Nail Trim",
            detail: "A returning-client reward.",
            pointCost: -50,
            systemImage: "scissors",
            styleRaw: LoyaltyReward.Style.care.rawValue,
            sortOrder: 0
        )

        XCTAssertEqual(reward.pointCost, 1)
    }
}
```

- [ ] **Step 2: Run the model tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyConfigTests
```

Expected: fail with errors that `LoyaltyConfig`, `LoyaltyEarnMode`, and
`LoyaltyRewardTemplate` are not found.

- [ ] **Step 3: Add `LoyaltyConfig`**

Create `Pawtrackr/Core/Storage/Models/LoyaltyConfig.swift`:

```swift
import Foundation
import SwiftData

enum LoyaltyEarnMode: String, CaseIterable, Sendable {
    case pointsPerDollar
    case flatPerVisit
}

struct LoyaltyConfigSnapshot: Equatable, Sendable {
    var earnMode: LoyaltyEarnMode
    var pointsPerDollar: Decimal
    var pointsPerVisit: Int
    var redemptionThreshold: Int
    var isRewardsCatalogEnabled: Bool

    static let `default` = LoyaltyConfigSnapshot(
        earnMode: .pointsPerDollar,
        pointsPerDollar: Decimal(1),
        pointsPerVisit: 20,
        redemptionThreshold: 100,
        isRewardsCatalogEnabled: true
    )

    init(
        earnMode: LoyaltyEarnMode,
        pointsPerDollar: Decimal,
        pointsPerVisit: Int,
        redemptionThreshold: Int,
        isRewardsCatalogEnabled: Bool
    ) {
        self.earnMode = earnMode
        self.pointsPerDollar = max(pointsPerDollar, .zero)
        self.pointsPerVisit = max(0, pointsPerVisit)
        self.redemptionThreshold = max(1, redemptionThreshold)
        self.isRewardsCatalogEnabled = isRewardsCatalogEnabled
    }

    init(config: LoyaltyConfig?) {
        guard let config else {
            self = .default
            return
        }
        self.init(
            earnMode: config.earnMode,
            pointsPerDollar: config.pointsPerDollar,
            pointsPerVisit: config.pointsPerVisit,
            redemptionThreshold: config.redemptionThreshold,
            isRewardsCatalogEnabled: config.isRewardsCatalogEnabled
        )
    }
}

@Model
final class LoyaltyConfig {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    var earnModeRaw: String = LoyaltyEarnMode.pointsPerDollar.rawValue
    var pointsPerDollar: Decimal = Decimal(1)
    var pointsPerVisit: Int = 20
    var redemptionThreshold: Int = 100
    var isRewardsCatalogEnabled: Bool = true

    @Transient
    var earnMode: LoyaltyEarnMode {
        get { LoyaltyEarnMode(rawValue: earnModeRaw) ?? .pointsPerDollar }
        set {
            earnModeRaw = newValue.rawValue
            markModified()
        }
    }

    init() {
        uuid = UUID()
        createdAt = .now
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
    }

    var snapshot: LoyaltyConfigSnapshot {
        LoyaltyConfigSnapshot(config: self)
    }

    func setEarnMode(_ mode: LoyaltyEarnMode) {
        earnMode = mode
    }

    func setPointsPerDollar(_ value: Decimal) {
        pointsPerDollar = max(value.roundedMoney(scale: 4), .zero)
        markModified()
    }

    func setPointsPerVisit(_ value: Int) {
        pointsPerVisit = max(0, value)
        markModified()
    }

    func setRedemptionThreshold(_ value: Int) {
        redemptionThreshold = max(1, value)
        markModified()
    }

    func setRewardsCatalogEnabled(_ value: Bool) {
        isRewardsCatalogEnabled = value
        markModified()
    }

    private func markModified() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
    }
}

enum LoyaltyConfigResolver {
    static func snapshot(in context: ModelContext) -> LoyaltyConfigSnapshot {
        var descriptor = FetchDescriptor<LoyaltyConfig>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        let config = try? context.fetch(descriptor).first
        return LoyaltyConfigSnapshot(config: config)
    }
}
```

- [ ] **Step 4: Add `LoyaltyRewardTemplate`**

Create `Pawtrackr/Core/Storage/Models/LoyaltyRewardTemplate.swift`:

```swift
import Foundation
import SwiftData

@Model
final class LoyaltyRewardTemplate {
    var uuid: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastModifiedBy: UUID = DeviceIdentity.currentID

    var title: String = ""
    var detail: String = ""
    var pointCost: Int = 100
    var systemImage: String = "gift.fill"
    var styleRaw: String = LoyaltyReward.Style.credit.rawValue
    var sortOrder: Int = 0
    var isEnabled: Bool = true

    init(
        title: String,
        detail: String,
        pointCost: Int,
        systemImage: String,
        styleRaw: String,
        sortOrder: Int,
        isEnabled: Bool = true
    ) {
        self.uuid = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.lastModifiedBy = DeviceIdentity.currentID
        self.title = TextInputLimits.clamped(title, to: TextInputLimits.shortText)
        self.detail = TextInputLimits.clamped(detail, to: TextInputLimits.notes)
        self.pointCost = max(1, pointCost)
        self.systemImage = systemImage.isEmpty ? "gift.fill" : systemImage
        self.styleRaw = LoyaltyReward.Style(rawValue: styleRaw)?.rawValue ?? LoyaltyReward.Style.credit.rawValue
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
    }

    @Transient
    var style: LoyaltyReward.Style {
        get { LoyaltyReward.Style(rawValue: styleRaw) ?? .credit }
        set {
            styleRaw = newValue.rawValue
            markModified()
        }
    }

    var displayReward: LoyaltyReward {
        LoyaltyReward(
            id: uuid.uuidString,
            title: title,
            detail: detail,
            pointCost: pointCost,
            systemImage: systemImage,
            style: style
        )
    }

    func update(
        title: String,
        detail: String,
        pointCost: Int,
        systemImage: String,
        style: LoyaltyReward.Style,
        isEnabled: Bool
    ) {
        self.title = TextInputLimits.clamped(title, to: TextInputLimits.shortText)
        self.detail = TextInputLimits.clamped(detail, to: TextInputLimits.notes)
        self.pointCost = max(1, pointCost)
        self.systemImage = systemImage.isEmpty ? "gift.fill" : systemImage
        self.styleRaw = style.rawValue
        self.isEnabled = isEnabled
        markModified()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        markModified()
    }

    private func markModified() {
        updatedAt = .now
        lastModifiedBy = DeviceIdentity.currentID
    }

    static func seedTemplates() -> [LoyaltyRewardTemplate] {
        LoyaltyReward.builtInCatalog.enumerated().map { index, reward in
            LoyaltyRewardTemplate(
                title: reward.title,
                detail: reward.detail,
                pointCost: reward.pointCost,
                systemImage: reward.systemImage,
                styleRaw: reward.style.rawValue,
                sortOrder: index
            )
        }
    }
}
```

- [ ] **Step 5: Run the model tests and verify they pass**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyConfigTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Pawtrackr/Core/Storage/Models/LoyaltyConfig.swift \
        Pawtrackr/Core/Storage/Models/LoyaltyRewardTemplate.swift \
        PawtrackrTests/LoyaltyConfigTests.swift
git commit -m "feat(loyalty): add configurable loyalty models"
```

---

### Task 2: Add V2 Migration And Default Seeding

**Files:**
- Modify: `Pawtrackr/Core/Storage/Migrations.swift`
- Modify: `Pawtrackr/App/RootView.swift`
- Modify: `PawtrackrTests/MigrationsTests.swift`

- [ ] **Step 1: Add failing migration/default tests**

Append these tests to `PawtrackrTests/MigrationsTests.swift`:

```swift
func testEnsureLoyaltyDefaults_CreatesConfigAndRewardTemplates() throws {
    DataMigrations.ensureLoyaltyDefaults(in: context)

    let configs = try context.fetch(FetchDescriptor<LoyaltyConfig>())
    XCTAssertEqual(configs.count, 1)
    XCTAssertEqual(configs.first?.earnMode, .pointsPerDollar)
    XCTAssertEqual(configs.first?.pointsPerDollar, Decimal(1))
    XCTAssertEqual(configs.first?.pointsPerVisit, 20)
    XCTAssertEqual(configs.first?.redemptionThreshold, 100)

    let rewards = try context.fetch(
        FetchDescriptor<LoyaltyRewardTemplate>(sortBy: [SortDescriptor(\.sortOrder)])
    )
    XCTAssertEqual(rewards.count, LoyaltyReward.builtInCatalog.count)
    XCTAssertEqual(rewards.first?.pointCost, 100)
}

func testEnsureLoyaltyDefaults_IsIdempotent() throws {
    DataMigrations.ensureLoyaltyDefaults(in: context)
    DataMigrations.ensureLoyaltyDefaults(in: context)

    XCTAssertEqual(try context.fetch(FetchDescriptor<LoyaltyConfig>()).count, 1)
    XCTAssertEqual(
        try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>()).count,
        LoyaltyReward.builtInCatalog.count
    )
}
```

- [ ] **Step 2: Run migration tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/MigrationsTests/testEnsureLoyaltyDefaults_CreatesConfigAndRewardTemplates \
  -only-testing:PawtrackrTests/MigrationsTests/testEnsureLoyaltyDefaults_IsIdempotent
```

Expected: fail because `ensureLoyaltyDefaults` does not exist.

- [ ] **Step 3: Add schema V2 and migration stage**

In `Pawtrackr/Core/Storage/Migrations.swift`, change the schema section to this shape:

```swift
typealias PawtrackrSchema = PawtrackrSchemaV2

enum PawtrackrSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 7)

    static var models: [any PersistentModel.Type] {
        [
            Client.self, Pet.self, Visit.self, VisitItem.self, Service.self, Payment.self, User.self,
            DaySummary.self, ServiceDaySummary.self, CategoryDaySummary.self, ClientInsightSummary.self,
            CheckoutTransaction.self, EmergencyContact.self, BusinessConfig.self, MessageTemplate.self,
            InventoryItem.self, InventoryTransaction.self, DeviceMetadata.self, PresenceRecord.self,
            LoyaltyLedgerEntry.self
        ]
    }
}

enum PawtrackrSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 1, 0)

    static var models: [any PersistentModel.Type] {
        PawtrackrSchemaV1.models + [
            LoyaltyConfig.self,
            LoyaltyRewardTemplate.self
        ]
    }
}
```

Then update `PawtrackrMigrationPlan`:

```swift
enum PawtrackrMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [PawtrackrSchemaV1.self, PawtrackrSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: PawtrackrSchemaV1.self,
                toVersion: PawtrackrSchemaV2.self
            )
        ]
    }
}
```

- [ ] **Step 4: Add loyalty default seeding**

Add this method inside `enum DataMigrations` in `Pawtrackr/Core/Storage/Migrations.swift`:

```swift
static func ensureLoyaltyDefaults(in context: ModelContext) {
    do {
        var didChange = false

        var configDescriptor = FetchDescriptor<LoyaltyConfig>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        configDescriptor.fetchLimit = 2
        let configs = try context.fetch(configDescriptor)
        if configs.isEmpty {
            context.insert(LoyaltyConfig())
            didChange = true
        } else if configs.count > 1 {
            for duplicate in configs.dropFirst() {
                context.delete(duplicate)
                didChange = true
            }
        }

        let existingRewards = try context.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        let existingTitles = Set(existingRewards.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for template in LoyaltyRewardTemplate.seedTemplates() {
            let key = template.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !existingTitles.contains(key) {
                context.insert(template)
                didChange = true
            }
        }

        if didChange || context.hasChanges {
            try context.save()
        }
    } catch {
        Logger.migrations.error("ensureLoyaltyDefaults failed: \(String(describing: error))")
    }
}
```

- [ ] **Step 5: Run loyalty defaults during startup maintenance**

In `Pawtrackr/App/RootView.swift`, add the call next to other `DataMigrations` startup calls:

```swift
DataMigrations.ensureServiceCatalog(in: backgroundContext)
DataMigrations.ensureMessageTemplates(in: backgroundContext)
DataMigrations.ensureLoyaltyDefaults(in: backgroundContext)
DataMigrations.backfillLoyaltyLedger(in: backgroundContext)
```

- [ ] **Step 6: Run migration tests and verify they pass**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/MigrationsTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Pawtrackr/Core/Storage/Migrations.swift Pawtrackr/App/RootView.swift PawtrackrTests/MigrationsTests.swift
git commit -m "feat(loyalty): add loyalty v2 migration defaults"
```

---

### Task 3: Make Loyalty Earning Configurable And Idempotent

**Files:**
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyEngine.swift`
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyCheckoutProcessor.swift`
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyService.swift`
- Modify: `Pawtrackr/Features/Checkout/CheckoutTransactionActor.swift`
- Modify: `PawtrackrTests/LoyaltyServiceTests.swift`
- Modify: `PawtrackrTests/CheckoutFlowTests.swift`

- [ ] **Step 1: Add failing earning tests**

Append these tests to `PawtrackrTests/LoyaltyServiceTests.swift`:

```swift
func testCalculatePoints_UsesDefaultPointsPerDollarSnapshot() {
    let points = LoyaltyEngine.calculatePoints(
        for: Decimal(string: "80.99")!,
        config: .default
    )

    XCTAssertEqual(points, 80)
}

func testCalculatePoints_UsesFlatPerVisitSnapshot() {
    let config = LoyaltyConfigSnapshot(
        earnMode: .flatPerVisit,
        pointsPerDollar: Decimal(1),
        pointsPerVisit: 20,
        redemptionThreshold: 100,
        isRewardsCatalogEnabled: true
    )

    XCTAssertEqual(LoyaltyEngine.calculatePoints(for: Decimal(80), config: config), 20)
    XCTAssertEqual(LoyaltyEngine.calculatePoints(for: Decimal.zero, config: config), 0)
}
```

Append this test to `PawtrackrTests/CheckoutFlowTests.swift` near the existing loyalty processor tests:

```swift
@MainActor
func testLoyaltyProcessor_ReprocessesFlatVisitModeIdempotently() throws {
    let context = container.mainContext
    let client = Client(firstName: "Flat", lastName: "Mode")
    context.insert(client)
    let pet = Pet(name: "Miso", species: .dog)
    pet.owner = client
    context.insert(pet)
    let visit = Visit(pet: pet)
    context.insert(visit)
    try context.save()

    let config = LoyaltyConfigSnapshot(
        earnMode: .flatPerVisit,
        pointsPerDollar: Decimal(1),
        pointsPerVisit: 20,
        redemptionThreshold: 100,
        isRewardsCatalogEnabled: true
    )

    LoyaltyCheckoutProcessor.applyEarnings(
        visit: visit,
        pet: pet,
        total: Decimal(80),
        in: context,
        now: .now,
        config: config
    )
    LoyaltyCheckoutProcessor.applyEarnings(
        visit: visit,
        pet: pet,
        total: Decimal(120),
        in: context,
        now: .now,
        config: config
    )

    XCTAssertEqual(visit.loyaltyPointsChange, 20)
    XCTAssertEqual(client.loyaltyPoints, 20)
}
```

- [ ] **Step 2: Run targeted tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyServiceTests/testCalculatePoints_UsesDefaultPointsPerDollarSnapshot \
  -only-testing:PawtrackrTests/LoyaltyServiceTests/testCalculatePoints_UsesFlatPerVisitSnapshot \
  -only-testing:PawtrackrTests/CheckoutFlowTests/testLoyaltyProcessor_ReprocessesFlatVisitModeIdempotently
```

Expected: fail because `calculatePoints(for:config:)` and the `config:` processor argument do not
exist.

- [ ] **Step 3: Update `LoyaltyEngine`**

In `Pawtrackr/Features/Loyalty/LoyaltyEngine.swift`, replace `calculatePoints(for:)` with:

```swift
static func calculatePoints(for total: Decimal, config: LoyaltyConfigSnapshot = .default) -> Int {
    guard total > .zero else { return 0 }

    switch config.earnMode {
    case .pointsPerDollar:
        let roundedTotal = total.roundedMoney()
        let rawPoints = (roundedTotal * config.pointsPerDollar).roundedMoney(scale: 4)
        return max(0, (rawPoints as NSDecimalNumber).intValue)
    case .flatPerVisit:
        return max(0, config.pointsPerVisit)
    }
}
```

- [ ] **Step 4: Update `LoyaltyCheckoutProcessor`**

In `Pawtrackr/Features/Loyalty/LoyaltyCheckoutProcessor.swift`, change the signature and base points:

```swift
static func applyEarnings(
    visit: Visit,
    pet: Pet,
    total: Decimal,
    in context: ModelContext,
    now: Date = .now,
    config: LoyaltyConfigSnapshot = .default
) -> UUID? {
    let client = pet.owner

    let base = LoyaltyEngine.calculatePoints(for: total, config: config)
```

Keep the rest of the function body unchanged.

- [ ] **Step 5: Feed config from checkout and service paths**

In `Pawtrackr/Features/Checkout/CheckoutTransactionActor.swift`, before applying earnings:

```swift
let loyaltyConfig = LoyaltyConfigResolver.snapshot(in: modelContext)
let loyaltyClientUUID = LoyaltyCheckoutProcessor.applyEarnings(
    visit: visit,
    pet: pet,
    total: request.amount,
    in: modelContext,
    now: endedAt,
    config: loyaltyConfig
)
```

In `Pawtrackr/Features/Loyalty/LoyaltyService.swift`, update `applyPoints(for:)`:

```swift
let config = LoyaltyConfigResolver.snapshot(in: modelContext)
let clientUUID = LoyaltyCheckoutProcessor.applyEarnings(
    visit: visit,
    pet: pet,
    total: visit.total,
    in: modelContext,
    now: visit.endedAt ?? .now,
    config: config
)
```

- [ ] **Step 6: Run targeted earning tests and verify they pass**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyServiceTests \
  -only-testing:PawtrackrTests/CheckoutFlowTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Pawtrackr/Features/Loyalty/LoyaltyEngine.swift \
        Pawtrackr/Features/Loyalty/LoyaltyCheckoutProcessor.swift \
        Pawtrackr/Features/Loyalty/LoyaltyService.swift \
        Pawtrackr/Features/Checkout/CheckoutTransactionActor.swift \
        PawtrackrTests/LoyaltyServiceTests.swift \
        PawtrackrTests/CheckoutFlowTests.swift
git commit -m "feat(loyalty): apply configurable earning rules"
```

---

### Task 4: Add Loyalty Service APIs For Config And Rewards

**Files:**
- Create: `PawtrackrTests/LoyaltyServiceConfigTests.swift`
- Modify: `Pawtrackr/Features/Loyalty/LoyaltyService.swift`

- [ ] **Step 1: Add failing service tests**

Create `PawtrackrTests/LoyaltyServiceConfigTests.swift`:

```swift
import XCTest
import SwiftData
@testable import Pawtrackr

final class LoyaltyServiceConfigTests: XCTestCase {
    var container: ModelContainer!

    override func setUpWithError() throws {
        let schema = Schema(PawtrackrSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: PawtrackrMigrationPlan.self, configurations: [config])
        DataMigrations.ensureLoyaltyDefaults(in: container.mainContext)
    }

    func testUpdateConfigPersistsFlatVisitMode() async throws {
        let service = LoyaltyService(modelContainer: container)

        try await service.updateConfig(
            earnMode: .flatPerVisit,
            pointsPerDollar: Decimal(1),
            pointsPerVisit: 20,
            redemptionThreshold: 100,
            isRewardsCatalogEnabled: true
        )

        let config = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<LoyaltyConfig>()).first)
        XCTAssertEqual(config.earnMode, .flatPerVisit)
        XCTAssertEqual(config.pointsPerVisit, 20)
        XCTAssertEqual(config.redemptionThreshold, 100)
    }

    func testCreateRewardTemplatePersistsReward() async throws {
        let service = LoyaltyService(modelContainer: container)

        try await service.createRewardTemplate(
            title: "Free Nail Trim",
            detail: "Redeem after five visits.",
            pointCost: 100,
            systemImage: "scissors",
            style: .care
        )

        let rewards = try container.mainContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>())
        XCTAssertTrue(rewards.contains { $0.title == "Free Nail Trim" && $0.pointCost == 100 })
    }

    func testCreateRewardTemplateRejectsInvalidCost() async throws {
        let service = LoyaltyService(modelContainer: container)

        do {
            try await service.createRewardTemplate(
                title: "Bad Reward",
                detail: "Invalid",
                pointCost: 0,
                systemImage: "gift.fill",
                style: .credit
            )
            XCTFail("Zero-cost rewards must be rejected.")
        } catch let error as AppError {
            guard case .validation = error else {
                return XCTFail("Expected validation error, got \(error).")
            }
        }
    }
}
```

- [ ] **Step 2: Run service config tests and verify they fail**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyServiceConfigTests
```

Expected: fail because the service methods do not exist.

- [ ] **Step 3: Add service mutation APIs**

Append these methods to `Pawtrackr/Features/Loyalty/LoyaltyService.swift` inside the actor:

```swift
func updateConfig(
    earnMode: LoyaltyEarnMode,
    pointsPerDollar: Decimal,
    pointsPerVisit: Int,
    redemptionThreshold: Int,
    isRewardsCatalogEnabled: Bool
) throws {
    guard pointsPerDollar >= .zero else {
        throw AppError.validation(.custom(message: "Points per dollar cannot be negative."))
    }
    guard pointsPerVisit >= 0 else {
        throw AppError.validation(.custom(message: "Points per visit cannot be negative."))
    }
    guard redemptionThreshold > 0 else {
        throw AppError.validation(.custom(message: "Reward threshold must be greater than zero."))
    }

    let config = try fetchOrCreateConfig()
    config.setEarnMode(earnMode)
    config.setPointsPerDollar(pointsPerDollar)
    config.setPointsPerVisit(pointsPerVisit)
    config.setRedemptionThreshold(redemptionThreshold)
    config.setRewardsCatalogEnabled(isRewardsCatalogEnabled)
    try modelContext.save()
}

func createRewardTemplate(
    title: String,
    detail: String,
    pointCost: Int,
    systemImage: String,
    style: LoyaltyReward.Style
) throws {
    guard pointCost > 0 else {
        throw AppError.validation(.custom(message: "Reward cost must be greater than zero."))
    }
    let nextOrder = ((try? modelContext.fetch(FetchDescriptor<LoyaltyRewardTemplate>()).map(\.sortOrder).max()) ?? -1) + 1
    let reward = LoyaltyRewardTemplate(
        title: title,
        detail: detail,
        pointCost: pointCost,
        systemImage: systemImage,
        styleRaw: style.rawValue,
        sortOrder: nextOrder
    )
    modelContext.insert(reward)
    try modelContext.save()
}

func setRewardTemplate(_ reward: LoyaltyRewardTemplate, isEnabled: Bool) throws {
    reward.setEnabled(isEnabled)
    try modelContext.save()
}

private func fetchOrCreateConfig() throws -> LoyaltyConfig {
    var descriptor = FetchDescriptor<LoyaltyConfig>(
        sortBy: [SortDescriptor(\.createdAt, order: .forward)]
    )
    descriptor.fetchLimit = 1
    if let existing = try modelContext.fetch(descriptor).first {
        return existing
    }
    let config = LoyaltyConfig()
    modelContext.insert(config)
    return config
}
```

- [ ] **Step 4: Run service config tests and verify they pass**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyServiceConfigTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Pawtrackr/Features/Loyalty/LoyaltyService.swift PawtrackrTests/LoyaltyServiceConfigTests.swift
git commit -m "feat(loyalty): add config reward service APIs"
```

---

### Task 5: Add Loyalty Management UI In Settings

**Files:**
- Create: `Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift`
- Modify: `Pawtrackr/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Add the settings section case**

In `Pawtrackr/Features/Settings/SettingsView.swift`, add `loyalty` to `SettingSection`:

```swift
enum SettingSection: String, CaseIterable, Identifiable {
    case business, preferences, loyalty, security, dataExport, icloud, help, devices, about
```

Add the switch cases:

```swift
case .loyalty: return "settings.section.loyalty"
```

```swift
case .loyalty: return "star.circle.fill"
```

```swift
case .preferences, .loyalty, .help, .devices:
    return nil
```

In `SettingsDetailView.content`, add:

```swift
case .loyalty: LoyaltyManagementView()
```

- [ ] **Step 2: Create the loyalty management view**

Create `Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift`:

```swift
import SwiftData
import SwiftUI

@MainActor
struct LoyaltyManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoyaltyConfig.createdAt, order: .forward) private var configs: [LoyaltyConfig]
    @Query(sort: \LoyaltyRewardTemplate.sortOrder, order: .forward) private var rewards: [LoyaltyRewardTemplate]

    @State private var errorMessage: String?
    @State private var newRewardTitle = ""
    @State private var newRewardCost = 100

    private var config: LoyaltyConfig? { configs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardView {
                Text("Loyalty Earning Rules")
                    .font(.headline)
                Picker("Earning Mode", selection: earnModeBinding) {
                    Text("Points per dollar").tag(LoyaltyEarnMode.pointsPerDollar)
                    Text("Flat points per visit").tag(LoyaltyEarnMode.flatPerVisit)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("loyaltySettings.earnMode")

                Stepper(value: pointsPerVisitBinding, in: 0...500, step: 5) {
                    Text("Flat visit points: \(config?.pointsPerVisit ?? 20)")
                }

                Stepper(value: thresholdBinding, in: 1...10_000, step: 25) {
                    Text("Reward threshold: \(config?.redemptionThreshold ?? 100)")
                }
            }

            CardView {
                Text("Rewards Catalog")
                    .font(.headline)
                ForEach(rewards) { reward in
                    Toggle(isOn: enabledBinding(for: reward)) {
                        VStack(alignment: .leading) {
                            Text(reward.title)
                                .font(.subheadline.weight(.semibold))
                            Text("\(reward.pointCost) points")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                TextField("Reward title", text: $newRewardTitle)
                    .textFieldStyle(.roundedBorder)
                Stepper(value: $newRewardCost, in: 1...10_000, step: 25) {
                    Text("Cost: \(newRewardCost) points")
                }
                Button {
                    createReward()
                } label: {
                    Label("Add Reward", systemImage: "plus.circle.fill")
                }
                .disabled(newRewardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            DataMigrations.ensureLoyaltyDefaults(in: modelContext)
        }
    }

    private var earnModeBinding: Binding<LoyaltyEarnMode> {
        Binding {
            config?.earnMode ?? .pointsPerDollar
        } set: { mode in
            updateConfig(earnMode: mode)
        }
    }

    private var pointsPerVisitBinding: Binding<Int> {
        Binding {
            config?.pointsPerVisit ?? 20
        } set: { value in
            updateConfig(pointsPerVisit: value)
        }
    }

    private var thresholdBinding: Binding<Int> {
        Binding {
            config?.redemptionThreshold ?? 100
        } set: { value in
            updateConfig(redemptionThreshold: value)
        }
    }

    private func enabledBinding(for reward: LoyaltyRewardTemplate) -> Binding<Bool> {
        Binding {
            reward.isEnabled
        } set: { enabled in
            Task { await mutate { try $0.setRewardTemplate(reward, isEnabled: enabled) } }
        }
    }

    private func updateConfig(
        earnMode: LoyaltyEarnMode? = nil,
        pointsPerVisit: Int? = nil,
        redemptionThreshold: Int? = nil
    ) {
        Task {
            await mutate { service in
                try service.updateConfig(
                    earnMode: earnMode ?? config?.earnMode ?? .pointsPerDollar,
                    pointsPerDollar: config?.pointsPerDollar ?? Decimal(1),
                    pointsPerVisit: pointsPerVisit ?? config?.pointsPerVisit ?? 20,
                    redemptionThreshold: redemptionThreshold ?? config?.redemptionThreshold ?? 100,
                    isRewardsCatalogEnabled: config?.isRewardsCatalogEnabled ?? true
                )
            }
        }
    }

    private func createReward() {
        let title = newRewardTitle
        let cost = newRewardCost
        Task {
            await mutate { service in
                try service.createRewardTemplate(
                    title: title,
                    detail: "Custom loyalty reward.",
                    pointCost: cost,
                    systemImage: "gift.fill",
                    style: .credit
                )
            }
            newRewardTitle = ""
            newRewardCost = 100
        }
    }

    private func mutate(_ operation: @escaping (LoyaltyService) throws -> Void) async {
        do {
            let service = LoyaltyService(modelContainer: modelContext.container)
            try await operation(service)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Build focused target**

Run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4'
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Pawtrackr/Features/Loyalty/LoyaltyManagementView.swift Pawtrackr/Features/Settings/SettingsView.swift
git commit -m "feat(loyalty): add loyalty management settings"
```

---

### Task 6: Use Persistent Rewards In The Client Catalog

**Files:**
- Modify: `Pawtrackr/Features/Loyalty/RewardsCatalogView.swift`
- Modify: `PawtrackrTests/LoyaltyRewardCatalogTests.swift`

- [ ] **Step 1: Add reward-template display test**

Append this test to `PawtrackrTests/LoyaltyRewardCatalogTests.swift`:

```swift
func testTemplateDisplayRewardKeepsRedeemabilityRules() {
    let template = LoyaltyRewardTemplate(
        title: "$10 Credit",
        detail: "Apply at checkout.",
        pointCost: 100,
        systemImage: "ticket.fill",
        styleRaw: LoyaltyReward.Style.credit.rawValue,
        sortOrder: 0
    )

    let reward = template.displayReward

    XCTAssertFalse(reward.isRedeemable(with: 99))
    XCTAssertTrue(reward.isRedeemable(with: 100))
}
```

- [ ] **Step 2: Run reward catalog tests**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyRewardCatalogTests
```

Expected: `** TEST SUCCEEDED **` after Task 1 has added `displayReward`.

- [ ] **Step 3: Query persistent rewards in `RewardsCatalogView`**

At the top of `RewardsCatalogView`, add:

```swift
@Query(
    filter: #Predicate<LoyaltyRewardTemplate> { $0.isEnabled == true },
    sort: \LoyaltyRewardTemplate.sortOrder,
    order: .forward
) private var rewardTemplates: [LoyaltyRewardTemplate]

private var visibleRewards: [LoyaltyReward] {
    let persistent = rewardTemplates.map(\.displayReward)
    return persistent.isEmpty ? LoyaltyReward.builtInCatalog : persistent
}
```

Replace:

```swift
ForEach(LoyaltyReward.builtInCatalog) { reward in
    rewardRow(reward)
}
```

with:

```swift
ForEach(visibleRewards) { reward in
    rewardRow(reward)
}
```

- [ ] **Step 4: Run reward and loyalty UI tests**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyRewardCatalogTests \
  -only-testing:PawtrackrUITests/LoyaltyUITests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Pawtrackr/Features/Loyalty/RewardsCatalogView.swift PawtrackrTests/LoyaltyRewardCatalogTests.swift
git commit -m "feat(loyalty): use persistent reward templates"
```

---

### Task 7: Add Detached Client, Loyalty, And Insights Windows

**Files:**
- Create: `Pawtrackr/App/ProWindows/DetachedClientWindow.swift`
- Create: `Pawtrackr/App/ProWindows/DetachedInsightsWindow.swift`
- Modify: `Pawtrackr/App/PawtrackrApp.swift`
- Modify: `Pawtrackr/Features/Clients/ClientDetailView.swift`
- Modify: `Pawtrackr/Features/Clients/ClientsView.swift`
- Modify: `Pawtrackr/App/MenuBarExtra.swift` (macOS only)

- [ ] **Step 1: Create detached client window view**

Create `Pawtrackr/App/ProWindows/DetachedClientWindow.swift`:

```swift
import SwiftData
import SwiftUI

enum DetachedClientWindowMode: String, Codable, Hashable, Sendable {
    case detail
    case loyalty
}

struct DetachedClientWindowRoute: Codable, Hashable, Sendable {
    let clientUUID: UUID
    let mode: DetachedClientWindowMode
}

struct DetachedClientWindow: View {
    @Environment(\.modelContext) private var modelContext
    @Namespace private var namespace
    let route: DetachedClientWindowRoute

    var body: some View {
        NavigationStack {
            if let client {
                switch route.mode {
                case .detail:
                    ClientDetailView(client: client, namespace: namespace)
                case .loyalty:
                    ClientLoyaltyView(client: client)
                }
            } else {
                ContentUnavailableView(
                    "Client Unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("This client was deleted or is not available on this device yet.")
                )
            }
        }
        .frame(minWidth: 520, minHeight: 520)
    }

    private var client: Client? {
        var descriptor = FetchDescriptor<Client>(
            predicate: #Predicate<Client> { $0.uuid == route.clientUUID }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
```

- [ ] **Step 2: Create detached insights window view**

Create `Pawtrackr/App/ProWindows/DetachedInsightsWindow.swift`:

```swift
import SwiftUI

struct DetachedInsightsWindow: View {
    var body: some View {
        NavigationStack {
            InsightsView()
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}
```

- [ ] **Step 3: Add Mac/iPad window scenes**

In `Pawtrackr/App/PawtrackrApp.swift`, add these scenes inside `body` after the main `WindowGroup`:

```swift
#if os(macOS) || os(iOS)
WindowGroup("Client", id: "client-window", for: DetachedClientWindowRoute.self) { route in
    if let container, let route = route.wrappedValue {
        DetachedClientWindow(route: route)
            .environment(\.locale, customLocale)
            .environment(appSettings)
            .environment(authViewModel)
            .environment(dataStore)
            .environment(router)
            .environment(eventBus)
            .environment(entitlements)
            .modelContainer(container)
    } else {
        ContentUnavailableView("Client Unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
    }
}
#if os(macOS)
.defaultSize(width: 760, height: 680)
#endif

WindowGroup("Insights", id: "insights-window") {
    if let container {
        DetachedInsightsWindow()
            .environment(\.locale, customLocale)
            .environment(appSettings)
            .environment(authViewModel)
            .environment(dataStore)
            .environment(router)
            .environment(eventBus)
            .environment(entitlements)
            .modelContainer(container)
    } else {
        Text(AppLocalization.localized("common.database_unavailable", value: "Database unavailable"))
    }
}
#if os(macOS)
.defaultSize(width: 980, height: 720)
#endif
#endif
```

- [ ] **Step 4: Add Mac/iPad open-window actions to client detail**

In `Pawtrackr/Features/Clients/ClientDetailView.swift`, add:

```swift
@Environment(\.openWindow) private var openWindow
@Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
```

In `navigationContent(vm:)`, update the existing toolbar block:

```swift
.toolbar {
    toolbarContent(vm)
    macAddPetToolbarItem
    proWindowToolbarItems
}
```

Add this toolbar content next to `macAddPetToolbarItem`:

```swift
@ToolbarContentBuilder
private var proWindowToolbarItems: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
        if supportsMultipleWindows {
            Button {
                openWindow(id: "client-window", value: DetachedClientWindowRoute(clientUUID: client.uuid, mode: .detail))
            } label: {
                Label("Open Client Window", systemImage: "rectangle.on.rectangle")
            }
            Button {
                openWindow(id: "client-window", value: DetachedClientWindowRoute(clientUUID: client.uuid, mode: .loyalty))
            } label: {
                Label("Open Loyalty Window", systemImage: "star.circle")
            }
        }
    }
}
```

- [ ] **Step 5: Add Mac/iPad context-menu actions to client cards**

In `Pawtrackr/Features/Clients/ClientsView.swift`, add these environment values beside the existing router/context values:

```swift
@Environment(\.openWindow) private var openWindow
@Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
```

In `clientList(for:isInProgress:enableInfiniteScroll:)`, add these buttons inside the existing `.contextMenu` immediately after "View Details" and before the UIKit call/message/email actions:

```swift
if supportsMultipleWindows {
    Button {
        openWindow(id: "client-window", value: DetachedClientWindowRoute(clientUUID: client.uuid, mode: .detail))
    } label: {
        Label("Open Client Window", systemImage: "rectangle.on.rectangle")
    }

    Button {
        openWindow(id: "client-window", value: DetachedClientWindowRoute(clientUUID: client.uuid, mode: .loyalty))
    } label: {
        Label("Open Loyalty Window", systemImage: "star.circle")
    }
}
```

- [ ] **Step 6: Add macOS menu bar insights action**

In `Pawtrackr/App/MenuBarExtra.swift`, add a button before "Open Main Window":

```swift
Button("Open Insights") {
    openWindow(id: "insights-window")
    NSApp.activate(ignoringOtherApps: true)
}
```

- [ ] **Step 7: Build macOS and iOS simulator targets**

Run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PawtrackrMacDerivedData
```

Then run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -derivedDataPath /tmp/PawtrackrIOSDerivedData
```

Expected: both builds report `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Pawtrackr/App/ProWindows/DetachedClientWindow.swift \
        Pawtrackr/App/ProWindows/DetachedInsightsWindow.swift \
        Pawtrackr/App/PawtrackrApp.swift \
        Pawtrackr/Features/Clients/ClientDetailView.swift \
        Pawtrackr/Features/Clients/ClientsView.swift \
        Pawtrackr/App/MenuBarExtra.swift
git commit -m "feat(pro): add detached workflow windows"
```

---

### Task 8: Add Insights Scrubber Readouts

**Files:**
- Modify: `Pawtrackr/Features/Insights/InsightsView.swift`

- [ ] **Step 1: Add selected revenue state**

In `InsightsView`, add state next to `selectedDrilldown`:

```swift
@State private var selectedRevenueDate: Date?
```

- [ ] **Step 2: Add helper for selected revenue point**

Add this helper inside `InsightsView`:

```swift
private func selectedRevenuePoint(in vm: InsightsViewModel) -> InsightsViewModel.RevenueData? {
    guard let selectedRevenueDate else { return nil }
    let calendar = Calendar.current
    return vm.revenueSeries.first { calendar.isDate($0.date, inSameDayAs: selectedRevenueDate) }
}
```

- [ ] **Step 3: Add chart selection and visible metric**

In `revenueCard(_:)`, add a selected readout above the chart:

```swift
if let selected = selectedRevenuePoint(in: vm) {
    Text("\(selected.date.formatted(.dateTime.weekday(.wide))): \(selected.amount.moneyString)")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(DS.ColorToken.primary)
        .transition(.opacity)
}
```

On the `Chart`, add:

```swift
.chartXSelection(value: $selectedRevenueDate)
.animation(.spring(response: 0.35, dampingFraction: 0.82), value: selectedRevenueDate)
```

- [ ] **Step 4: Build iOS and macOS targets**

Run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4'
```

Expected: `** BUILD SUCCEEDED **`.

Run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PawtrackrMacDerivedData
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Pawtrackr/Features/Insights/InsightsView.swift
git commit -m "feat(insights): add revenue scrubber readout"
```

---

### Task 9: Add Focused UI Coverage

**Files:**
- Create: `PawtrackrUITests/ProWorkflowUITests.swift`

- [ ] **Step 1: Create UI tests for the pro workflow surfaces**

Create `PawtrackrUITests/ProWorkflowUITests.swift`:

```swift
import XCTest

@MainActor
final class ProWorkflowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "-pawtrackr-ui-testing",
            "--mock-storekit-premium",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["PAWTRACKR_UI_TESTING"] = "1"
        app.launchEnvironment["PAWTRACKR_UI_TESTING_PREMIUM"] = "1"
    }

    func testSettingsShowsLoyaltySection() throws {
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        if settingsTab.waitForExistence(timeout: 6) {
            settingsTab.tap()
        } else {
            app.buttons["sidebar.row.settings"].tap()
        }

        XCTAssertTrue(app.staticTexts["Loyalty"].waitForExistence(timeout: 8))
    }

    func testInsightsScreenStillLoads() throws {
        app.launch()

        let insightsTab = app.tabBars.buttons["Insights"]
        if insightsTab.waitForExistence(timeout: 6) {
            insightsTab.tap()
        } else {
            app.buttons["sidebar.row.insights"].tap()
        }

        XCTAssertTrue(
            app.staticTexts["Insights"].waitForExistence(timeout: 8)
            || app.navigationBars["Insights"].waitForExistence(timeout: 8)
        )
    }
}
```

- [ ] **Step 2: Run the focused UI tests**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrUITests/ProWorkflowUITests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add PawtrackrUITests/ProWorkflowUITests.swift
git commit -m "test: cover loyalty and pro workflow navigation"
```

---

### Task 10: Final Verification, Review, And Handoff

**Files:**
- No source changes unless verification exposes a failure.

- [ ] **Step 1: Run whitespace check**

Run:

```bash
git diff --check
```

Expected: exit 0 with no output.

- [ ] **Step 2: Run focused loyalty tests**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrTests/LoyaltyConfigTests \
  -only-testing:PawtrackrTests/LoyaltyServiceTests \
  -only-testing:PawtrackrTests/LoyaltyServiceConfigTests \
  -only-testing:PawtrackrTests/LoyaltyRewardCatalogTests \
  -only-testing:PawtrackrTests/MigrationsTests \
  -only-testing:PawtrackrTests/CheckoutFlowTests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Run focused UI tests**

Run:

```bash
xcodebuild test \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.4' \
  -only-testing:PawtrackrUITests/LoyaltyUITests \
  -only-testing:PawtrackrUITests/ProWorkflowUITests
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Run macOS build**

Run:

```bash
xcodebuild build \
  -project Pawtrackr.xcodeproj \
  -scheme Pawtrackr \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/PawtrackrMacDerivedData
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run CodeRabbit review**

Run:

```bash
coderabbit --version
coderabbit auth status --agent
coderabbit review --agent -t uncommitted
```

Expected: CodeRabbit returns zero critical or major issues, or issues are fixed in follow-up
commits before completion.

- [ ] **Step 6: Security review checklist**

Inspect the final diff for these invariants:

```bash
git diff --check
rg -n "@Attribute\\(\\.unique\\)|Double\\(|Float\\(" Pawtrackr/Core/Storage/Models Pawtrackr/Features/Loyalty Pawtrackr/Features/Checkout
rg -n "try\\?|print\\(" Pawtrackr/Features/Loyalty Pawtrackr/Core/Storage/Migrations.swift
```

Expected:

- no unique SwiftData attributes in new loyalty models
- no new `Double` or `Float` money math in loyalty or checkout code
- no new `print()` calls
- any `try?` that remains is pre-existing or intentionally non-critical and documented in final notes

- [ ] **Step 7: Confirm final git status**

Run:

```bash
git status --short --branch
```

Expected: the branch contains only intentional committed feature work and no uncommitted changes.
