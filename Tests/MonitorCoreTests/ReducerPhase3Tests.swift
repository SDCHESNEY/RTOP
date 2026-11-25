import Foundation
import Testing
@testable import MonitorCore

@Suite struct DetailsReducerTests {
    private func loaded(pids: [Int32] = [1, 2, 3]) -> AppState {
        var state = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        _ = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(1, pids.map { Fixtures.process($0) })))
        return state
    }

    private func details(_ pid: Int32, args: [String] = ["a"]) -> ProcessDetails {
        ProcessDetails(identity: Fixtures.identity(pid), commandLine: .value(.init(arguments: args)))
    }

    @Test func dOpensPaneAndRequestsDetailsForTheSelection() {
        var state = loaded()
        let effects = Reducer.reduce(&state, .key(.character("d")))
        #expect(effects == [.loadDetails(identity: Fixtures.identity(1), generation: 1)])
        #expect(state.detailPane?.identity == Fixtures.identity(1))
        #expect(state.detailPane?.details == nil)
    }

    @Test func enterOpensAndEscapeClosesWithoutQuitting() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.enter))
        #expect(state.detailPane != nil)
        #expect(Reducer.reduce(&state, .key(.escape)) == [])
        #expect(state.detailPane == nil)
        #expect(Reducer.reduce(&state, .key(.escape)) == [.exit]) // no context left: quits
    }

    @Test func dTogglesClosed() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        _ = Reducer.reduce(&state, .key(.character("d")))
        #expect(state.detailPane == nil)
    }

    @Test func matchingReplyIsAccepted() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: details(1)))
        #expect(state.detailPane?.details == details(1))
    }

    @Test func staleGenerationAndWrongIdentityAreRejected() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))             // generation 1
        _ = Reducer.reduce(&state, .key(.down))                       // retarget -> generation 2, pid 2
        #expect(state.detailPane?.identity == Fixtures.identity(2))
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: details(1)))
        #expect(state.detailPane?.details == nil)
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 2, details: details(1))) // right generation, wrong process
        #expect(state.detailPane?.details == nil)
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 2, details: details(2)))
        #expect(state.detailPane?.details == details(2))
    }

    @Test func replyAfterCloseIsIgnored() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        _ = Reducer.reduce(&state, .key(.character("d")))
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: details(1)))
        #expect(state.detailPane == nil)
    }

    @Test func pidReuseWithNewStartTimeDoesNotAcceptOldReply() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        let reused = ProcessDetails(identity: Fixtures.identity(1, start: 999), commandLine: .value(.init(arguments: ["evil"])))
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: reused))
        #expect(state.detailPane?.details == nil)
    }

    @Test func cachedDetailsShowWhileFreshOnesLoad() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: details(1)))
        _ = Reducer.reduce(&state, .key(.character("d"))) // close
        let effects = Reducer.reduce(&state, .key(.character("d")))
        #expect(state.detailPane?.details == details(1))
        #expect(effects.count == 1) // still asks for a fresh read
    }

    @Test func newSnapshotReloadsDetailsOfTheOpenPane() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        let effects = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(2, [1, 2, 3].map { Fixtures.process($0) })))
        #expect(effects == [.loadDetails(identity: Fixtures.identity(1), generation: 2)])
    }

    @Test func unavailableCommandLineIsKeptAsUnavailable() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("d")))
        let d = ProcessDetails.unavailable(Fixtures.identity(1), .permissionDenied)
        _ = Reducer.reduce(&state, .detailsLoaded(generation: 1, details: d))
        #expect(state.detailPane?.details?.commandLine == .unavailable(.permissionDenied))
    }

    @Test func nothingOpensWithNoRows() {
        var state = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        #expect(Reducer.reduce(&state, .key(.character("d"))) == [])
        #expect(state.detailPane == nil)
    }
}

@Suite struct TreeReducerTests {
    private func proc(_ pid: Int32, parent: Int32, name: String = "p") -> ProcessSummary {
        var p = Fixtures.process(pid, name: "\(name)\(pid)")
        p.parentPID = .value(parent)
        return p
    }

