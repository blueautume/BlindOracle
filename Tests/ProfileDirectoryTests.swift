import XCTest
@testable import BlindOracle

enum EnglishDistrictBirthFixtures {
    struct Scenario {
        let date: String
        let clock: String
        let place: String
        let expectedDate: String
        let expectedClock: String
        let canonicalPlace: String
        let districtCode: String

        var question: String {
            "Please use BaZi to explore my career strengths. My name is Alex Chen, and I’m male. I was born on \(date), at \(clock) in \(place), China."
        }
    }

    static let scenarios: [Scenario] = [
        .init(date: "June 15, 1995", clock: "9:30 a.m.", place: "Xuhui District, Shanghai",
              expectedDate: "1995-06-15", expectedClock: "09:30", canonicalPlace: "上海市徐汇区", districtCode: "310104"),
        .init(date: "15 June 1995", clock: "8:45 PM", place: "Chaoyang District, Beijing",
              expectedDate: "1995-06-15", expectedClock: "20:45", canonicalPlace: "北京市朝阳区", districtCode: "110105"),
        .init(date: "1995-06-15", clock: "14:20", place: "Nanshan District, Shenzhen, Guangdong",
              expectedDate: "1995-06-15", expectedClock: "14:20", canonicalPlace: "广东省深圳市南山区", districtCode: "440305"),
        .init(date: "February 29, 2000", clock: "12 a.m.", place: "Tianhe District, Guangzhou, Guangdong",
              expectedDate: "2000-02-29", expectedClock: "00:00", canonicalPlace: "广东省广州市天河区", districtCode: "440106"),
        .init(date: "15 June 1995", clock: "12 p.m.", place: "Xihu District, Hangzhou, Zhejiang",
              expectedDate: "1995-06-15", expectedClock: "12:00", canonicalPlace: "浙江省杭州市西湖区", districtCode: "330106"),
        .init(date: "1995-06-15", clock: "00:05", place: "Wuhou District, Chengdu, Sichuan",
              expectedDate: "1995-06-15", expectedClock: "00:05", canonicalPlace: "四川省成都市武侯区", districtCode: "510107"),
        .init(date: "Feb 29, 2000", clock: "23:59:30", place: "Chaoyang District, Changchun, Jilin",
              expectedDate: "2000-02-29", expectedClock: "23:59:30", canonicalPlace: "吉林省长春市朝阳区", districtCode: "220104"),
        .init(date: "June 15, 1995", clock: "06:15AM", place: "Pudong New Area, Shanghai",
              expectedDate: "1995-06-15", expectedClock: "06:15", canonicalPlace: "上海市浦东新区", districtCode: "310115"),
        .init(date: "June 15, 1995", clock: "noon", place: "Nanshan District, Shenzhen",
              expectedDate: "1995-06-15", expectedClock: "12:00", canonicalPlace: "广东省深圳市南山区", districtCode: "440305"),
        .init(date: "June 15, 1995", clock: "midnight", place: "Xuhui District, Shanghai",
              expectedDate: "1995-06-15", expectedClock: "00:00", canonicalPlace: "上海市徐汇区", districtCode: "310104")
    ]
}

final class ProfileDirectoryTests: XCTestCase {
    func testEnglishDistrictAndClockMatrixPreservesTheCompleteBirthplace() throws {
        for scenario in EnglishDistrictBirthFixtures.scenarios {
            let updates = ProfileDirectory.parseExplicitUpdates(in: scenario.question, profiles: [])
            XCTAssertEqual(updates.count, 1, scenario.question)
            let update = try XCTUnwrap(updates.first, scenario.question)
            XCTAssertEqual(update.birthDate, scenario.expectedDate, scenario.question)
            XCTAssertEqual(update.birthTime, scenario.expectedClock, scenario.question)
            let place = try XCTUnwrap(update.birthPlace, scenario.question)
            for component in scenario.place.components(separatedBy: ", ") {
                XCTAssertTrue(place.contains(component), "Missing \(component) in \(place)")
            }

            let result = ProfileDirectory.applying(updates, to: [])
            XCTAssertTrue(result.issues.isEmpty, scenario.question)
            let profile = try XCTUnwrap(result.profiles.first, scenario.question)
            XCTAssertEqual(profile.birthPlace, scenario.canonicalPlace, scenario.question)
            XCTAssertEqual(profile.birthDistrictCode, scenario.districtCode, scenario.question)
            XCTAssertEqual(profile.birthDateText, scenario.expectedDate, scenario.question)
            XCTAssertEqual(profile.birthTimeText, scenario.expectedClock, scenario.question)
            XCTAssertTrue(profile.birthTimeKnown, scenario.question)
            XCTAssertTrue(profile.currentPlace.isEmpty, "A birthplace does not establish a current location.")
        }
    }

    func testEnglishDistrictGroundingPreservesSpecificityAndUsesOnlyCatalogCoordinates() throws {
        let scenario = try XCTUnwrap(EnglishDistrictBirthFixtures.scenarios.first { $0.districtCode == "440305" })
        let parsed = ProfileDirectory.parseExplicitUpdates(in: scenario.question, profiles: [])
        let profile = try XCTUnwrap(ProfileDirectory.applying(parsed, to: []).profiles.first)
        let catalog = ChinaDistrictCatalog.shared
        let guangdong = try XCTUnwrap(catalog.provinces.first { $0.id == "440000" })
        let shenzhen = try XCTUnwrap(catalog.children(of: guangdong).first { $0.id == "440300" })
        let nanshan = try XCTUnwrap(catalog.children(of: shenzhen).first { $0.id == "440305" })
        XCTAssertNotNil(nanshan.latitude)
        XCTAssertNotNil(nanshan.longitude)
        XCTAssertEqual(profile.birthLatitude, nanshan.latitude)
        XCTAssertEqual(profile.birthLongitude, nanshan.longitude)

        for (place, accepted) in [("Shenzhen", true), ("广东省深圳市南山区", true), ("Chaoyang District, Beijing", false)] {
            let proposed = ProfileUpdate(id: profile.id, name: "Alex Chen", birthPlace: place,
                                         birthLatitude: 39.9, birthLongitude: 116.4)
            let grounded = ProfileDirectory.groundedUpdates([proposed], in: scenario.question, profiles: [profile])
            XCTAssertEqual(grounded.first?.birthPlace, accepted ? scenario.canonicalPlace : nil, place)
            XCTAssertTrue(grounded.allSatisfy { $0.birthLatitude == nil && $0.birthLongitude == nil },
                          "The message did not supply the model-proposed coordinates.")
            let updated = try XCTUnwrap(ProfileDirectory.applying(grounded, to: [profile]).profiles.first)
            XCTAssertEqual(updated.birthDistrictCode, "440305", place)
            XCTAssertEqual(updated.birthPlace, "广东省深圳市南山区", place)
            XCTAssertEqual(updated.birthLatitude, nanshan.latitude, place)
            XCTAssertEqual(updated.birthLongitude, nanshan.longitude, place)
            XCTAssertEqual(updated.birthDateText, scenario.expectedDate, place)
            XCTAssertEqual(updated.birthTimeText, scenario.expectedClock, place)
            XCTAssertTrue(updated.currentPlace.isEmpty, place)
            XCTAssertNil(updated.currentDistrictCode, place)
            XCTAssertNil(updated.currentLatitude, place)
            XCTAssertNil(updated.currentLongitude, place)
        }
    }

    func testEnglishDistrictGroundingDoesNotDiscardConflictingCountryOrProvinceQualifiers() throws {
        let scenarios = [
            (original: "Nanshan District, Shenzhen, Guangdong, Japan", proposed: "Nanshan District, Shenzhen, Guangdong", qualifier: "Japan"),
            (original: "Chaoyang District, Beijing, Jilin", proposed: "Chaoyang District, Beijing", qualifier: "Jilin"),
            (original: "Nanshan District, Shenzhen, Guangdong, China, Japan", proposed: "Nanshan District, Shenzhen, Guangdong, China", qualifier: "Japan")
        ]
        for scenario in scenarios {
            let question = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 a.m. in \(scenario.original)."
            let parsed = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
            let original = try XCTUnwrap(parsed.first { $0.name == "Alex Chen" }, question)
            if let place = original.birthPlace {
                XCTAssertTrue(place.contains(scenario.qualifier), "An invalid qualifier must not be silently discarded: \(question)")
            }
            let profile = try XCTUnwrap(ProfileDirectory.applying(parsed, to: []).profiles.first { $0.resolvedName == "Alex Chen" })
            XCTAssertNil(profile.birthDistrictCode, question)
            XCTAssertNil(profile.birthLatitude, question)
            XCTAssertNil(profile.birthLongitude, question)

            let proposed = ProfileUpdate(id: profile.id, name: "Alex Chen", birthPlace: scenario.proposed)
            let grounded = ProfileDirectory.groundedUpdates([proposed], in: question, profiles: [profile])
            for update in grounded {
                if let place = update.birthPlace {
                    XCTAssertTrue(place.contains(scenario.qualifier), "Grounding must retain the complete supplied location.")
                }
            }
            let updated = try XCTUnwrap(ProfileDirectory.applying(grounded, to: [profile]).profiles.first)
            XCTAssertNil(updated.birthDistrictCode, scenario.proposed)
            XCTAssertNil(updated.birthLatitude, scenario.proposed)
            XCTAssertNil(updated.birthLongitude, scenario.proposed)
        }
    }

