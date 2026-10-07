import Foundation

func expect(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    guard try condition() else { throw AppError("Assertion failed at \(file):\(line)") }
}

func expectThrows(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
    do { try operation() } catch { return }
    throw AppError("Expected an error at \(file):\(line)")
}

let tests: [(String, () throws -> Void)] = [
    ("Preserve existing mappings", { try KeyMappingTests().testInstallPreservesOtherMappingsAndReplacesExistingCapsLockMapping() }),
    ("Preserve concurrent mapping changes", { try KeyMappingTests().testRestorePreservesUnrelatedChangesMadeDuringSession() }),
    ("Respect external Caps Lock remaps", { try KeyMappingTests().testRestoreDoesNotOverwriteNewCapsLockMappingFromAnotherApp() }),
    ("Mute and restore every input channel", { try MicrophoneTests().testVolumeFallbackMutesAllChannelsAndRestoresOriginalLevels() }),
    ("Hardware mute and input slider", { try MicrophoneTests().testHardwareMutePreferredAndVolumeSliderWorksWithoutUnmuting() }),
    ("Reject incomplete channel control", { try MicrophoneTests().testRejectsPartiallyControllableMicrophone() }),
    ("Continue muting after a failed channel", { try MicrophoneTests().testMutingContinuesAfterOneChannelFails() }),
    ("Reassert mute after external gain change", { try MicrophoneTests().testIdleReassertsMuteAfterAnotherAppChangesGain() }),
    ("Switch microphones safely", { try MicrophoneTests().testDeviceSwitchMutesBothDevicesAndRequiresFreshPress() }),
    ("Recover original gain after a crash", { try MicrophoneTests().testCrashRecoveryRetainsOriginalVolumeInsteadOfCapturingZero() }),
    ("Handle an initially muted input", { try MicrophoneTests().testInitiallyZeroVolumeGetsUsableTalkLevelButRestoresZeroOnQuit() }),
    ("Recover after a microphone is unplugged", { try MicrophoneTests().testUnpluggedMicrophoneDoesNotBlockSwitchToNewInput() }),
    ("Mute new input when old mute fails", { try MicrophoneTests().testOldMuteFailureStillMutesAndRecordsNewInput() }),
    ("Retry failed microphone journal writes", { try MicrophoneTests().testFailedJournalWriteCannotBeBypassedOnRetry() }),
    ("Drop a stale queued press", { try MicrophoneTests().testCancelledQueuedPressNeverRaisesGain() }),
    ("Cancel unmute during device read", { try MicrophoneTests().testReleaseDuringSlowReadPreventsUnmuteWrite() }),
    ("Remute after release during device write", { try MicrophoneTests().testReleaseDuringWriteRemutesBeforeNextChannelOpens() }),
    ("Retry failed keyboard journal writes", { try KeyMappingTests().testFailedJournalWriteNeverInstallsUnrecordedMapping() }),
    ("Complete failed startup on retry", { try RuntimeTests().testStartupRetryCompletesCallbacksAndMonitoring() }),
    ("Serialize stale watchdog recovery", { try RuntimeTests().testStaleWatchdogWaitsForLockThenSkipsNewSession() }),
    ("Recover the owning session only once", { try RuntimeTests().testMatchingWatchdogRecoversOnceAndKeepsMicrophoneRecord() }),
    ("Upgrade the original session journal", { try RuntimeTests().testLegacyJournalWithoutSessionIDCanBeClaimed() })
]

var failed = 0
for (name, test) in tests {
    do { try test(); print("PASS: \(name)") }
    catch { failed += 1; fputs("FAIL: \(name): \(error.localizedDescription)\n", stderr) }
}
print("\(tests.count - failed)/\(tests.count) tests passed")
exit(failed == 0 ? 0 : 1)
