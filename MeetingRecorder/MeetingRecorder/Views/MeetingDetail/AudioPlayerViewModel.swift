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

        // Observe duration
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard duration.isValid, !duration.isIndefinite else { return }
                self?.duration = duration.seconds
            }
            .store(in: &cancellables)

        // Observe playback end
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
            .store(in: &cancellables)

        // Periodic time observer — every 0.5s
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.isPlaying else { return }
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
        currentTime = 0
        duration = 0
        cancellables.removeAll()
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func setSpeed(_ newSpeed: Float) {
        speed = newSpeed
        if isPlaying { player?.rate = newSpeed }
    }
}
