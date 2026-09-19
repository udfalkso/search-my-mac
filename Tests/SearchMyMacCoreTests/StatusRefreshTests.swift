import Testing
@testable import SearchMyMacCore

@Test func statusRefreshCoalescesConcurrentPollersAndYieldsToSearch() {
    var schedule = StatusRefreshSchedule()
    let focusedAtStartup = schedule.begin(searchHasPriority: true, now: 0)
    #expect(!focusedAtStartup)
    let initial = schedule.begin(searchHasPriority: false, now: 0)
    let duplicate = schedule.begin(searchHasPriority: false, now: 10)
    #expect(initial)
    #expect(!duplicate)
    schedule.finish(now: 10)
    let tooSoon = schedule.begin(searchHasPriority: false, now: 14)
    let duringSearch = schedule.begin(searchHasPriority: true, now: 20)
    let afterSearch = schedule.begin(searchHasPriority: false, now: 20)
    #expect(!tooSoon)
    #expect(!duringSearch)
    #expect(afterSearch)
    schedule.finish(now: 21)
    let throttled = schedule.begin(searchHasPriority: false, now: 25)
    let due = schedule.begin(searchHasPriority: false, now: 26)
    #expect(!throttled)
    #expect(due)
}
