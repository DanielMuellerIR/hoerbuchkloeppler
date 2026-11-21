import ArgumentParser
import Darwin
import Foundation
import HoerbuchkloepplerCore

final class InterruptState: @unchecked Sendable {
    private enum Phase {
        case preparing
        case converting
        case finished
    }

    private let condition = NSCondition()
    private var receivedSignal: Int32?
    private var pendingSignals = 0
    private var announced = false
    private var phase: Phase = .preparing

    func install(for session: ConversionSession) -> [DispatchSourceSignal] {
        let queue = DispatchQueue(label: "de.hoerbuchkloeppler.signals")
        return [SIGINT, SIGTERM].map { signal in
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler(handler: makeInterruptHandler(
                session: session,
                interruptState: self,
                signal: signal
            ))
            Darwin.signal(signal, SIG_IGN)
            source.resume()
            return source
        }
    }

    var shouldCancelPreparation: Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase == .preparing
    }

    /// Sperrt den Phasenabschluss, bevor der Handler Core-Cancellation aufruft.
    /// Sonst kann dessen terminales Event die CLI zwischen akzeptiertem Cancel
    /// und `recordSignal` mit Exit 0/1 statt 128+Signal beenden.
    func beginSignal() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard phase != .finished else { return false }
        pendingSignals += 1
        return true
    }

    /// Akzeptiert das Signal nur, solange noch Arbeit abgebrochen werden kann.
    /// Ein vom Core nach dem letzten atomaren Commit abgelehnter Cancel darf
    /// keinen falschen Exit 130 mehr erzeugen.
    func recordSignal(
        _ signal: Int32,
        conversionOutcome: ConversionCancellationOutcome,
        preparationCancelled: Bool
    ) -> Bool {
        condition.lock()
        defer {
            pendingSignals -= 1
            condition.broadcast()
            condition.unlock()
        }
        guard phase != .finished else { return false }
        var accepted = false
        switch conversionOutcome {
        case .cancelled:
            accepted = true
        case .noActiveConversion:
            // In der Vorbereitung oder in der winzigen Lücke direkt vor dem
            // synchronen Anlegen des Conversion-Contexts bleibt das Signal offen.
            accepted = true
        case .rejected:
            accepted = phase == .preparing && preparationCancelled
        }
        if accepted, receivedSignal == nil { receivedSignal = signal }
        return accepted
    }

    func beginConversion() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard pendingSignals == 0, receivedSignal == nil else { return false }
        phase = .converting
        return true
    }

    /// Wartet auf einen bereits laufenden Signal-Handler, bevor die Phase
    /// unwiderruflich geschlossen wird. Der Handler braucht dafür keinen Main
    /// Actor und kann die Condition auch dann auflösen, wenn dieser Thread wartet.
    func finishExecution() -> Int32? {
        condition.lock()
        while pendingSignals > 0 { condition.wait() }
        phase = .finished
        let signal = receivedSignal
        condition.unlock()
        return signal
    }

    var wasReceived: Bool {
        condition.lock()
        defer { condition.unlock() }
        return receivedSignal != nil || pendingSignals > 0
    }

    func waitForExitCode() -> ExitCode? {
        condition.lock()
        while pendingSignals > 0 { condition.wait() }
        let signal = receivedSignal
        condition.unlock()
        return signal.map { ExitCode(128 + $0) }
    }

    func takeUnannouncedSignal() -> Int32? {
        condition.lock()
        defer { condition.unlock() }
        guard let signal = receivedSignal, !announced else { return nil }
        announced = true
        return signal
    }
}

func readLine(unlessInterrupted state: InterruptState) -> String? {
    var descriptor = pollfd(
        fd: FileHandle.standardInput.fileDescriptor,
        events: Int16(POLLIN),
        revents: 0
    )
    while !state.wasReceived {
        let result = Darwin.poll(&descriptor, 1, 100)
        if result > 0 { return Swift.readLine() }
        if result < 0, errno != EINTR { return nil }
    }
    return nil
}

/// Erzeugt den GCD-Handler außerhalb des Main Actors. Wird die Closure direkt
/// auf dem Main Actor angelegt, könnte sie dessen Isolation erben und auf
/// der Signal-Queue einen Laufzeitfehler auslösen.
private func makeInterruptHandler(
    session: ConversionSession,
    interruptState: InterruptState,
    signal: Int32
) -> @Sendable () -> Void {
    {
        guard interruptState.beginSignal() else { return }
        let preparationCancelled = interruptState.shouldCancelPreparation
            ? session.cancelPreparation()
            : false
        let outcome = FFmpegWrapper.cancelConversion(session: session)
        _ = interruptState.recordSignal(
            signal,
            conversionOutcome: outcome,
            preparationCancelled: preparationCancelled
        )
    }
}
