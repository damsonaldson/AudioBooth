import Combine
import Foundation
import Logging
import Models

#if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
import GoogleCast
#endif

final class CastPlaybackController {
  enum Event {
    case timeUpdate(TimeInterval)
    case stateChanged(AudioPlayer.PlaybackState)
    case seek(TimeInterval)
    case rateChanged(Float)
    case finished
    case error(Error?)
    case sessionStarted
    case sessionEnded
    case sessionUpdated(PlaybackSession)
    case trackChanged(Int)
  }

  var onRequireRemoteSession: (() async -> PlaybackSession?)?
  var onCastSessionEnded: (() -> Void)?

  private(set) var currentTrackIndex: Int = 0
  private(set) var isPlaying: Bool = false
  private(set) var isBuffering: Bool = false

  var isPlaybackActive: Bool {
    isPlaying || isBuffering
  }

  var isConnected: Bool {
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.isSessionActive
    #else
    false
    #endif
  }

  let events = PassthroughSubject<Event, Never>()

  private var pendingSeekTarget: TimeInterval?
  private var tracks: [Track] = []
  private var session: PlaybackSession?
  private var coverURL: URL?
  private var playbackRate: Float = 1.0
  private var wantsPlayback: Bool = false
  private var reportedTime: TimeInterval?
  private var loadTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  init() {
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.events
      .sink { [weak self] event in
        self?.handleCastEvent(event)
      }
      .store(in: &cancellables)
    #endif
  }

  func updateContext(
    session: PlaybackSession,
    tracks: [Track],
    currentTrackIndex: Int,
    coverURL: URL?,
    rate: Float,
    wantsPlayback: Bool
  ) {
    self.session = session
    self.tracks = tracks
    self.currentTrackIndex = currentTrackIndex
    self.coverURL = coverURL
    self.playbackRate = rate
    self.wantsPlayback = wantsPlayback
  }

  func load(
    session: PlaybackSession,
    tracks: [Track],
    trackIndex: Int,
    offset: TimeInterval,
    coverURL: URL?,
    rate: Float,
    autoPlay: Bool
  ) {
    loadTask?.cancel()
    self.session = session
    self.tracks = tracks
    self.currentTrackIndex = trackIndex
    self.coverURL = coverURL
    self.playbackRate = rate
    self.wantsPlayback = autoPlay
    self.pendingSeekTarget = nil

    guard tracks.indices.contains(trackIndex) else {
      events.send(.error(nil))
      return
    }

    let track = tracks[trackIndex]
    self.reportedTime = track.startOffset + offset

    if let url = session.remoteURL(for: track) {
      castLoad(track: track, url: url, offset: offset, autoPlay: autoPlay)
      return
    }

    loadTask = Task { [weak self] in
      defer { self?.loadTask = nil }
      guard let self, let remoteSession = await self.onRequireRemoteSession?(), !Task.isCancelled else {
        self?.events.send(.error(nil))
        return
      }

      self.session = remoteSession
      self.events.send(.sessionUpdated(remoteSession))

      let resolvedTracks = remoteSession.tracks.isEmpty ? self.tracks : remoteSession.tracks
      self.tracks = resolvedTracks

      guard resolvedTracks.indices.contains(trackIndex),
            let url = remoteSession.remoteURL(for: resolvedTracks[trackIndex]) else {
        self.events.send(.error(nil))
        return
      }

      self.castLoad(
        track: resolvedTracks[trackIndex],
        url: url,
        offset: offset,
        autoPlay: self.wantsPlayback
      )
    }
  }

  func play() {
    wantsPlayback = true
    guard loadTask == nil else { return }
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.play()
    #endif
  }

  func pause() {
    wantsPlayback = false
    loadTask?.cancel()
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.pause()
    #endif
  }

  func stop() {
    wantsPlayback = false
    isPlaying = false
    isBuffering = false
    pendingSeekTarget = nil
    reportedTime = nil
    loadTask?.cancel()
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.pause()
    #endif
  }