    func testEnglishRelativesLabeledBirthFactsAreNotAppliedToTheSpeaker() throws {
        let relativesFacts = [
            "My brother's birthplace: Nanshan District, Shenzhen, Guangdong, China.",
            "My brother’s birthplace: Nanshan District, Shenzhen, Guangdong, China, birth time: 8:45 PM, sex: male.",
            "My brother's birth time: 8:45 PM, sex: male, birthplace: Nanshan District, Shenzhen, Guangdong, China."
        ]
        for facts in relativesFacts {
            let question = "My name is Alex Chen. I was born on June 15, 1995. " + facts
            let parsed = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
            let alex = try XCTUnwrap(parsed.first { $0.name == "Alex Chen" }, question)
            XCTAssertEqual(alex.birthDate, "1995-06-15", question)
            XCTAssertNil(alex.sex, question)
            XCTAssertNil(alex.birthTime, question)
            XCTAssertNil(alex.birthPlace, question)
            let profile = try XCTUnwrap(ProfileDirectory.applying(parsed, to: []).profiles.first { $0.resolvedName == "Alex Chen" })
            XCTAssertNil(profile.birthDistrictCode, question)
            XCTAssertNil(profile.birthLatitude, question)
            XCTAssertNil(profile.birthLongitude, question)
            let wrongOwner = ProfileUpdate(id: profile.id, name: "Alex Chen", sex: "male", birthTime: "20:45",
                                           birthPlace: "广东省深圳市南山区")
            let grounded = ProfileDirectory.groundedUpdates([wrongOwner], in: question, profiles: [profile])
            XCTAssertTrue(grounded.allSatisfy { $0.sex == nil && $0.birthTime == nil && $0.birthPlace == nil }, question)
            let updated = try XCTUnwrap(ProfileDirectory.applying(grounded, to: [profile]).profiles.first)
            XCTAssertEqual(updated.birthDateText, "1995-06-15", question)
            XCTAssertFalse(updated.birthTimeKnown, question)
            XCTAssertTrue(updated.birthPlace.isEmpty, question)
            XCTAssertNil(updated.birthDistrictCode, question)
            XCTAssertNil(updated.birthLatitude, question)
            XCTAssertNil(updated.birthLongitude, question)
        }
    }

    func testEnglishDistrictPrefillKeepsAmbiguousAndContradictoryLocationsUnresolved() throws {
        for place in ["Chaoyang District", "Nanshan District, Beijing", "Xuhui District, Beijing"] {
            let question = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 a.m. in \(place), China."
            let updates = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
            let profile = try XCTUnwrap(ProfileDirectory.applying(updates, to: []).profiles.first, question)
            XCTAssertNil(profile.birthDistrictCode, question)
            for component in place.components(separatedBy: ", ") {
                XCTAssertTrue(profile.birthPlace.contains(component), question)
            }
        }

        for laterLocation in ["I currently live in Beijing.", "I work in Beijing.", "Current location: Beijing."] {
            let question = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 a.m. in Chaoyang District. \(laterLocation)"
            let updates = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
            let profile = try XCTUnwrap(ProfileDirectory.applying(updates, to: []).profiles.first, question)
            XCTAssertTrue(profile.birthPlace.contains("Chaoyang District"), question)
            XCTAssertFalse(profile.birthPlace.contains("Beijing"), question)
            XCTAssertNil(profile.birthDistrictCode, question)
        }
    }

    func testEnglishDistrictPrefillDoesNotAssumeAnAmbiguousTwelveHourClock() throws {
        let question = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 in Xuhui District, Shanghai, China."
        let updates = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(update.birthDate, "1995-06-15")
        XCTAssertNil(update.birthTime)
        let profile = try XCTUnwrap(ProfileDirectory.applying(updates, to: []).profiles.first)
        XCTAssertEqual(profile.birthDistrictCode, "310104")
        XCTAssertNil(profile.birthTimeText)
        XCTAssertFalse(profile.birthTimeKnown)
    }

    func testEnglishCareerQuestionExtractsAndGroundsBirthDetailsBeforeConfirmation() throws {
        let question = "Please use BaZi to explore my career strengths and what kind of work would suit me best. My name is Alex Chen, and I’m male. I was born on June 15, 1995, at 9:30 a.m. in Shanghai, China."
        let updates = ProfileDirectory.parseExplicitUpdates(in: question, profiles: [])
        XCTAssertEqual(updates.count, 1)
        let update = try XCTUnwrap(updates.first)
        XCTAssertEqual(update.name, "Alex Chen")
        XCTAssertEqual(update.sex, "男")
        XCTAssertEqual(update.birthDate, "1995-06-15")
        XCTAssertEqual(update.birthTime, "09:30")
        XCTAssertEqual(update.birthPlace, "Shanghai")
        XCTAssertEqual(ProfileDirectory.explicitSelfName(in: question, profiles: []), "Alex Chen")
        XCTAssertNil(update.birthTimeZoneID, "A default zone is applied by the form, not invented as a user-supplied fact.")
        XCTAssertNil(update.birthLatitude)
        XCTAssertNil(update.birthLongitude)

        let proposed = ProfileUpdate(name: "Alex Chen", sex: "male", birthDate: "1995-06-15", birthTime: "09:30:00",
                                     birthTimeZoneID: "Asia/Shanghai", birthPlace: "Shanghai", birthLatitude: 31.2304, birthLongitude: 121.4737)
        let grounded = try XCTUnwrap(ProfileDirectory.groundedUpdates([proposed], in: question, profiles: []).first)
        XCTAssertEqual(grounded.name, "Alex Chen")
        XCTAssertEqual(grounded.sex, "male")
        XCTAssertEqual(grounded.birthDate, "1995-06-15")
        XCTAssertEqual(grounded.birthTime, "09:30:00")
        XCTAssertEqual(grounded.birthPlace, "Shanghai")
        XCTAssertNil(grounded.birthTimeZoneID)
        XCTAssertNil(grounded.birthLatitude)
        XCTAssertNil(grounded.birthLongitude)
    }

