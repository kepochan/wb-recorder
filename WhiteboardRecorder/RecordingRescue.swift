import AppKit

/// The server keeps no copy of the audio, so an `.m4a` the user does not know
/// about is a lost meeting. This is the pair of safety nets that sit outside the
/// normal flow: the hand-off when the app is quit mid-flight, and the sweep at
/// launch that picks up whatever an earlier run never handed over.
extension MenuBarController {

    // MARK: - Quitting mid-flight

    /// Called from `applicationShouldTerminate`. `NSApplication.terminate` does
    /// not unwind anything: without this the capture object is never released,
    /// `AudioFileWriter.finish()` never runs, and the file is left without its
    /// `moov` atom — a file no player can open, in a folder nothing lists,
    /// with the user told nothing and the ESP32 still red.
    ///
    /// So the exit is held back until the capture is closed properly, the file
    /// is in the user's save folder, the light is out and the user has been
    /// told where the meeting went.
    func prepareForTermination() -> NSApplication.TerminateReply {
        if case .idle = flow.state { return .terminateNow }

        switch flow.state {
        case .configuring, .recording:
            // Closes the encoder and finalises the container. Even when it
            // throws, the partial file it names is worth rescuing.
            do {
                currentFileURL = try capture.stop()
            } catch {
                currentFileURL = partialFileURL(for: error)
            }
        case .idle, .uploading, .failed:
            // Capture already stopped; `currentFileURL` is the file the upload
            // was sending, or the one the failure alert is holding. A quit here
            // kills that Task, which is exactly why the file must be rescued.
            break
        }

        configurationWindow?.close()

        let destination = moveCurrentFileToSaveFolder()
        turnOffESP32AndWait()

        if let destination {
            // Named by folder and file rather than by full path: inside the
            // sandbox `~/Downloads` resolves to a container path the user has
            // never seen and cannot match to anything in Finder.
            showAlert(title: "Enregistrement mis à l'abri",
                      message: """
                      L'enregistrement en cours a été arrêté proprement et déposé dans \
                      \(saveFolderDisplayName), sous le nom :

                      \(destination.lastPathComponent)
                      """)
        } else if currentFileURL == nil {
            showAlert(title: "Enregistrement perdu",
                      message: "L'enregistrement en cours n'a pas pu être récupéré : aucun fichier audio n'a été trouvé.")
        }
        // Otherwise the move failed and `moveCurrentFileToSaveFolder` has
        // already told the user where the file still is.

        return .terminateNow
    }

    /// Everything above runs synchronously on purpose. Deferring the work with
    /// `.terminateLater` looks like the tidier option, but the window it opens
    /// is pumped by `-[NSApplication _shouldTerminate]` in a private event mode
    /// that never services the main dispatch queue: a `Task { @MainActor }`
    /// scheduled there never runs, `reply(toApplicationShouldTerminate:)` is
    /// never sent, and the app hangs on quit forever. So the one asynchronous
    /// step — the ESP32 request — is awaited off the main thread and bounded.
    private func turnOffESP32AndWait() {
        guard let host = preferences.esp32Host else { return }
        let display = ESP32Display(host: host)
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            await display.setRecording(false)
            finished.signal()
        }
        // The request itself times out at 2s; this only guarantees that a quit
        // can never be held up by the gadget.
        _ = finished.wait(timeout: .now() + 3)
    }

    // MARK: - Sweeping what an earlier run left behind

    /// Run once at launch. Anything left in the recordings folder was stranded
    /// by a crash, a kill or a move that failed; nothing else in the app ever
    /// lists that folder, so without this those files stay there invisibly
    /// forever. They are moved into the save folder and named once, out loud.
    func sweepStrandedRecordings() {
        let stranded = RecordingStorage.strandedFiles()
        guard !stranded.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"

        var moved: [URL] = []
        var failures = 0
        for file in stranded {
            // The meeting's title is long gone; its date is not.
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let destination = uniqueURL(in: preferences.saveFolder,
                                        name: "reunion-recuperee-\(formatter.string(from: date))")
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                moved.append(destination)
            } catch {
                failures += 1
            }
        }

        var lines: [String] = []
        if !moved.isEmpty {
            let headline = moved.count == 1
                ? "Un enregistrement d'une session précédente a été retrouvé et déposé dans"
                : "\(moved.count) enregistrements de sessions précédentes ont été retrouvés et déposés dans"
            lines.append("""
            \(headline) \(saveFolderDisplayName) :

            \(moved.map(\.lastPathComponent).joined(separator: "\n"))
            """)
        }
        if failures > 0 {
            lines.append("""
            \(failures) fichier(s) n'ont pas pu être déplacés et se trouvent toujours ici :

            \(RecordingStorage.directory.path)
            """)
        }

        guard !lines.isEmpty else { return }
        showAlert(title: moved.isEmpty ? "Enregistrements à récupérer" : "Enregistrements récupérés",
                  message: lines.joined(separator: "\n\n"))
    }
}
