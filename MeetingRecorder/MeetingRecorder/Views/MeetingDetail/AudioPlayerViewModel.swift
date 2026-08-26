//
//  AudioPlayerViewModel.swift
//  MeetingRecorder
//
//  AVPlayer wrapper for the meeting detail audio player.
//

import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AudioPlayerViewModel: ObservableObject {

    static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var speed: Float = 1.0
    @Published var isLoaded = false

    // True while the user is dragging the slider — suppresses the periodic update
    var isScrubbing = false

    var speedLabel: String { "\(String(format: "%.2g", speed))×" }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Load

    func load(url: URL) {
        stop()

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        self.player = p

        // Load duration asynchronously from the asset — avoids the "always 0" bug
        // caused by reading duration before AVPlayerItem finishes loading.
        Task { [weak self] in
            guard let self else { return }
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.isValid, !d.isIndefinite {
                self.duration = d.seconds
                self.isLoaded = true
            }
        }

        // Observe playback end
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
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
        player?.play()
        player?.rate = speed
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        if let p = player, let obs = timeObserver {
            p.removeTimeObserver(obs)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        isScrubbing = false
        cancellables.removeAll()
    }

    func seek(to time: TimeInterval) {
        let t = max(0, min(time, duration))
        let cmTime = CMTime(seconds: t, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        if isPlaying { player?.rate = newSpeed }
    }
}