  func seek(to time: TimeInterval) {
    let (targetIndex, offset) = trackAndOffset(for: time)
    pendingSeekTarget = time
    reportedTime = time
    events.send(.seek(time))

    if targetIndex != currentTrackIndex, let session {
      currentTrackIndex = targetIndex
      events.send(.trackChanged(targetIndex))
      load(
        session: session,
        tracks: tracks,
        trackIndex: targetIndex,
        offset: offset,
        coverURL: coverURL,
        rate: playbackRate,
        autoPlay: wantsPlayback
      )
      pendingSeekTarget = time
      return
    }

    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.seek(to: offset) { [weak self] _ in
      guard let self, self.pendingSeekTarget == time else { return }
      self.pendingSeekTarget = nil
    }
    #endif
  }

  func setRate(_ rate: Float) {
    playbackRate = rate
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.setRate(rate)
    #endif
    events.send(.rateChanged(rate))
  }

  func setVolume(_ volume: Float) {
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.setVolume(volume)
    #endif
  }

  func currentTime(fallback: TimeInterval) -> TimeInterval {
    if let pendingSeekTarget {
      return pendingSeekTarget
    }
    return reportedTime ?? fallback
  }

  func isPositioned(at target: TimeInterval, fallback: TimeInterval) -> Bool {
    if let pendingSeekTarget {
      return abs(pendingSeekTarget - target) <= 1
    }
    return abs(currentTime(fallback: fallback) - target) <= 1
  }
}

private extension CastPlaybackController {
  func castLoad(track: Track, url: URL, offset: TimeInterval, autoPlay: Bool) {
    #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
    CastManager.shared.load(
      streamURL: url,
      title: session?.displayTitle ?? "Audiobook",
      author: session?.displayAuthor,
      coverURL: coverURL,
      startTime: offset,
      playbackRate: playbackRate,
      contentType: track.mimeType ?? "audio/mpeg",
      autoplay: autoPlay
    )
    #endif
  }

  func trackAndOffset(for time: TimeInterval) -> (Int, TimeInterval) {
    guard !tracks.isEmpty else { return (0, time) }

    let totalDuration = tracks.reduce(0) { $0 + $1.duration }
    let clampedTime = max(0, min(time, totalDuration))

    for (index, track) in tracks.enumerated() {
      let trackEnd = track.startOffset + track.duration
      if clampedTime < trackEnd || index == tracks.count - 1 {
        return (index, clampedTime - track.startOffset)
      }
    }

    return (0, 0)
  }

  #if canImport(GoogleCast) && !targetEnvironment(macCatalyst) && !os(watchOS)
  func handleCastEvent(_ event: CastEvent) {
    switch event {
    case .sessionStarted:
      AppLogger.player.info("Cast session started")
      events.send(.sessionStarted)

    case .sessionEnded:
      AppLogger.player.info("Cast session ended")
      loadTask?.cancel()
      isPlaying = false
      isBuffering = false
      pendingSeekTarget = nil
      onCastSessionEnded?()
      events.send(.sessionEnded)

    case .positionUpdated(let position):
      handlePositionUpdated(position)

    case .stateChanged(let isNowPlaying):
      isPlaying = isNowPlaying
      isBuffering = false
      events.send(.stateChanged(isNowPlaying ? .playing : .paused))

    case .trackFinished:
      handleTrackFinished()

    case .error:
      isPlaying = false
      isBuffering = false
      events.send(.error(nil))
    }
  }

  func handlePositionUpdated(_ trackPosition: TimeInterval) {
    let globalTime: TimeInterval
    if tracks.indices.contains(currentTrackIndex) {
      let track = tracks[currentTrackIndex]
      globalTime = track.startOffset + min(max(0, trackPosition), track.duration)
    } else {
      globalTime = max(0, trackPosition)
    }

    if let target = pendingSeekTarget {
      guard abs(globalTime - target) <= 2 else { return }
      pendingSeekTarget = nil
    }

    reportedTime = globalTime
    events.send(.timeUpdate(globalTime))
  }

  func handleTrackFinished() {
    let nextIndex = currentTrackIndex + 1
    guard tracks.indices.contains(nextIndex), let session else {
      wantsPlayback = false
      isPlaying = false
      isBuffering = false
      events.send(.finished)
      CastManager.shared.disconnect()
      return
    }

    currentTrackIndex = nextIndex
    events.send(.trackChanged(nextIndex))
    load(
      session: session,
      tracks: tracks,
      trackIndex: nextIndex,
      offset: 0,
      coverURL: coverURL,
      rate: playbackRate,
      autoPlay: true
    )
  }
  #endif
}
