import XCTest
@testable import Pawtrackr

final class BehaviorTagIconsTests: XCTestCase {
    func testSharedColorMappingMatchesEachBehavior() {
        XCTAssertEqual(BehaviorTagIcons.tint(for: .calm), DS.ColorToken.success)
        XCTAssertEqual(BehaviorTagIcons.tint(for: .cooperative), DS.ColorToken.success)
        XCTAssertEqual(BehaviorTagIcons.tint(for: .anxious), DS.ColorToken.anxious)
        XCTAssertEqual(BehaviorTagIcons.tint(for: .nervous), DS.ColorToken.info)
        XCTAssertEqual(BehaviorTagIcons.tint(for: .aggressive), DS.ColorToken.danger)
        XCTAssertEqual(BehaviorTagIcons.tint(for: .specialNeeds), DS.ColorToken.specialCare)
    }
    
    func testDisplay_ReturnsCorrectEmojiAndLabel() {
        let calm = BehaviorTagIcons.display(for: "Calm")
        XCTAssertEqual(calm.emoji, "🧘")
        XCTAssertEqual(calm.label, "Calm")
        
        let aggressive = BehaviorTagIcons.display(for: "aggressive")
        XCTAssertEqual(aggressive.emoji, "🛑")
        XCTAssertEqual(aggressive.label, "Aggressive")
        
        let puppy = BehaviorTagIcons.display(for: " Puppy ")
        XCTAssertEqual(puppy.emoji, "🐶")
        XCTAssertEqual(puppy.label, "Puppy / Young")
    }

    func testDisplay_RecognizesLocalizedSpanishStandardTags() {
        let calm = BehaviorTagIcons.display(for: "Tranquilo")
        XCTAssertEqual(calm.emoji, "🧘")
        XCTAssertEqual(calm.label, "Calm")

        let cooperative = BehaviorTagIcons.display(for: "Cooperativo")
        XCTAssertEqual(cooperative.emoji, "🤝")
        XCTAssertEqual(cooperative.label, "Cooperative")

        let specialNeeds = BehaviorTagIcons.display(for: "Necesidades especiales")
        XCTAssertEqual(specialNeeds.emoji, "❤️‍🩹")
        XCTAssertEqual(specialNeeds.label, "Special Needs")
    }
    
    func testDisplay_Fallback_ReturnsTitleCase() {
        let unknown = BehaviorTagIcons.display(for: "likes belly rubs")
        XCTAssertNil(unknown.emoji)
        XCTAssertEqual(unknown.label, "Likes Belly Rubs")
    }
}