    private func loaded() -> AppState {
        var state = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        let rows = [proc(1, parent: 0), proc(2, parent: 1), proc(3, parent: 2), proc(4, parent: 1), proc(9, parent: 77)]
        _ = Reducer.reduce(&state, .snapshot(Fixtures.snapshot(1, rows)))
        return state
    }

    @Test func tTogglesTreeOrderAndDepths() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("t")))
        #expect(state.treeMode)
        #expect(state.rows.map(\.identity.pid) == [1, 2, 3, 4, -1, 9])
        #expect(state.rowDepths == [0, 1, 2, 1, 0, 1])
        _ = Reducer.reduce(&state, .key(.character("t")))
        #expect(!state.treeMode)
        #expect(state.rowDepths.isEmpty)
        #expect(state.rows.map(\.identity.pid) == [1, 2, 3, 4, 9])
    }

    @Test func selectionSurvivesModeChanges() {
        var state = loaded()
        for _ in 0..<2 { _ = Reducer.reduce(&state, .key(.down)) } // pid 3
        _ = Reducer.reduce(&state, .key(.character("t")))
        #expect(state.selection == Fixtures.identity(3))
        _ = Reducer.reduce(&state, .key(.character("t")))
        #expect(state.selection == Fixtures.identity(3))
    }

    @Test func filterInTreeModeAddsContextRows() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("t")))
        _ = Reducer.reduce(&state, .key(.character("/")))
        for ch in "p3" { _ = Reducer.reduce(&state, .key(.character(ch))) }
        #expect(state.rows.map(\.identity.pid) == [1, 2, 3])
        #expect(state.contextRows == [Fixtures.identity(1), Fixtures.identity(2)])
    }

    @Test func groupRowCannotBeOpenedOrSignalled() {
        var state = loaded()
        _ = Reducer.reduce(&state, .key(.character("t")))
        _ = Reducer.reduce(&state, .key(.end))
        _ = Reducer.reduce(&state, .key(.up)) // the "Unattached" row
        #expect(state.rows[state.selectedIndex ?? 0].isSynthetic)
        #expect(Reducer.reduce(&state, .key(.character("d"))) == [])
        #expect(state.detailPane == nil)
        _ = Reducer.reduce(&state, .key(.character("x")))
        #expect(state.signalWorkflow == nil)
    }
}

@Suite struct SignalWorkflowTests {
    private func state(
        uid: UInt32 = 501, path: String = "/Applications/Thing.app/thing", pid: Int32 = 500,
        start: UInt64? = 100, own: Int32 = 4242
    ) -> AppState {
        var s = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        s.ownPID = own
        var p = Fixtures.process(pid, start: start ?? 100, name: "thing", uid: uid, path: path)
        if start == nil { p.identity = ProcessIdentity(pid: pid, start: nil) }
        _ = Reducer.reduce(&s, .snapshot(Fixtures.snapshot(1, [p])))
        return s
    }

    private func press(_ s: inout AppState, _ key: KeyEvent) -> [Effect] { Reducer.reduce(&s, .key(key)) }

    private var identity500: ProcessIdentity { Fixtures.identity(500) }

    @Test func xOpensDialogDefaultingToSIGTERMAndSendsNothing() {
        var s = state()
        #expect(press(&s, .character("x")) == [])
        #expect(s.signalWorkflow?.request.signal == .term)
        #expect(s.signalWorkflow?.stage == .confirm)
        #expect(s.signalWorkflow?.request.identity == identity500)
        #expect(s.signalWorkflow?.request.name == "thing")
    }

    @Test func ordinaryTargetIsSentAfterOneExplicitConfirmation() {
        var s = state()
        _ = press(&s, .character("x"))
        let effects = press(&s, .enter)
        guard case .sendSignal(let request)? = effects.first else {
            Issue.record("expected send")
            return
        }
        #expect(request.signal == .term)
        #expect(s.signalWorkflow?.stage == .sending)
    }

    @Test func yAlsoConfirmsStageOne() {
        var s = state()
        _ = press(&s, .character("x"))
        #expect(press(&s, .character("y")).count == 1)
    }

    @Test func nothingElseConfirms() {
        var s = state()
        _ = press(&s, .character("x"))
        for key in [KeyEvent.character("z"), .character(" "), .down, .tab, .character("q"), .unknown] {
            #expect(press(&s, key) == [])
        }
        #expect(s.signalWorkflow?.stage == .confirm) // and `q` did not quit
    }

