//
//  AudioPlayerViewModel.swift
//  MeetingRecorder
//
//  AVPlayer wrapper for the meeting detail recording player.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioPlayerViewModel: ObservableObject {

    enum LoadError: Equatable {
        case fileMissing
        case invalidFile
    }

    static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var speed: Float = 1.0
    @Published var isLoaded = false
    @Published private(set) var loadError: LoadError?
    @Published private(set) var avPlayer: AVPlayer?

    // True while the user is dragging the slider — suppresses the periodic update
    var isScrubbing = false

    var speedLabel: String { "\(String(format: "%.2g", speed))×" }

    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Load

    @discardableResult
    func load(url: URL) -> Task<Void, Never>? {
        stop()

        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = .fileMissing
            return nil
        }

        let task = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let loadedDuration = try? await asset.load(.duration),
                  loadedDuration.isValid,
                  !loadedDuration.isIndefinite,
                  loadedDuration.seconds.isFinite,
                  loadedDuration.seconds > 0 else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.loadError = .invalidFile
                }
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.configurePlayer(url: url, duration: loadedDuration.seconds)
            }
        }
        loadTask = task
        return task
    }

    private func configurePlayer(url: URL, duration: TimeInterval) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        self.avPlayer = p
        self.duration = duration
        self.isLoaded = true

        // Observe playback end
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.avPlayer?.seek(to: .zero)
            }
            .store(in: &cancellables)

        // Periodic time observer — always update currentTime, scrub suppresses it
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = time.seconds
        }
    }

    // MARK: - Controls

    func play() {
        avPlayer?.play()
        avPlayer?.rate = speed
        isPlaying = true
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let p = avPlayer, let obs = timeObserver {
            p.removeTimeObserver(obs)
        }
        avPlayer?.pause()
        avPlayer = nil
        timeObserver = nil
        isPlaying = false
        isLoaded = false
        loadError = nil
        currentTime = 0
        duration = 0
        isScrubbing = false
        cancellables.removeAll()
    }

    func seek(to time: TimeInterval) {
        let t = max(0, min(time, duration))
        let cmTime = CMTime(seconds: t, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        if isPlaying { avPlayer?.rate = newSpeed }
    }
}
