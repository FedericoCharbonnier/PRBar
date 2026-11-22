import PRBarCore

enum RespondStagesTests {
    static let cases: [TestCase] = [
        TestCase("etapas: el reloj anota cuándo empieza y termina cada una") {
            var timeline = RespondStageTimeline()
            timeline.note(phase: .analyzing(agents: 2), runningTests: false, at: t0)
            timeline.note(phase: .implementing(done: 0, total: 2), runningTests: false, at: t0.addingTimeInterval(30))
            timeline.note(phase: .readyToPush(draftStub, resultStub), runningTests: true, at: t0.addingTimeInterval(90))
            let stages = timeline.stages(phase: .readyToPush(draftStub, resultStub), runningTests: true, testsRan: false)
            try expectEqual(stages.map(\.status), [.done, .done, .running])
            try expectEqual(stages[0].duration(now: t0.addingTimeInterval(100)), 30)
            try expectEqual(stages[1].duration(now: t0.addingTimeInterval(100)), 60)
            try expectEqual(stages[2].duration(now: t0.addingTimeInterval(100)), 10)
        },
        TestCase("etapas: listo para elegir, sin tests y fallido") {
            let empty = RespondStageTimeline()
            try expectEqual(empty.stages(phase: .ready(draftStub), runningTests: false, testsRan: false).map(\.status),
                            [.done, .pending, .pending])
            try expectEqual(empty.stages(phase: .readyToPush(draftStub, resultStub), runningTests: false, testsRan: false)
                                .map(\.status), [.done, .done, .pending])
            try expectEqual(empty.stages(phase: .readyToPush(draftStub, resultStub), runningTests: false, testsRan: true)
                                .map(\.status), [.done, .done, .done])
            var failed = RespondStageTimeline()
            failed.note(phase: .implementing(done: 0, total: 1), runningTests: false, at: t0)
            try expectEqual(failed.stages(phase: .failed("x", logURL: nil), runningTests: false, testsRan: false)
                                .map(\.status), [.done, .failed, .pending])
        },
    ]
}