    @Test func nAndEscapeCancel() {
        for key: KeyEvent in [.character("n"), .escape] {
            var s = state()
            _ = press(&s, .character("x"))
            #expect(press(&s, key) == [])
            #expect(s.signalWorkflow == nil)
        }
    }

    @Test func rootOwnedTargetNeedsASecondDistinctConfirmation() {
        var s = state(uid: 0)
        _ = press(&s, .character("x"))
        #expect(s.signalWorkflow?.request.isProtected == true)
        #expect(press(&s, .enter) == [])
        #expect(s.signalWorkflow?.stage == .confirmProtected)
        #expect(press(&s, .enter) == [], "Enter must not satisfy the second stage")
        #expect(s.signalWorkflow?.stage == .confirmProtected)
        #expect(press(&s, .character("y")).count == 1)
        #expect(s.signalWorkflow?.stage == .sending)
    }

    @Test func systemPathTargetIsProtectedAndLookalikeIsNot() {
        var protectedState = state(path: "/usr/libexec/thing")
        _ = press(&protectedState, .character("x"))
        #expect(protectedState.signalWorkflow?.request.isProtected == true)
        var lookalike = state(path: "/usrlocal/bin/thing")
        _ = press(&lookalike, .character("x"))
        #expect(lookalike.signalWorkflow?.request.isProtected == false)
    }

    @Test func changingSignalResetsGrantedConfirmation() {
        var s = state(uid: 0)
        _ = press(&s, .character("x"))
        _ = press(&s, .enter) // stage 1 granted
        _ = press(&s, .right)
        #expect(s.signalWorkflow?.stage == .confirm)
        #expect(s.signalWorkflow?.request.signal == .kill)
        #expect(press(&s, .character("y")) == [])  // y at stage 1 only advances
        #expect(s.signalWorkflow?.stage == .confirmProtected)
        _ = press(&s, .left)
        #expect(s.signalWorkflow?.stage == .confirm)
        #expect(s.signalWorkflow?.request.signal == .term)
    }

    @Test func signalsCycleThroughTheAllowList() {
        var s = state()
        _ = press(&s, .character("x"))
        var seen = [s.signalWorkflow!.request.signal]
        for _ in 0..<ControlSignal.allCases.count { _ = press(&s, .right); seen.append(s.signalWorkflow!.request.signal) }
        #expect(seen.first == seen.last)
        #expect(Set(seen) == Set(ControlSignal.allCases))
        _ = press(&s, .left)
        #expect(s.signalWorkflow?.request.signal == .cont) // wraps backwards from TERM
    }

    @Test func pidOneSelfAndInvalidTargetsNeverOpenADialog() {
        for (pid, message) in [(Int32(1), "protected"), (4242, "protected"), (100_000, "valid process")] {
            var s = state(pid: pid)
            _ = press(&s, .character("x"))
            #expect(s.signalWorkflow == nil)
            #expect(s.messages.last?.kind == .signalResult)
            #expect(s.messages.last?.text.contains(message) == true)
        }
    }

    @Test func unverifiableIdentityNeverOpensADialog() {
        var s = state(start: nil)
        _ = press(&s, .character("x"))
        #expect(s.signalWorkflow == nil)
        #expect(s.messages.last?.text.contains("cannot be verified") == true)
    }

    @Test func navigationIsIgnoredWhileTheDialogIsOpenAndTargetStaysCaptured() {
        var s = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        _ = Reducer.reduce(&s, .snapshot(Fixtures.snapshot(1, [Fixtures.process(500), Fixtures.process(501)])))
        _ = press(&s, .character("x"))
        _ = press(&s, .down)
        _ = press(&s, .character("j"))
        #expect(s.selection == Fixtures.identity(500))
        #expect(s.signalWorkflow?.request.identity == Fixtures.identity(500))
    }

    @Test func targetExitingOrPIDReuseMidConfirmationCancelsTheDialog() {
        var s = state()
        _ = press(&s, .character("x"))
        // Same PID, different start time: a reused PID is a different identity.
        _ = Reducer.reduce(&s, .snapshot(Fixtures.snapshot(2, [Fixtures.process(500, start: 999)])))
        #expect(s.signalWorkflow == nil)
        #expect(s.messages.last?.text.contains("cancelled") == true)
    }