    func testEnglishBirthClockHandlesDottedPeriodsAndNoonAndMidnight() throws {
        for (clock, expected) in [("9:30 a.m.", "09:30"), ("9:30 p.m.", "21:30"), ("12 a.m.", "00:00"), ("12 p.m.", "12:00")] {
            let text = "Please explore my career. My name is Alex Chen. I was born on June 15, 1995, at \(clock) in Shanghai, China."
            let update = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: text, profiles: []).first, clock)
            XCTAssertEqual(update.birthDate, "1995-06-15", clock)
            XCTAssertEqual(update.birthTime, expected, clock)
            XCTAssertEqual(update.birthPlace, "Shanghai", clock)
        }
    }

    func testEnglishLabeledBirthDateRetainsItsFollowingClock() throws {
        let text = "Alex Chen, birth date: June 15, 1995 at 8:30 PM"
        let update = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: text, profiles: []).first)
        XCTAssertEqual(update.name, "Alex Chen")
        XCTAssertEqual(update.birthDate, "1995-06-15")
        XCTAssertEqual(update.birthTime, "20:30")
    }

    func testEnglishMonthMayDoesNotMakeExplicitBirthFieldsUncertain() throws {
        let text = "Alex Chen, birth date: May 15, 1995, birth time: 8:30 PM, birthplace: Xuhui District, Shanghai, China."
        let update = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: text, profiles: []).first)
        XCTAssertEqual(update.birthDate, "1995-05-15")
        XCTAssertEqual(update.birthTime, "20:30")
        let profile = try XCTUnwrap(ProfileDirectory.applying([update], to: []).profiles.first)
        XCTAssertEqual(profile.birthDistrictCode, "310104")
    }

    func testEnglishBirthStatementDoesNotBorrowAnUnnamedFriendsPlace() throws {
        let text = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 a.m.; my friend was born in Beijing."
        let update = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: text, profiles: []).first { $0.name == "Alex Chen" })
        XCTAssertEqual(update.birthDate, "1995-06-15")
        XCTAssertEqual(update.birthTime, "09:30")
        XCTAssertNil(update.birthPlace)
        let proposed = ProfileUpdate(name: "Alex Chen", birthDate: "1995-06-15", birthTime: "09:30", birthPlace: "Beijing")
        let grounded = try XCTUnwrap(ProfileDirectory.groundedUpdates([proposed], in: text, profiles: []).first)
        XCTAssertEqual(grounded.birthDate, "1995-06-15")
        XCTAssertEqual(grounded.birthTime, "09:30")
        XCTAssertNil(grounded.birthPlace)
    }

    func testEnglishSelfGenderAndBirthClausesAreNotStoredForAnotherNamedPerson() throws {
        for (speaker, other) in [("Alex Chen", "Bob Smith"), ("Bob Smith", "Alex Chen")] {
            let text = "My name is \(speaker). \(other), birth date: June 15, 1995. I’m female. I was born on July 20, 1996, at 8:30 p.m. in Beijing."
            let updates = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [])
            let update = try XCTUnwrap(updates.first { $0.name == other })
            XCTAssertEqual(update.birthDate, "1995-06-15", other)
            XCTAssertNil(update.sex, other)
            XCTAssertNil(update.birthTime, other)
            XCTAssertNil(update.birthPlace, other)
            let wrongOwner = ProfileUpdate(name: other, sex: "female", birthDate: "1996-07-20", birthTime: "20:30", birthPlace: "Beijing")
            let grounded = ProfileDirectory.groundedUpdates([wrongOwner], in: text, profiles: [])
            XCTAssertTrue(grounded.allSatisfy {
                $0.sex == nil && $0.birthDate == nil && $0.birthTime == nil && $0.birthPlace == nil
            }, other)
        }
    }

    func testEnglishPrefillDoesNotUseNegatedUncertainOrUnrelatedBirthFacts() throws {
        for fact in [
            "I was not born on June 15, 1995, at 9:30 a.m. in Shanghai, China.",
            "I may have been born on June 15, 1995, at 9:30 a.m. in Shanghai, China.",
            "I have an interview on June 15, 1995, at 9:30 a.m. in Shanghai, China."
        ] {
            let text = "My name is Alex Chen. " + fact
            let updates = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [])
            let update = try XCTUnwrap(updates.first { $0.name == "Alex Chen" }, fact)
            XCTAssertNil(update.birthDate, fact)
            XCTAssertNil(update.birthTime, fact)
            XCTAssertNil(update.birthPlace, fact)
            let proposal = ProfileUpdate(name: "Alex Chen", birthDate: "1995-06-15", birthTime: "09:30", birthPlace: "Shanghai")
            let grounded = ProfileDirectory.groundedUpdates([proposal], in: text, profiles: [])
            XCTAssertTrue(grounded.allSatisfy { $0.birthDate == nil && $0.birthTime == nil && $0.birthPlace == nil }, fact)
        }

        let separateEvent = "My name is Alex Chen. I was born on June 15, 1995. I have an interview at 9:30 a.m. in Shanghai."
        let update = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: separateEvent, profiles: []).first)
        XCTAssertEqual(update.birthDate, "1995-06-15")
        XCTAssertNil(update.birthTime)
        XCTAssertNil(update.birthPlace)
        let currentPlace = "My name is Alex Chen. I was born on June 15, 1995, at 9:30 a.m. I work in Beijing."
        let own = try XCTUnwrap(ProfileDirectory.parseExplicitUpdates(in: currentPlace, profiles: []).first)
        XCTAssertEqual(own.birthTime, "09:30")
        XCTAssertNil(own.birthPlace, "A work location is not a birthplace.")
    }

    func testEnglishBirthFactsStayWithTheNamedPerson() throws {
        let text = "My name is Alex Chen. Bob Smith was born on June 15, 1995, at 9:30 a.m. in Shanghai, China."
        let updates = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [])
        let alex = try XCTUnwrap(updates.first { $0.name == "Alex Chen" })
        let bob = try XCTUnwrap(updates.first { $0.name == "Bob Smith" })
        XCTAssertNil(alex.birthDate)
        XCTAssertNil(alex.birthTime)
        XCTAssertNil(alex.birthPlace)
        XCTAssertEqual(bob.birthDate, "1995-06-15")
        XCTAssertEqual(bob.birthTime, "09:30")
        XCTAssertEqual(bob.birthPlace, "Shanghai")
        let wrongOwner = ProfileUpdate(name: "Alex Chen", birthDate: "1995-06-15", birthTime: "09:30", birthPlace: "Shanghai")
        let grounded = ProfileDirectory.groundedUpdates([wrongOwner], in: text, profiles: [])
        XCTAssertTrue(grounded.allSatisfy { $0.birthDate == nil && $0.birthTime == nil && $0.birthPlace == nil })
    }

    func testColloquialReplacementRecognizesTheExactSavedPerson() {
        var person = OracleProfile(); person.name = "李岚"
        XCTAssertEqual(ProfileDirectory.referencedNames(in: "换成李岚，看看她的工作", profiles: [person]), ["李岚"])
        XCTAssertTrue(ProfileDirectory.referencedNames(in: "换成李岚青，看看她的工作", profiles: [person]).isEmpty)
    }

    func testUnknownPlannerNameNeedsAnExactAffirmativeQuestionTarget() {
        XCTAssertTrue(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "帮我看看我同事王安的事业", profiles: []))
        XCTAssertTrue(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "王安下周工作怎么样？", profiles: []))
        XCTAssertFalse(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "不要问王安，看看我自己的工作", profiles: []))
        XCTAssertFalse(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "帮我看看王安宁的事业", profiles: []))
        XCTAssertFalse(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "我的同事王安，出生日期是1990年1月2日", profiles: []))
        XCTAssertFalse(ProfileDirectory.isAffirmativeParticipantReference("王安", in: "帮我看看王安的朋友最近怎么样", profiles: []))
    }

    func testPossessiveReferenceSelectsTheNamedColleagueInsteadOfTheOwner() {
        var chen = OracleProfile(); chen.name = "陈平"
        var colleague = OracleProfile(); colleague.name = "王安"
        let text = "帮我看看陈平的同事王安的工作"
        let references = ProfileDirectory.participantReferences(in: text, profiles: [chen, colleague])
        XCTAssertEqual(references.included, ["王安"])
        XCTAssertEqual(references.excluded, ["陈平"])
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "陈平的同事1995年1月2日出生", profiles: [chen]).isEmpty)
    }

    func testNegatedBirthDateIsNotStoredAndActualCorrectionIsUsed() {
        var person = OracleProfile(); person.name = "陈平"
        let profiles = [person]
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "陈平不是1995年1月2日出生的", profiles: profiles).isEmpty)
        let updates = ProfileDirectory.parseExplicitUpdates(in: "陈平不是1995年1月2日出生，是1994年2月3日出生", profiles: profiles)
        XCTAssertEqual(updates.first?.birthDate, "1994-02-03")
    }

    func testNamedReadingQuestionDoesNotAttachTheSpeakersBirthdayToThatPerson() {
        var person = OracleProfile(); person.name = "陈平"
        var speaker = OracleProfile(); speaker.name = "王安"
        let text = "陈平工作怎么样？我的生日是1990年1月2日"
        let profiles = [person, speaker]
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: text, profiles: profiles).isEmpty)
        let misleading = ProfileUpdate(id: person.id, name: "陈平", birthDate: "1990-01-02")
        XCTAssertTrue(ProfileDirectory.groundedUpdates([misleading], in: text, profiles: profiles, contextIDs: [person.id]).isEmpty)
        let owned = ProfileDirectory.explicitSelfUpdates(in: text, profiles: profiles, selfProfileID: speaker.id)
        XCTAssertEqual(owned.map(\.id), [speaker.id])
        XCTAssertEqual(owned.first?.birthDate, "1990-01-02")
        XCTAssertTrue(ProfileDirectory.explicitSelfUpdates(in: text, profiles: profiles, selfProfileID: nil).isEmpty)
        XCTAssertTrue(ProfileDirectory.explicitSelfUpdates(in: "我的生日是1990年1月2日吗？", profiles: profiles, selfProfileID: speaker.id).isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "陈平生日是1990年1月2日吗？", profiles: profiles).isEmpty)
    }

    func testContextGroundsSelfBirthdayOnlyToTheSuppliedOwner() {
        var other = OracleProfile(); other.name = "张三"
        var own = OracleProfile(); own.name = "李四"
        let statement = "我的生日是1991年2月3日"
        let profiles = [other, own]
        XCTAssertTrue(ProfileDirectory.hasExplicitSelfFacts(in: statement))
        XCTAssertTrue(ProfileDirectory.hasExplicitSelfFacts(in: "张三的工作怎么样？我的生日是1991年2月3日"))
        XCTAssertFalse(ProfileDirectory.hasExplicitSelfFacts(in: "帮我补一下生日"))
        XCTAssertFalse(ProfileDirectory.hasExplicitSelfFacts(in: "我朋友的生日是1991年2月3日"))
        let wrong = ProfileUpdate(id: other.id, name: other.resolvedName, birthDate: "1991-02-03")
        XCTAssertTrue(ProfileDirectory.groundedUpdates([wrong], in: statement, profiles: profiles, contextIDs: [own.id]).isEmpty)
        let correct = ProfileDirectory.groundedUpdates([ProfileUpdate(birthDate: "1991-02-03")], in: statement, profiles: profiles, contextIDs: [own.id])
        XCTAssertEqual(correct.map(\.id), [own.id])
        XCTAssertEqual(correct.first?.birthDate, "1991-02-03")
        XCTAssertTrue(ProfileDirectory.groundedUpdates([ProfileUpdate(birthDate: "1991-02-03")], in: statement, profiles: profiles).isEmpty)
    }

    func testPenNameQuestionReferencesTheExactSavedName() {
        var profile = OracleProfile(); profile.name = "周文"
        let question = "周文这个名字当笔名怎么样？只用姓名五格。"
        XCTAssertEqual(ProfileDirectory.participantReferences(in: question, profiles: [profile]).included, ["周文"])
        XCTAssertTrue(ProfileDirectory.isAffirmativeParticipantReference("周文", in: question, profiles: []))
        XCTAssertTrue(ProfileDirectory.participantReferences(in: "周文涛这个名字当笔名怎么样？", profiles: [profile]).included.isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: question, profiles: [profile]).isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "只用姓名五格", profiles: []).isEmpty)
        for declaration in ["姓名周文", "姓名：周文"] {
            XCTAssertEqual(ProfileDirectory.parseExplicitUpdates(in: declaration, profiles: []).map(\.name), ["周文"])
        }
    }
    private func person(_ name: String, date: String = "1990-01-02", time: String = "08:30", zone: String = "Asia/Shanghai", sex: String = "男") throws -> OracleProfile {
        let result = ProfileDirectory.applying([ProfileUpdate(name: name, sex: sex, birthDate: date, birthTime: time, birthTimeZoneID: zone, birthPlace: "北京")], to: [])
        XCTAssertTrue(result.issues.isEmpty)
        return try XCTUnwrap(result.profiles.first)
    }

    func testNamedPartialUpdatePreservesAllUnprovidedFacts() throws {
        var original = try person("张三")
        original.familyName = "张"; original.givenName = "三"; original.displayName = "旧称呼"
        original.birthLatitude = 39.9; original.birthLongitude = 116.4
        let result = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthPlace: "上海")], to: [original])
        let updated = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(result.appliedIDs, [original.id])
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.birthDate, original.birthDate)
        XCTAssertEqual(updated.birthDateText, original.birthDateText)
        XCTAssertEqual(updated.birthTimeText, original.birthTimeText)
        XCTAssertEqual(updated.birthTimeKnown, original.birthTimeKnown)
        XCTAssertEqual(updated.birthTimeZoneID, original.birthTimeZoneID)
        XCTAssertEqual(updated.sex, original.sex)
        XCTAssertEqual(updated.familyName, original.familyName)
        XCTAssertEqual(updated.givenName, original.givenName)
        XCTAssertEqual(updated.displayName, original.displayName)
        XCTAssertEqual(updated.birthLatitude, original.birthLatitude)
        XCTAssertEqual(updated.birthLongitude, original.birthLongitude)
        XCTAssertEqual(updated.birthPlace, "上海")
        let renamed = try XCTUnwrap(ProfileDirectory.applying([ProfileUpdate(id: original.id, name: "张小明")], to: [original]).profiles.first)
        XCTAssertEqual(renamed.resolvedName, "张小明")
        XCTAssertEqual(renamed.familyName, "")
        XCTAssertEqual(renamed.givenName, "")
        XCTAssertTrue(renamed.unknownFields.isSuperset(of: [.surname, .givenName]))
        XCTAssertEqual(renamed.birthDate, original.birthDate)
    }

    func testNameOnlyCreatesNamedRecordWithExplicitlyUnknownBirthFacts() throws {
        let result = ProfileDirectory.applying([ProfileUpdate(name: "张三")], to: [])
        let profile = try XCTUnwrap(result.profiles.first)
        XCTAssertEqual(profile.resolvedName, "张三")
        XCTAssertNil(profile.birthDate)
        XCTAssertNil(profile.birthDateText)
        XCTAssertNil(profile.birthTimeText)
        XCTAssertFalse(profile.birthTimeKnown)
        XCTAssertTrue(profile.unknownFields.isSuperset(of: [.gender, .birthDate, .birthTime, .birthTimeZone, .birthPlace]))
        XCTAssertEqual(profile.sex, "未提供")
    }

    func testUnknownBirthTimeAndZoneOverrideConflictingPatchWithoutErasingDate() throws {
        let original = try person("张三")
        let patch = ProfileUpdate(name: "张三", birthTime: "09:00", birthTimeZoneID: "Asia/Shanghai", unknownFields: [.birthTime, .birthTimeZone])
        let updated = try XCTUnwrap(ProfileDirectory.applying([patch], to: [original]).profiles.first)
        XCTAssertEqual(updated.birthDateText, "1990-01-02")
        XCTAssertNil(updated.birthTimeText)
        XCTAssertFalse(updated.birthTimeKnown)
        XCTAssertTrue(updated.unknownFields.contains(.birthTime))
        XCTAssertTrue(updated.unknownFields.contains(.birthTimeZone))
        XCTAssertFalse(updated.unknownFields.contains(.birthDate))
    }

    func testDuplicateNameRequiresSpecificIDAndResolutionReportsAmbiguity() throws {
        let first = try person("张三")
        let second = try person("张三", date: "1992-03-04")
        let rejected = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthPlace: "深圳")], to: [first, second])
        XCTAssertEqual(rejected.profiles, [first, second])
        XCTAssertTrue(rejected.appliedIDs.isEmpty)
        XCTAssertEqual(rejected.issues.first?.kind, .ambiguousName)
        XCTAssertEqual(Set(rejected.issues.first?.candidateIDs ?? []), Set([first.id, second.id]))
        let resolved = ProfileDirectory.resolve(names: ["张三"], in: [first, second])
        XCTAssertTrue(resolved.ids.isEmpty)
        XCTAssertEqual(resolved.issues.first?.kind, .ambiguousName)
        let selected = ProfileDirectory.applying([ProfileUpdate(id: second.id, birthPlace: "深圳")], to: [first, second])
        XCTAssertEqual(selected.profiles.first, first)
        XCTAssertEqual(selected.profiles.last?.birthPlace, "深圳")
        XCTAssertEqual(selected.appliedIDs, [second.id])
    }

    func testLegacyFullNameAndDisplayNameResolveWithoutCreatingAnotherRecord() throws {
        var fullName = OracleProfile(); fullName.familyName = "王"; fullName.givenName = "小明"
        var displayName = OracleProfile(); displayName.displayName = "李四"
        let result = ProfileDirectory.applying([ProfileUpdate(name: "王小明", sex: "男"), ProfileUpdate(name: "李四", sex: "女")], to: [fullName, displayName])
        XCTAssertEqual(result.profiles.map(\.id), [fullName.id, displayName.id])
        XCTAssertEqual(ProfileDirectory.resolve(names: ["王小明", "李四", "王小明"], in: result.profiles).ids, [fullName.id, displayName.id])
    }

    func testNamelessPlaceholderAndUnknownIDNeverCreateAnUnidentifiedPerson() {
        let result = ProfileDirectory.applying([
            ProfileUpdate(birthDate: "1990-01-02"), ProfileUpdate(name: "本人"),
            ProfileUpdate(id: UUID(), name: "张三", birthDate: "1990-01-02")
        ], to: [])
        XCTAssertTrue(result.profiles.isEmpty)
        XCTAssertEqual(result.issues.map(\.kind), [.missingName, .missingName, .unknownID])
    }

    func testAnonymousLabelStaysStableAcrossEditsAndDecodingWithoutBecomingAName() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000002A"))
        var profile = OracleProfile(id: id, isAnonymousRecord: true)
        XCTAssertEqual(profile.anonymousCode, "0042")
        XCTAssertEqual(profile.participantLabel, "0042")
        XCTAssertTrue(profile.resolvedName.isEmpty)
        XCTAssertTrue(ProfileDirectory.resolve(names: ["0042"], in: [profile]).ids.isEmpty)
        profile.alias = "  小满  "
        XCTAssertEqual(profile.participantLabel, "小满")
        XCTAssertTrue(profile.resolvedName.isEmpty)
        profile.alias = ""
        profile.displayName = "旧姓名"
        let decoded = try JSONDecoder().decode(OracleProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.anonymousCode, "0042")
        XCTAssertEqual(decoded.participantLabel, "旧姓名")
        XCTAssertEqual(decoded.isAnonymousRecord, true)
    }

    func testChineseBirthZoneDefaultPreservesLegacyClockOnFreshSnapshot() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "1990-01-02T00:05:17Z"))
        var legacy = OracleProfile(birthDate: instant, birthTimeZoneID: "UTC")
        legacy.unknownFields.insert(.birthTimeZone)
        legacy.declaredUnknownFields = [.birthTimeZone]
        let updated = ProfileDirectory.assigningDefaultBirthTimeZone(to: legacy)
        XCTAssertEqual(updated.birthTimeZoneID, OracleProfile.defaultChinaTimeZoneID)
        XCTAssertEqual(updated.birthDateText, "1990-01-02")
        XCTAssertEqual(updated.birthTimeText, "00:05:17")
        XCTAssertEqual(updated.birthDate, instant.addingTimeInterval(-8 * 3_600))
        XCTAssertFalse(updated.unknownFields.contains(.birthTimeZone))
        XCTAssertFalse(updated.declaredUnknownFields?.contains(.birthTimeZone) == true)
        XCTAssertEqual(legacy.birthTimeZoneID, "UTC")
        XCTAssertEqual(legacy.birthDate, instant)
        legacy.unknownFields = []; legacy.declaredUnknownFields = []
        legacy.birthTimeZoneID = "America/New_York"
        XCTAssertEqual(ProfileDirectory.assigningDefaultBirthTimeZone(to: legacy), legacy)
        XCTAssertEqual(OracleProfile().currentTimeZoneID, OracleProfile.defaultChinaTimeZoneID)
    }

    func testClearedOptionalFieldsStayClearedWhenRestoringCachedDraft() throws {
        var saved = try person("张三")
        saved.alias = "小满"
        saved.familyName = "张"; saved.givenName = "三"
        saved.birthDistrictCode = "110101"
        saved.birthLatitude = 39.9; saved.birthLongitude = 116.4
        var draft = ProfileDirectory.clearingFields([.birthDate, .birthPlace, .surname, .gender], in: saved)
        draft.alias = ""
        let restored = ProfileDirectory.restoringKnownFields(in: draft, from: saved)
        XCTAssertNil(restored.birthDate)
        XCTAssertNil(restored.birthDateText)
        XCTAssertEqual(restored.birthTimeText, saved.birthTimeText)
        XCTAssertTrue(restored.birthTimeKnown)
        XCTAssertEqual(restored.birthPlace, "")
        XCTAssertNil(restored.birthDistrictCode)
        XCTAssertNil(restored.birthLatitude)
        XCTAssertNil(restored.birthLongitude)
        XCTAssertEqual(restored.familyName, "")
        XCTAssertEqual(restored.givenName, "三")
        XCTAssertEqual(restored.sex, "未提供")
        XCTAssertEqual(restored.participantLabel, "张三")
        XCTAssertTrue(restored.declaredUnknownFields?.isSuperset(of: [.birthDate, .birthPlace, .birthCoordinates, .surname, .gender]) == true)
        let timeCleared = ProfileDirectory.clearingFields([.birthTime], in: saved)
        XCTAssertEqual(timeCleared.birthDateText, saved.birthDateText)
        XCTAssertNil(timeCleared.birthTimeText)
        XCTAssertFalse(timeCleared.birthTimeKnown)
    }

    func testBoundAnonymousProfileAcceptsItsOwnFactsWithoutUsingAnInventedName() throws {
        let person = OracleProfile(isAnonymousRecord: true)
        let updates = ProfileDirectory.explicitSelfUpdates(in: "我的生日是1990年1月2日。陈平的生日是1992年8月3日。",
            profiles: [person], selfProfileID: person.id)
        XCTAssertEqual(updates.map(\.id), [person.id])
        XCTAssertNil(updates.first?.name)
        let merged = ProfileDirectory.applying(updates, to: [person])
        let updated = try XCTUnwrap(merged.profiles.first)
        XCTAssertTrue(merged.issues.isEmpty)
        XCTAssertEqual(updated.birthDateText, "1990-01-02")
        XCTAssertEqual(updated.participantLabel, person.anonymousCode)
    }

    func testDraftCoordinatesOnlyRestoreForSameBirthDistrictOrAnEntireMissingPlace() throws {
        var saved = try person("张三")
        saved.birthPlace = "北京市东城区"
        saved.birthDistrictCode = "110101"
        saved.birthLatitude = 39.93; saved.birthLongitude = 116.42
        var draft = saved
        draft.birthPlace = "北京市西城区"
        draft.birthDistrictCode = "110102"
        draft.birthLatitude = nil; draft.birthLongitude = nil
        draft.unknownFields.insert(.birthCoordinates)
        XCTAssertEqual(ProfileDirectory.restoringKnownFields(in: draft, from: saved), draft)
        draft.birthDistrictCode = saved.birthDistrictCode
        draft.birthPlace = saved.birthPlace
        let sameDistrict = ProfileDirectory.restoringKnownFields(in: draft, from: saved)
        XCTAssertEqual(sameDistrict.birthLatitude, saved.birthLatitude)
        XCTAssertEqual(sameDistrict.birthLongitude, saved.birthLongitude)
        draft.birthDistrictCode = nil; draft.birthPlace = ""
        let missingPlace = ProfileDirectory.restoringKnownFields(in: draft, from: saved)
        XCTAssertEqual(missingPlace.birthDistrictCode, saved.birthDistrictCode)
        XCTAssertEqual(missingPlace.birthPlace, saved.birthPlace)
        XCTAssertEqual(missingPlace.birthLatitude, saved.birthLatitude)
        saved.birthDistrictCode = nil
        draft.birthPlace = "上海市"
        XCTAssertEqual(ProfileDirectory.restoringKnownFields(in: draft, from: saved), draft)
    }

    func testCurrentDistrictReplacementAndClearDoNotRestoreOldCoordinatesOrChangeBirthplace() throws {
        var saved = try person("张三")
        saved.birthDistrictCode = "110101"
        saved.birthLatitude = 39.93; saved.birthLongitude = 116.42
        saved.currentPlace = "上海市浦东新区"
        saved.currentDistrictCode = "310115"
        saved.currentLatitude = 31.22; saved.currentLongitude = 121.53

        var draft = saved
        draft.currentPlace = "重庆市沙坪坝区"
        draft.currentDistrictCode = "500106"
        draft.currentLatitude = nil; draft.currentLongitude = nil
        XCTAssertEqual(ProfileDirectory.restoringKnownFields(in: draft, from: saved), draft)

        saved.currentTimeZoneID = "America/New_York"
        let cleared = ProfileDirectory.clearingFields([.currentLocation], in: saved)
        XCTAssertEqual(cleared.currentPlace, "")
        XCTAssertNil(cleared.currentDistrictCode)
        XCTAssertNil(cleared.currentLatitude)
        XCTAssertNil(cleared.currentLongitude)
        XCTAssertEqual(cleared.currentTimeZoneID, OracleProfile.defaultChinaTimeZoneID)
        XCTAssertTrue(cleared.unknownFields.contains(.currentLocation))
        XCTAssertTrue(cleared.declaredUnknownFields?.contains(.currentLocation) == true)
        XCTAssertEqual(cleared.birthDistrictCode, saved.birthDistrictCode)
        XCTAssertEqual(cleared.birthPlace, saved.birthPlace)
        XCTAssertEqual(cleared.birthLatitude, saved.birthLatitude)
        XCTAssertEqual(cleared.birthLongitude, saved.birthLongitude)
        XCTAssertEqual(cleared.birthTimeZoneID, saved.birthTimeZoneID)
        XCTAssertEqual(ProfileDirectory.restoringKnownFields(in: cleared, from: saved), cleared)

        saved.currentDistrictCode = nil
        let legacy = try JSONDecoder().decode(OracleProfile.self, from: JSONEncoder().encode(saved))
        XCTAssertNil(legacy.currentDistrictCode)
        XCTAssertEqual(legacy.currentLatitude, saved.currentLatitude)
        XCTAssertEqual(legacy.currentLongitude, saved.currentLongitude)
        XCTAssertEqual(legacy.currentTimeZoneID, "America/New_York")
    }

    func testOfflineParserSeparatesTwoNamedPeopleAndDoesNotInferBirthTimeOrZone() throws {
        let text = "张三，男，1995年1月2日出生；李四，女，1996年3月4日出生"
        let patches = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [])
        XCTAssertEqual(patches.map(\.name), ["张三", "李四"])
        XCTAssertEqual(patches.map(\.birthDate), ["1995-01-02", "1996-03-04"])
        XCTAssertEqual(patches.map(\.sex), ["男", "女"])
        XCTAssertTrue(patches.allSatisfy { $0.birthTime == nil && $0.birthTimeZoneID == nil && $0.birthPlace == nil })
        let result = ProfileDirectory.applying(patches, to: [])
        XCTAssertEqual(result.profiles.count, 2)
        XCTAssertTrue(result.profiles.allSatisfy { $0.unknownFields.contains(.birthTime) && $0.unknownFields.contains(.birthTimeZone) })
    }

    func testOfflineNamedFollowupAddsOnlyItsExplicitTimeAndPlace() throws {
        let people = [try person("张三"), try person("李四", sex: "女")]
        let patches = ProfileDirectory.parseExplicitUpdates(in: "张三出生时间09:15，出生地深圳", profiles: people)
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.id, people[0].id)
        XCTAssertEqual(patches.first?.birthTime, "09:15")
        XCTAssertEqual(patches.first?.birthPlace, "深圳")
        XCTAssertNil(patches.first?.sex)
        XCTAssertNil(patches.first?.birthDate)
        XCTAssertNil(patches.first?.birthTimeZoneID)
        XCTAssertEqual(ProfileDirectory.applying(patches, to: people).profiles[1], people[1])
    }

    func testUnknownClausesDoNotBecomeFictitiousPeopleAndPronounsDoNotLocateProfiles() throws {
        let patches = ProfileDirectory.parseExplicitUpdates(in: "张三出生于1990年1月2日，时间不确定，时区不确定", profiles: [])
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches.first?.name, "张三")
        XCTAssertEqual(Set(patches.first?.unknownFields ?? []), Set([.birthTime, .birthTimeZone]))
        let existing = try person("张三")
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "他出生时间09:00", profiles: [existing]).isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "张三在2026年11月2日要面试", profiles: [existing]).isEmpty)
    }

    func testTimeCanArriveBeforeBirthdayAndLaterTimezoneKeepsWallClockText() throws {
        let first = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthTime: "08:30")], to: [])
        XCTAssertNil(first.profiles.first?.birthDate)
        XCTAssertEqual(first.profiles.first?.birthTimeText, "08:30")
        let dated = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthDate: "1990-01-02")], to: first.profiles)
        let anchored = try XCTUnwrap(dated.profiles.first?.birthDate)
        let zoned = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthTimeZoneID: "Asia/Shanghai")], to: dated.profiles)
        let profile = try XCTUnwrap(zoned.profiles.first)
        XCTAssertEqual(profile.birthDateText, "1990-01-02")
        XCTAssertEqual(profile.birthTimeText, "08:30")
        XCTAssertEqual(try XCTUnwrap(profile.birthDate).timeIntervalSince(anchored), -8 * 3600, accuracy: 1)
        XCTAssertFalse(profile.unknownFields.contains(.birthTimeZone))
    }

    func testUnrelatedLegacyUpdateDoesNotRebuildAmbiguousDaylightSavingInstant() throws {
        var legacy = OracleProfile(); legacy.displayName = "张三"; legacy.birthTimeZoneID = "America/New_York"
        legacy.birthDate = ISO8601DateFormatter().date(from: "2020-11-01T01:30:00-05:00")
        let result = ProfileDirectory.applying([ProfileUpdate(name: "张三", sex: "女")], to: [legacy])
        XCTAssertEqual(result.profiles.first?.birthDate, legacy.birthDate)
        XCTAssertEqual(result.profiles.first?.birthTimeZoneID, legacy.birthTimeZoneID)
        XCTAssertNil(result.profiles.first?.birthDateText)
        XCTAssertNil(result.profiles.first?.birthTimeText)
        let invalid = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthDate: "2020-02-30")], to: [legacy])
        XCTAssertEqual(invalid.profiles.first?.birthDate, legacy.birthDate)
        XCTAssertNil(invalid.profiles.first?.birthDateText)
        var oldEmpty = OracleProfile(); oldEmpty.displayName = "李四"
        let birthdayOnly = ProfileDirectory.applying([ProfileUpdate(name: "李四", birthDate: "1990-01-02")], to: [oldEmpty])
        XCTAssertFalse(try XCTUnwrap(birthdayOnly.profiles.first).birthTimeKnown)
        XCTAssertNil(birthdayOnly.profiles.first?.birthTimeText)
        XCTAssertTrue(birthdayOnly.profiles.first?.unknownFields.contains(.birthTime) == true)
    }

    func testInvalidCalendarValuesAndNonexistentLocalTimePreserveKnownBirthFacts() throws {
        let original = try person("张三", date: "2020-01-02", zone: "America/New_York")
        let invalid = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthDate: "2020-02-30", birthTime: "25:00", birthTimeZoneID: "Not/AZone")], to: [original])
        XCTAssertEqual(invalid.profiles.first?.birthDate, original.birthDate)
        XCTAssertEqual(invalid.profiles.first?.birthTimeZoneID, original.birthTimeZoneID)
        XCTAssertEqual(invalid.issues.count, 3)
        let gap = ProfileDirectory.applying([ProfileUpdate(name: "张三", birthDate: "2020-03-08", birthTime: "02:30")], to: [original])
        XCTAssertEqual(gap.profiles.first?.birthDate, original.birthDate)
        XCTAssertEqual(gap.profiles.first?.birthDateText, original.birthDateText)
        XCTAssertEqual(gap.profiles.first?.birthTimeText, original.birthTimeText)
        XCTAssertFalse(gap.issues.isEmpty)
    }

    func testModelGroundingDropsInferredDefaultsAndOtherPersonsFacts() throws {
        let people = [try person("张三"), try person("李四", sex: "女")]
        let proposed = [
            ProfileUpdate(id: people[0].id, name: "张三", sex: "男", birthDate: "1996-03-04", birthTime: "09:00", birthTimeZoneID: "Asia/Shanghai", birthPlace: "北京"),
            ProfileUpdate(id: people[1].id, name: "李四", sex: "女", birthDate: "1996-03-04", birthTimeZoneID: "Asia/Shanghai", unknownFields: [.birthTime, .birthDate])
        ]
        let text = "张三出生时间09:00；李四出生日期1996-03-04，时间不确定"
        let grounded = ProfileDirectory.groundedUpdates(proposed, in: text, profiles: people)
        XCTAssertEqual(grounded.count, 2)
        XCTAssertEqual(grounded[0].birthTime, "09:00")
        XCTAssertNil(grounded[0].birthDate)
        XCTAssertNil(grounded[0].sex)
        XCTAssertNil(grounded[0].birthTimeZoneID)
        XCTAssertNil(grounded[0].birthPlace)
        XCTAssertEqual(grounded[1].birthDate, "1996-03-04")
        XCTAssertEqual(grounded[1].unknownFields, [.birthTime])
        XCTAssertNil(grounded[1].sex)
        XCTAssertNil(grounded[1].birthTimeZoneID)
        let seconds = ProfileDirectory.groundedUpdates([ProfileUpdate(name: "张三", birthTime: "09:00:00")], in: "张三出生时间09:00", profiles: people)
        XCTAssertEqual(seconds.first?.birthTime, "09:00:00")
    }

    func testModelGroundingBindsOmittedNameOnlyForOneExplicitContextAndRejectsAmbiguousIDGuess() throws {
        let first = try person("张三")
        let second = try person("李四")
        let proposed = [ProfileUpdate(sex: "男", birthTime: "08:30", birthPlace: "北京")]
        let text = "出生时间08:30，出生地北京"
        let one = ProfileDirectory.groundedUpdates(proposed, in: text, profiles: [first, second], contextIDs: [first.id])
        XCTAssertEqual(one.first?.id, first.id)
        XCTAssertEqual(one.first?.birthTime, "08:30")
        XCTAssertNil(one.first?.sex)
        XCTAssertTrue(ProfileDirectory.groundedUpdates(proposed, in: text, profiles: [first, second], contextIDs: [first.id, second.id]).isEmpty)
        let duplicate = try person("张三", date: "1992-03-04")
        let guessed = ProfileDirectory.groundedUpdates([ProfileUpdate(id: first.id, name: "张三", birthTime: "08:30")], in: "张三出生时间08:30", profiles: [first, duplicate])
        XCTAssertNil(guessed.first?.id)
        XCTAssertEqual(ProfileDirectory.applying(guessed, to: [first, duplicate]).issues.first?.kind, .ambiguousName)
    }

    func testSelfDeclarationRequiresNameBoundaryAndNeverUsesRelationshipWords() {
        XCTAssertEqual(ProfileDirectory.explicitSelfName(in: "我叫张三，生日1990-01-02", profiles: []), "张三")
        XCTAssertEqual(ProfileDirectory.explicitSelfName(in: "我是李四。", profiles: []), "李四")
        XCTAssertNil(ProfileDirectory.explicitSelfName(in: "我是张三的朋友", profiles: []))
        XCTAssertNil(ProfileDirectory.explicitSelfName(in: "我是张三今年26岁", profiles: []))
        XCTAssertNil(ProfileDirectory.explicitSelfName(in: "张三是我朋友", profiles: []))
    }

    func testPatchBatchAndNameLengthAreBounded() {
        let many = (0..<30).map { ProfileUpdate(name: "Person \($0)") }
        XCTAssertEqual(ProfileDirectory.applying(many, to: []).profiles.count, 20)
        XCTAssertTrue(ProfileDirectory.applying([ProfileUpdate(name: String(repeating: "张", count: 81))], to: []).profiles.isEmpty)
    }

    func testReferencedNamesPreferCompleteLongNameAndDoNotSelectItsShortPrefix() throws {
        let short = try person("李四")
        let long = try person("李四海")
        let people = [short, long]
        XCTAssertEqual(ProfileDirectory.referencedNames(in: "李四海的工作怎么样，李四海最近如何", profiles: people), ["李四海"])
        let parsed = ProfileDirectory.parseExplicitUpdates(in: "李四海出生日期1992-03-04", profiles: people)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.id, long.id)
        XCTAssertEqual(parsed.first?.name, "李四海")
        let grounded = ProfileDirectory.groundedUpdates([ProfileUpdate(id: short.id, name: "李四", birthDate: "1992-03-04")], in: "李四海出生日期1992-03-04", profiles: people)
        XCTAssertTrue(grounded.isEmpty)
    }

    func testUnknownLongNameCannotReferenceOrPatchKnownShortName() throws {
        let short = try person("李四")
        XCTAssertTrue(ProfileDirectory.referencedNames(in: "李四海的工作怎么样", profiles: [short]).isEmpty)
        XCTAssertEqual(ProfileDirectory.referencedNames(in: "李四的工作如何，李四和朋友一起创业", profiles: [short]), ["李四"])
        let parsed = ProfileDirectory.parseExplicitUpdates(in: "李四海1992-03-04，男", profiles: [short])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "李四海")
        XCTAssertNil(parsed.first?.id)
        let merged = ProfileDirectory.applying(parsed, to: [short])
        XCTAssertEqual(merged.profiles.first, short)
        XCTAssertEqual(merged.profiles.last?.resolvedName, "李四海")
        let grounded = ProfileDirectory.groundedUpdates([ProfileUpdate(id: short.id, name: "李四", birthDate: "1992-03-04")], in: "李四海1992-03-04，男", profiles: [short])
        XCTAssertTrue(grounded.isEmpty)
    }

    func testBareSingleAIExtractedNameSavesIdentityWithoutInventedBirthFacts() throws {
        let proposed = [ProfileUpdate(name: "张三", sex: "男", birthDate: "1990-01-01", birthTime: "08:00", birthTimeZoneID: "Asia/Shanghai")]
        let grounded = ProfileDirectory.groundedUpdates(proposed, in: "  张三  ", profiles: [])
        XCTAssertEqual(grounded, [ProfileUpdate(name: "张三")])
        let saved = try XCTUnwrap(ProfileDirectory.applying(grounded, to: []).profiles.first)
        XCTAssertEqual(saved.resolvedName, "张三")
        XCTAssertNil(saved.birthDate)
        XCTAssertEqual(saved.sex, "未提供")
        XCTAssertTrue(saved.unknownFields.isSuperset(of: [.birthDate, .birthTime, .birthTimeZone, .gender]))
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "张三", profiles: []).isEmpty)
    }

    func testBareTwoAIExtractedNamesSaveSeparatelyWithoutDefaultDatesOrSex() {
        let proposed = [ProfileUpdate(name: "张三", sex: "男", birthDate: "1990-01-01"),
                        ProfileUpdate(name: "李四", sex: "女", birthDate: "1992-01-01")]
        for text in ["张三、李四", "张三，李四", "张三；李四", "张三\n李四", "张三和李四", "张三与李四"] {
            let grounded = ProfileDirectory.groundedUpdates(proposed, in: text, profiles: [])
            XCTAssertEqual(grounded, [ProfileUpdate(name: "张三"), ProfileUpdate(name: "李四")], text)
            let saved = ProfileDirectory.applying(grounded, to: []).profiles
            XCTAssertEqual(saved.map(\.resolvedName), ["张三", "李四"], text)
            XCTAssertTrue(saved.allSatisfy { $0.birthDate == nil && $0.sex == "未提供" }, text)
        }
    }

    func testSupplementPrefixDoesNotBecomeNameOrHideNamedTimeEvidence() throws {
        let firstText = "先留存两个人的资料：姓名：张三，男，1995年1月2日出生；姓名：李四，女，1996年3月4日出生。先保存资料，不要算卦。"
        let firstUpdates = ProfileDirectory.parseExplicitUpdates(in: firstText, profiles: [])
        XCTAssertEqual(firstUpdates.map(\.name), ["张三", "李四"])
        let initial = ProfileDirectory.applying(firstUpdates, to: []).profiles
        let text = "补充张三的出生时间08:30，出生时区Asia/Shanghai；李四的出生时间不确定，出生时区Asia/Shanghai。只补充资料。"
        let local = ProfileDirectory.parseExplicitUpdates(in: text, profiles: initial)
        XCTAssertEqual(local.map(\.name), ["张三", "李四"])
        XCTAssertEqual(local.first?.birthTime, "08:30")
        let proposed = [ProfileUpdate(name: "张三", birthTime: "08:30", birthTimeZoneID: "Asia/Shanghai"),
                        ProfileUpdate(name: "李四", birthTimeKnown: false, birthTimeZoneID: "Asia/Shanghai", unknownFields: [.birthTime])]
        let grounded = ProfileDirectory.groundedUpdates(proposed, in: text, profiles: initial)
        XCTAssertEqual(grounded.first?.birthTime, "08:30")
        let saved = ProfileDirectory.applying(grounded, to: initial).profiles
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first?.birthTimeText, "08:30")
        XCTAssertEqual(saved.last?.birthDateText, "1996-03-04")
        XCTAssertEqual(saved.last?.birthTimeKnown, false)
        XCTAssertTrue(saved.allSatisfy { $0.birthTimeZoneID == "Asia/Shanghai" })
    }

    func testSingleContextAcceptsBareClockOrIANAZoneWithoutInventingBirthday() throws {
        let first = try person("张三", time: "07:00")
        let second = try person("李四", sex: "女")
        let people = [first, second]
        let proposed = [ProfileUpdate(birthDate: "2000-01-01", birthTime: "08:30")]
        let grounded = ProfileDirectory.groundedUpdates(proposed, in: "08:30", profiles: people, contextIDs: [first.id])
        XCTAssertEqual(grounded.first?.id, first.id)
        XCTAssertEqual(grounded.first?.birthTime, "08:30")
        XCTAssertNil(grounded.first?.birthDate)
        let saved = ProfileDirectory.applying(grounded, to: people).profiles
        XCTAssertEqual(saved.first?.birthTimeText, "08:30")
        XCTAssertEqual(saved.first?.birthDateText, first.birthDateText)
        XCTAssertEqual(saved.last, second)
        XCTAssertTrue(ProfileDirectory.groundedUpdates(proposed, in: "08:30", profiles: people, contextIDs: people.map(\.id)).isEmpty)
        let clockWithSeconds = ProfileDirectory.groundedUpdates([ProfileUpdate(birthTime: "08:30:15")], in: "08:30:15", profiles: people, contextIDs: [first.id])
        XCTAssertEqual(clockWithSeconds.first?.birthTime, "08:30:15")
        let zone = [ProfileUpdate(birthTimeZoneID: "America/New_York")]
        let zoned = ProfileDirectory.groundedUpdates(zone, in: "America/New_York", profiles: people, contextIDs: [first.id])
        XCTAssertEqual(zoned.first?.birthTimeZoneID, "America/New_York")
        XCTAssertNil(zoned.first?.birthDate)
        XCTAssertTrue(ProfileDirectory.groundedUpdates(zone, in: "America/New_York", profiles: people, contextIDs: people.map(\.id)).isEmpty)
        XCTAssertTrue(ProfileDirectory.groundedUpdates(proposed, in: "大概08:30", profiles: people, contextIDs: [first.id]).isEmpty)
        XCTAssertTrue(ProfileDirectory.groundedUpdates([ProfileUpdate(birthPlace: "北京")], in: "北京", profiles: people, contextIDs: [first.id]).isEmpty)
    }

    func testExplicitSurnameAndGivenNameAreCollectedSeparatelyWithoutSplittingIdentity() throws {
        var original = try person("张小明")
        original.unknownFields.formUnion([.surname, .givenName])
        original.declaredUnknownFields = [.surname, .givenName]
        let guessed = ProfileDirectory.groundedUpdates([ProfileUpdate(name: "张小明", familyName: "张", givenName: "小明")], in: "张小明", profiles: [original])
        XCTAssertNil(guessed.first?.familyName)
        XCTAssertNil(guessed.first?.givenName)
        let surnameText = "张小明姓氏：张"
        let surname = ProfileDirectory.parseExplicitUpdates(in: surnameText, profiles: [original])
        XCTAssertEqual(surname.first?.familyName, "张")
        let familyGrounded = ProfileDirectory.groundedUpdates([ProfileUpdate(name: "张小明", familyName: "张", givenName: "小明")], in: surnameText, profiles: [original])
        XCTAssertNil(familyGrounded.first?.givenName)
        let withFamily = try XCTUnwrap(ProfileDirectory.applying(familyGrounded, to: [original]).profiles.first)
        XCTAssertEqual(withFamily.familyName, "张")
        XCTAssertFalse(withFamily.unknownFields.contains(.surname))
        XCTAssertFalse(withFamily.declaredUnknownFields?.contains(.surname) == true)
        let givenText = "张小明名字：小明"
        let given = ProfileDirectory.parseExplicitUpdates(in: givenText, profiles: [withFamily])
        XCTAssertEqual(given.count, 1)
        XCTAssertEqual(given.first?.name, "张小明")
        XCTAssertEqual(given.first?.givenName, "小明")
        let complete = ProfileDirectory.applying(ProfileDirectory.groundedUpdates(given, in: givenText, profiles: [withFamily]), to: [withFamily])
        XCTAssertEqual(complete.profiles.count, 1)
        XCTAssertEqual(complete.profiles.first?.givenName, "小明")
        XCTAssertFalse(complete.profiles.first?.unknownFields.contains(.givenName) == true)
        XCTAssertFalse(complete.profiles.first?.declaredUnknownFields?.contains(.givenName) == true)
        XCTAssertEqual(complete.profiles.first?.birthDate, original.birthDate)
        let both = ProfileDirectory.parseExplicitUpdates(in: "张三姓氏：张，名字：三", profiles: [])
        XCTAssertEqual(both.count, 1)
        XCTAssertEqual(both.first?.familyName, "张")
        XCTAssertEqual(both.first?.givenName, "三")
        XCTAssertNil(ProfileDirectory.parseExplicitUpdates(in: "张小明出生时间8点半", profiles: [original]).first?.birthTime)
        XCTAssertEqual(ProfileDirectory.parseExplicitUpdates(in: "张小明出生时间晚上8点半", profiles: [original]).first?.birthTime, "20:30")
    }

    func testNaturalSelfBirthTimeRetractionClearsTheOldClockAndCannotBeRestoredFromSavedDetails() throws {
        let original = try person("陈平")
        let text = "我不知道几点出生，之前那个八点半不准"
        XCTAssertTrue(ProfileDirectory.hasExplicitSelfFacts(in: text))
        let local = ProfileDirectory.explicitSelfUpdates(in: text, profiles: [original], selfProfileID: original.id)
        let patch = try XCTUnwrap(local.first)
        XCTAssertEqual(patch.id, original.id)
        XCTAssertEqual(patch.birthTimeKnown, false)
        XCTAssertTrue(patch.unknownFields?.contains(.birthTime) == true)
        XCTAssertNil(patch.birthTime)
        let grounded = ProfileDirectory.groundedUpdates([ProfileUpdate(id: original.id, birthTimeKnown: false, unknownFields: [.birthTime])],
            in: text, profiles: [original], contextIDs: [original.id])
        XCTAssertEqual(grounded.first?.birthTimeKnown, false)
        XCTAssertTrue(grounded.first?.unknownFields?.contains(.birthTime) == true)
        let changed = try XCTUnwrap(ProfileDirectory.applying(grounded, to: [original]).profiles.first)
        XCTAssertFalse(changed.birthTimeKnown)
        XCTAssertNil(changed.birthTimeText)
        XCTAssertTrue(changed.unknownFields.contains(.birthTime))
        XCTAssertTrue(changed.declaredUnknownFields?.contains(.birthTime) == true)
        XCTAssertEqual(changed.birthDateText, original.birthDateText)
        XCTAssertEqual(changed.birthTimeZoneID, original.birthTimeZoneID)
        let restored = ProfileDirectory.restoringKnownFields(in: changed, from: original)
        XCTAssertFalse(restored.birthTimeKnown)
        XCTAssertNil(restored.birthTimeText)
        let guessed = ProfileDirectory.groundedUpdates([ProfileUpdate(id: original.id, birthTime: "08:30", birthTimeKnown: true)],
            in: text, profiles: [original], contextIDs: [original.id])
        XCTAssertFalse(guessed.contains { $0.birthTime != nil || $0.birthTimeKnown == true })
    }

    func testNamedBirthTimeRetractionsDoNotRetainTheRejectedClockButAcceptAnExplicitReplacement() throws {
        let original = try person("陈平")
        for text in ["陈平不知道几点出生", "陈平出生时间08:30不准", "陈平出生时间不是08:30",
                     "陈平不用原来的出生时间", "陈平不要用之前那个八点半作为出生时间"] {
            let patches = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [original])
            let patch = try XCTUnwrap(patches.first, text)
            XCTAssertEqual(patch.birthTimeKnown, false, text)
            XCTAssertTrue(patch.unknownFields?.contains(.birthTime) == true, text)
            XCTAssertNil(patch.birthTime, text)
            let changed = try XCTUnwrap(ProfileDirectory.applying(patches, to: [original]).profiles.first)
            XCTAssertFalse(changed.birthTimeKnown, text)
            XCTAssertNil(changed.birthTimeText, text)
        }
        let correction = ProfileDirectory.parseExplicitUpdates(in: "陈平出生时间不是08:30，是09:30", profiles: [original])
        XCTAssertEqual(correction.first?.birthTime, "09:30")
        XCTAssertEqual(correction.first?.birthTimeKnown, true)
        XCTAssertFalse(correction.first?.unknownFields?.contains(.birthTime) == true)
        let changed = try XCTUnwrap(ProfileDirectory.applying(correction, to: [original]).profiles.first)
        XCTAssertTrue(changed.birthTimeKnown)
        XCTAssertEqual(changed.birthTimeText, "09:30")
    }

    func testBirthTimeRetractionStaysWithItsOwnerAndNegatedUncertaintyDoesNotClearTime() throws {
        let own = try person("陈平")
        let other = try person("李岚")
        let text = "李岚出生日期1991-04-03，我不知道几点出生"
        let named = ProfileDirectory.parseExplicitUpdates(in: text, profiles: [own, other])
        XCTAssertEqual(named.first?.id, other.id)
        XCTAssertFalse(named.contains { $0.birthTimeKnown == false || $0.unknownFields?.contains(.birthTime) == true })
        let selfUpdates = ProfileDirectory.explicitSelfUpdates(in: text, profiles: [own, other], selfProfileID: own.id)
        XCTAssertEqual(selfUpdates.first?.id, own.id)
        XCTAssertEqual(selfUpdates.first?.birthTimeKnown, false)
        XCTAssertTrue(ProfileDirectory.explicitSelfUpdates(in: "我朋友不知道几点出生", profiles: [own, other], selfProfileID: own.id).isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "陈平不知道我几点出生", profiles: [own, other]).isEmpty)
        XCTAssertTrue(ProfileDirectory.parseExplicitUpdates(in: "陈平不用我的出生时间", profiles: [own, other]).isEmpty)
        let negated = ProfileDirectory.parseExplicitUpdates(in: "陈平不是不知道几点出生", profiles: [own])
        XCTAssertFalse(negated.contains { $0.birthTimeKnown == false || $0.unknownFields?.contains(.birthTime) == true })
    }
}
