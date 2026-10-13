import XCTest
@testable import Pawtrackr

@MainActor
final class NavigationRouterTests: XCTestCase {
    func testRapidCardTapsAppendOncePerTab() {
        let router = NavigationRouter()
        let client = Client(firstName: "Card", lastName: "Test")
        router.activeNavigationItem = .clients
        router.navigateToClientFromCard(client)
        router.navigateToClientFromCard(client)
        XCTAssertEqual(router.clientsPath.count, 1)
        router.activeNavigationItem = .dashboard
        router.navigateToClientFromCard(client)
        XCTAssertEqual(router.dashboardPath.count, 1)
    }

    func testProgrammaticNavigationBypassesCardCooldown() {
        let router = NavigationRouter()
        let client = Client(firstName: "Route", lastName: "Test")
        router.activeNavigationItem = .clients
        router.navigateToClientFromCard(client)
        router.navigateToClient(client)
        router.navigateToClientLoyalty(client)
        XCTAssertEqual(router.clientsPath.count, 3)
    }
}