    @Test func filteredOutTargetKeepsItsDialog() {
        var s = state()
        _ = press(&s, .character("x"))
        s.filter = (try? ProcessFilter.parse("nomatch").get()) ?? .empty
        _ = Reducer.reduce(&s, .snapshot(Fixtures.snapshot(2, [Fixtures.process(500)])))
        #expect(s.signalWorkflow != nil) // still running, merely hidden
    }

    private func sentRequest(_ s: inout AppState) -> SignalRequest {
        _ = press(&s, .character("x"))
        guard case .sendSignal(let r)? = press(&s, .enter).first else { fatalError("no send") }
        return r
    }

    @Test func successIsReportedAsSignalSentAndTriggersRefresh() {
        var s = state()
        let request = sentRequest(&s)
        let effects = Reducer.reduce(&s, .signalResult(request: request, result: .success(SignalSent(pid: 500, signal: .term))))
        #expect(effects == [.requestRefresh])
        #expect(s.signalWorkflow == nil)
        let text = s.messages.last?.text ?? ""
        #expect(text.hasPrefix("Signal sent:"))
        #expect(!text.lowercased().contains("killed"))
        #expect(text.contains("may still be running"))
    }

    @Test(arguments: [
        (ControlError.permissionDenied, "Permission denied"),
        (.processExited, "no longer exists"),
        (.identityChanged, "different process"),
        (.identityUnavailable, "cannot be verified"),
        (.osFailure(errno: 22), "errno 22"),
    ]) func failuresAreReportedAndCloseTheDialog(error: ControlError, text: String) {
        var s = state()
        let request = sentRequest(&s)
        _ = Reducer.reduce(&s, .signalResult(request: request, result: .failure(error)))
        #expect(s.signalWorkflow == nil)
        #expect(s.messages.last?.text.contains(text) == true)
        #expect(s.messages.last?.text.contains("SIP") == false)
    }

    @Test func cautionChangedReturnsToConfirmationAsProtected() {
        var s = state()
        let request = sentRequest(&s)
        let effects = Reducer.reduce(&s, .signalResult(request: request, result: .failure(.cautionChanged)))
        #expect(effects == [])
        #expect(s.signalWorkflow?.stage == .confirm)
        #expect(s.signalWorkflow?.request.isProtected == true)
        #expect(s.signalWorkflow?.notice != nil)
        // and it now needs both stages
        _ = press(&s, .enter)
        #expect(s.signalWorkflow?.stage == .confirmProtected)
    }

    @Test func resultForADifferentRequestIsIgnored() {
        var s = state()
        var other = sentRequest(&s)
        other.signal = .kill
        _ = Reducer.reduce(&s, .signalResult(request: other, result: .success(SignalSent(pid: 500, signal: .kill))))
        #expect(s.signalWorkflow?.stage == .sending)
        #expect(s.messages.isEmpty)
    }

