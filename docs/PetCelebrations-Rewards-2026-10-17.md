# Pet celebrations and points-only rewards — October 17, 2026

## Behavior

- A known pet birthdate takes priority. On that calendar day, the pet card shows a birthday boy/girl message, the pet’s name, and the age being celebrated. Unrecognized legacy gender values receive neutral birthday wording.
- When the birthdate is unknown, the card celebrates the client relationship after at least one year. The anchor is the earliest stored client registration, this pet’s registration, or a completed visit belonging to one of the client’s pets. Unfinished visits, future completions, and visits ending before they started do not establish tenure.
- Client anniversaries thank the client’s family and describe years with the salon. They never populate a birthdate or infer the pet’s age. February 29 is observed on February 28 in non-leap years, including the first anniversary. Calendar matching uses the local day; the presentation refreshes once a minute across midnight.
- Celebrations use a short, replayable confetti burst. Birthday colors follow the existing male/female palette; client anniversaries use a warm orange accent.
- Rewards now present the points balance, the next reward, and visit/redemption history. Bronze, Silver, Gold and Platinum labels and tier explanations have been removed from rewards, checkout, loyalty Settings, and Academy guidance.
- The reward bar has a blue-to-cyan fill, a traveling light sweep, and a pulsing sparkle or gift at the progress edge. Balance changes move the fill; resuming the app does not reset it to zero. A native progress accessibility representation announces the reward and point count.

## Motion and data safety

Decorations run only while the view is visible in its scroll surface, the scene is active, Reduce Motion is off, Low Power Mode is off, and the thermal state is nominal/fair. The static presentation retains the same text and progress. Confetti stops after two seconds, can be replayed, and cannot intercept neighboring controls.

No persisted model fields, migration plans, stored enum attributes, reward prices, earning rules, balances, or ledger history were changed. Completed, settled visits still earn 20 points. Legacy tier calculations remain internal for compatibility and have no displayed membership status.

Celebration screen fixtures are DEBUG-only, explicitly opted into UI automation, and use the existing disposable in-memory UI store. Normal launches and real client records are unaffected.

## Verification

- **43 focused unit tests passed.** Suites: PetMilestoneTests, RewardProgressTests, LoyaltyPreviewTests, AutomaticVisitLoyaltyTests, and MotionGovernorTests.
- **4 native iPhone UI tests passed** on iPhone 18 Pro / iOS 27. Scenarios: birthday boy, birthday girl and replay, unknown-birthday client anniversary, points-only rewards, and the all-rewards-unlocked balance.
- **macOS build passed** for the existing Pawtrackr scheme. Desktop navigation and grid layouts were not changed.
- **Passed:** local persistence/schema pre-build gates, localization plist validation for English/Spanish/Latin American Spanish, and SwiftLint regression comparison (**0 introduced findings**).
- CodeRabbit review findings were corrected; its subsequent review reported no remaining findings. The native accessibility control and identifier behavior were then validated by the passing screen tests.
- Unit evidence: `/tmp/pawtrackr-celebration-final.xcresult`; accepted UI evidence: `/tmp/pawtrackr-celebration-ready.xcresult`. The checks use simulated/in-memory records, not real client data.

The checks caught and corrected two animation lifecycle problems: refill on motion-policy changes and a replay task attached to an empty Group. Native UI checks also exposed an inaccessible custom progress element; the final control supplies standard progress semantics. The UI automation taps the client name to avoid the nested status control, and uses the actual rendered accessibility role of the celebration banner.