    @Test func keysAreIgnoredWhileSending() {
        var s = state()
        _ = sentRequest(&s)
        for key in [KeyEvent.enter, .character("y"), .escape, .right] { #expect(press(&s, key) == []) }
        #expect(s.signalWorkflow?.stage == .sending)
    }

    @Test func resultMessageClearsOnTheNextKey() {
        var s = state()
        let request = sentRequest(&s)
        _ = Reducer.reduce(&s, .signalResult(request: request, result: .success(SignalSent(pid: 500, signal: .term))))
        _ = press(&s, .down)
        #expect(s.messages.isEmpty)
    }

    @Test func ctrlCStillQuitsFromTheDialog() {
        var s = state()
        _ = press(&s, .character("x"))
        #expect(press(&s, .ctrl("c")) == [.exit])
    }

    @Test func helpOverlayOpensAndClosesAndEscapeDoesNotQuitIt() {
        var s = state()
        _ = press(&s, .character("?"))
        #expect(s.showHelp)
        #expect(press(&s, .escape) == [])
        #expect(!s.showHelp)
        _ = press(&s, .character("?"))
        #expect(press(&s, .character("q")) == []) // closes help; does not quit
        #expect(!s.showHelp)
    }

    @Test func destructiveSignalIsFlagged() {
        #expect(ControlSignal.kill.isDestructive)
        #expect(ControlSignal.allCases.filter(\.isDestructive) == [.kill])
    }
}

@Suite struct ControlPolicyTests {
    @Test func validationRefusesPIDOneSelfAndOutOfRange() {
        #expect(ProcessControlPolicy.validate(pid: 0, ownPID: 5) == .invalidTarget)
        #expect(ProcessControlPolicy.validate(pid: -1, ownPID: 5) == .invalidTarget)
        #expect(ProcessControlPolicy.validate(pid: Int32.min, ownPID: 5) == .invalidTarget)
        #expect(ProcessControlPolicy.validate(pid: 100_000, ownPID: 5) == .invalidTarget)
        #expect(ProcessControlPolicy.validate(pid: 1, ownPID: 5) == .protectedTarget)
        #expect(ProcessControlPolicy.validate(pid: 5, ownPID: 5) == .protectedTarget)
        #expect(ProcessControlPolicy.validate(pid: 99_999, ownPID: 5) == nil)
        #expect(ProcessControlPolicy.validate(pid: 2, ownPID: 5) == nil)
    }

    @Test func cautionUsesPathComponentsNotPrefixes() {
        #expect(CautionPolicy.isCaution(uid: 501, path: "/System/Library/x"))
        #expect(CautionPolicy.isCaution(uid: 501, path: "/usr/bin/x"))
        #expect(CautionPolicy.isCaution(uid: 501, path: "/sbin/x"))
        #expect(CautionPolicy.isCaution(uid: 501, path: "//usr//bin/x"))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "/usrlocal/x"))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "/Users/me/usr/x"))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "/Systems/x"))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "usr/bin/x")) // relative: not a system path
        #expect(!CautionPolicy.isCaution(uid: 501, path: nil))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "/"))
    }

    @Test func rootAndUnknownOwnerAreCaution() {
        #expect(CautionPolicy.isCaution(uid: 0, path: "/Users/me/x"))
        #expect(CautionPolicy.isCaution(uid: nil, path: "/Users/me/x"))
        #expect(!CautionPolicy.isCaution(uid: 501, path: "/Users/me/x"))
    }

    @Test func signalNumbersAreDistinctAndNamed() {
        #expect(Set(ControlSignal.allCases.map(\.number)).count == ControlSignal.allCases.count)
        #expect(ControlSignal.allCases.allSatisfy { $0.number > 0 && $0.name.hasPrefix("SIG") })
    }
}

@Suite struct KeyBindingsTests {
    @Test func footersComeFromTheTable() {
        #expect(KeyBindings.footer(for: .main) == "q quit  s sort  / filter  t tree  d details  x signal  ? help")
        #expect(KeyBindings.footer(for: .filterEditor) == "Enter keep  Esc cancel")
        #expect(KeyBindings.footer(for: .help) == "Esc close")
    }

    @Test func everyContextHasBindingsAndPrecedenceCoversAllContexts() {
        for context in KeyContext.allCases { #expect(!KeyBindings.bindings(for: context).isEmpty) }
        #expect(Set(KeyBindings.precedence) == Set(KeyContext.allCases))
    }

    @Test func helpListsEveryBinding() {
        let text = KeyBindings.helpLines().joined(separator: "\n")
        for binding in KeyBindings.all { #expect(text.contains(binding.keys) && text.contains(binding.summary)) }
    }

    /// Every documented main-context command must be bound in the reducer.
    @Test func documentedMainKeysDoSomething() {
        var base = AppState(terminalSize: TerminalSize(columns: 80, rows: 24))
        base.ownPID = 4242
        _ = Reducer.reduce(&base, .snapshot(Fixtures.snapshot(1, [Fixtures.process(500), Fixtures.process(501)])))
        let keys: [KeyEvent] = [.character("s"), .character("r"), .character("/"), .character(" "), .character("t"),
                                .character("d"), .character("x"), .character("?"), .down, .character("q")]
        for key in keys {
            var s = base
            let effects = Reducer.reduce(&s, .key(key))
            #expect(s != base || !effects.isEmpty, "\(key) changed nothing")
        }
    }
}
