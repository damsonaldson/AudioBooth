import Combine
import Foundation
import Models
import Testing
@testable import AudioBooth

private final class MockCastClient: CastClientProtocol {
  struct LoadCall: Equatable {
    let streamURL: URL
    let title: String
    let author: String?
    let coverURL: URL?
    let startTime: TimeInterval
    let playbackRate: Float
    let contentType: String
    let autoplay: Bool
  }

  var isConnected: Bool = true
  let events = PassthroughSubject<CastEvent, Never>()

  private(set) var loadCalls: [LoadCall] = []
  private(set) var playCallCount = 0
  private(set) var pauseCallCount = 0
  private(set) var seekCalls: [TimeInterval] = []
  private(set) var rateCalls: [Float] = []
  private(set) var disconnectCallCount = 0

  private var pendingSeekCompletions: [(Bool) -> Void] = []

  func load(
    streamURL: URL,
    title: String,
    author: String?,
    coverURL: URL?,
    startTime: TimeInterval,
    playbackRate: Float,
    contentType: String,
    autoplay: Bool
  ) {
    loadCalls.append(
      LoadCall(
        streamURL: streamURL,
        title: title,
        author: author,
        coverURL: coverURL,
        startTime: startTime,
        playbackRate: playbackRate,
        contentType: contentType,
        autoplay: autoplay
      )
    )
  }

  func play() {
    playCallCount += 1
  }

  func pause() {
    pauseCallCount += 1
  }

  func seek(to time: TimeInterval, completion: ((Bool) -> Void)?) {
    seekCalls.append(time)
    if let completion {
      pendingSeekCompletions.append(completion)
    }
  }

  func completeSeek(at index: Int = 0, success: Bool = true) {
    guard pendingSeekCompletions.indices.contains(index) else { return }
    let completion = pendingSeekCompletions.remove(at: index)
    completion(success)
  }

  func setRate(_ rate: Float) {
    rateCalls.append(rate)
  }

  func disconnect() {
    disconnectCallCount += 1
  }
}

private func makeTracks(durations: [TimeInterval] = [100, 200, 150]) -> [Track] {
  var offset: TimeInterval = 0
  return durations.enumerated().map { index, duration in
    let track = Track(index: index, startOffset: offset, duration: duration, mimeType: "audio/mp4")
    offset += duration
    return track
  }
}

private func makeSession(
  baseURL: URL? = URL(string: "https://abs.example.com/session/1"),
  tracks: [Track] = makeTracks(),
  currentTime: TimeInterval = 0
) -> PlaybackSession {
  let session = PlaybackSession(
    id: "session-1",
    libraryItemID: "item-1",
    startTime: 0,
    currentTime: currentTime,
    duration: tracks.reduce(0) { $0 + $1.duration },
    baseURL: baseURL,
    displayTitle: "Test Book",
    displayAuthor: "Test Author"
  )
  session.tracks = tracks
  return session
}

@Suite("Cast Playback & Session Tests")
struct CastPlaybackTests {
  @Test("PlaybackSession.remoteURL returns remote track URL even when localPath is set")
  func remoteURLIgnoresLocalPath() {
    let tracks = makeTracks(durations: [60, 60])
    tracks[0].relativePath = URL(fileURLWithPath: "/tmp/track0.m4b")
    let session = makeSession(tracks: tracks)

    #expect(session.remoteURL(for: tracks[0]) == URL(string: "https://abs.example.com/session/1/track/0"))
    #expect(session.remoteURL(for: tracks[1]) == URL(string: "https://abs.example.com/session/1/track/1"))
  }

  @Test("PlaybackSession.remoteURL returns nil when baseURL is nil")
  func remoteURLNilWithoutBaseURL() {
    let tracks = makeTracks(durations: [60])
    let session = makeSession(baseURL: nil, tracks: tracks)

    #expect(session.remoteURL(for: tracks[0]) == nil)
  }

  @Test("Loading remote session dispatches expected Cast load parameters")
  func loadRemoteSessionDispatchesLoad() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks()
    let session = makeSession(tracks: tracks)
    let coverURL = URL(string: "https://abs.example.com/cover.jpg")

    controller.load(
      session: session,
      tracks: tracks,
      trackIndex: 1,
      offset: 42,
      coverURL: coverURL,
      rate: 1.5,
      autoPlay: true
    )

    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].streamURL == URL(string: "https://abs.example.com/session/1/track/1"))
    #expect(client.loadCalls[0].startTime == 42)
    #expect(client.loadCalls[0].playbackRate == 1.5)
    #expect(client.loadCalls[0].autoplay == true)
    #expect(client.loadCalls[0].title == "Test Book")
    #expect(client.loadCalls[0].author == "Test Author")
    #expect(client.loadCalls[0].coverURL == coverURL)
  }

  @Test("Loading local-only session awaits onRequireRemoteSession and avoids premature play()")
  func loadLocalSessionRequestsRemoteAndGuardsPrematurePlay() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let localTracks = makeTracks()
    let localSession = makeSession(baseURL: nil, tracks: localTracks)
    let remoteSession = makeSession(tracks: localTracks)

    var receivedEvents: [CastPlaybackController.Event] = []
    let cancellable = controller.events.sink { receivedEvents.append($0) }

    controller.onRequireRemoteSession = {
      try? await Task.sleep(for: .milliseconds(30))
      return remoteSession
    }

    controller.load(
      session: localSession,
      tracks: localTracks,
      trackIndex: 0,
      offset: 25,
      coverURL: nil,
      rate: 1.0,
      autoPlay: false
    )

    // Calling play() while onRequireRemoteSession is in-flight must NOT send client.play()
    controller.play()
    #expect(client.playCallCount == 0)
    #expect(client.loadCalls.isEmpty)

    try? await Task.sleep(for: .milliseconds(80))

    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].autoplay == true)
    #expect(client.loadCalls[0].startTime == 25)
    #expect(receivedEvents.contains { if case .sessionUpdated = $0 { return true }; return false })
    _ = cancellable
  }

  @Test("Loading local-only session emits error when onRequireRemoteSession returns nil")
  func loadLocalSessionEmitsErrorWhenRemoteUnavailable() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let localTracks = makeTracks()
    let localSession = makeSession(baseURL: nil, tracks: localTracks)

    var sawError = false
    let cancellable = controller.events.sink { event in
      if case .error = event { sawError = true }
    }

    controller.onRequireRemoteSession = { nil }
    controller.load(
      session: localSession,
      tracks: localTracks,
      trackIndex: 0,
      offset: 0,
      coverURL: nil,
      rate: 1.0,
      autoPlay: true
    )

    try? await Task.sleep(for: .milliseconds(50))
    #expect(sawError)
    #expect(client.loadCalls.isEmpty)
    _ = cancellable
  }

  @Test("Same-track seek drops stale position polls until seek completes or converges")
  func sameTrackSeekDropsStalePolls() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let session = makeSession(tracks: tracks)

    var timeUpdates: [TimeInterval] = []
    let cancellable = controller.events.sink { event in
      if case .timeUpdate(let t) = event { timeUpdates.append(t) }
    }

    controller.load(
      session: session,
      tracks: tracks,
      trackIndex: 0,
      offset: 10,
      coverURL: nil,
      rate: 1.0,
      autoPlay: true
    )

    controller.seek(to: 80)
    #expect(client.seekCalls == [80])
    #expect(controller.currentTime(fallback: 0) == 80)

    // Stale poll from old position (12s) must be ignored
    client.events.send(.positionUpdated(12))
    #expect(timeUpdates.isEmpty)

    // Completing seek clears pendingSeekTarget and allows subsequent polls
    client.completeSeek(success: true)
    client.events.send(.positionUpdated(81))
    #expect(timeUpdates == [81])
    _ = cancellable
  }

  @Test("Rapid consecutive seeks do not let earlier completion clear newer pendingSeekTarget")
  func rapidSeeksPreserveLatestTarget() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [200])
    let session = makeSession(tracks: tracks)

    var timeUpdates: [TimeInterval] = []
    let cancellable = controller.events.sink { event in
      if case .timeUpdate(let t) = event { timeUpdates.append(t) }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 0, coverURL: nil, rate: 1.0, autoPlay: true)
    controller.seek(to: 50)
    controller.seek(to: 150)

    // First seek completes — must NOT clear pendingSeekTarget (150)
    client.completeSeek(at: 0, success: true)
    client.events.send(.positionUpdated(51))
    #expect(timeUpdates.isEmpty)
    #expect(controller.currentTime(fallback: 0) == 150)

    // Second seek completes — now updates flow
    client.completeSeek(at: 0, success: true)
    client.events.send(.positionUpdated(151))
    #expect(timeUpdates == [151])
    _ = cancellable
  }

  @Test("Cross-track seek updates currentTrackIndex, emits trackChanged, and loads target track")
  func crossTrackSeekLoadsTargetTrack() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 200, 150])
    let session = makeSession(tracks: tracks)

    var changedTracks: [Int] = []
    let cancellable = controller.events.sink { event in
      if case .trackChanged(let idx) = event { changedTracks.append(idx) }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.25, autoPlay: true)
    controller.seek(to: 160) // Track 1 at offset 60

    #expect(controller.currentTrackIndex == 1)
    #expect(changedTracks == [1])
    #expect(client.loadCalls.count == 2)
    #expect(client.loadCalls[1].streamURL == URL(string: "https://abs.example.com/session/1/track/1"))
    #expect(client.loadCalls[1].startTime == 60)
    #expect(client.loadCalls[1].autoplay == true)
    _ = cancellable
  }

  @Test("Track advance on trackFinished loads next track at offset 0")
  func trackFinishedAdvancesToNextTrack() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let session = makeSession(tracks: tracks)

    var changedTracks: [Int] = []
    let cancellable = controller.events.sink { event in
      if case .trackChanged(let idx) = event { changedTracks.append(idx) }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 95, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.trackFinished)

    #expect(controller.currentTrackIndex == 1)
    #expect(changedTracks == [1])
    #expect(client.loadCalls.count == 2)
    #expect(client.loadCalls[1].startTime == 0)
    #expect(client.loadCalls[1].autoplay == true)
    #expect(client.disconnectCallCount == 0)
    _ = cancellable
  }

  @Test("Final trackFinished emits paused before finished without disconnecting Cast session")
  func finalTrackFinishedEmitsFinishedWithoutDisconnecting() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let session = makeSession(tracks: tracks)

    var lifecycleEvents: [String] = []
    let cancellable = controller.events.sink { event in
      switch event {
      case .stateChanged(.paused): lifecycleEvents.append("paused")
      case .finished: lifecycleEvents.append("finished")
      default: break
      }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 99, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.stateChanged(isPlaying: true))
    #expect(controller.isPlaying == true)

    client.events.send(.trackFinished)

    #expect(lifecycleEvents == ["paused", "finished"])
    #expect(controller.isPlaying == false)
    #expect(client.disconnectCallCount == 0)
    _ = cancellable
  }

  @Test("Overlapping controllers do not clobber each other when first is deallocated")
  func overlappingControllersDoNotClobberSubscriptions() {
    let client = MockCastClient()
    var controllerA: CastPlaybackController? = CastPlaybackController(client: client)
    let controllerB = CastPlaybackController(client: client)

    var bPlayingStates: [Bool] = []
    let cancellable = controllerB.events.sink { event in
      if case .stateChanged(let state) = event {
        bPlayingStates.append(state == .playing)
      }
    }

    // Deallocate A while B is active
    _ = controllerA
    controllerA = nil

    client.events.send(.stateChanged(isPlaying: true))
    #expect(controllerB.isPlaying == true)
    #expect(bPlayingStates == [true])
    _ = cancellable
  }

  @Test("Session ended resets state and fires onCastSessionEnded")
  func sessionEndedResetsStateAndNotifies() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks()
    let session = makeSession(tracks: tracks)

    var endedCallbacks = 0
    var sessionEndedEvents = 0
    controller.onCastSessionEnded = { endedCallbacks += 1 }
    let cancellable = controller.events.sink { event in
      if case .sessionEnded = event { sessionEndedEvents += 1 }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.stateChanged(isPlaying: true))
    controller.seek(to: 50)

    client.events.send(.sessionEnded)

    #expect(controller.isPlaying == false)
    #expect(endedCallbacks == 1)
    #expect(sessionEndedEvents == 1)
    _ = cancellable
  }

  @Test("Rate change forwards to Cast client")
  func rateForwardsToClient() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)

    var emittedRates: [Float] = []
    let cancellable = controller.events.sink { event in
      if case .rateChanged(let r) = event { emittedRates.append(r) }
    }

    controller.setRate(1.75)

    #expect(client.rateCalls == [1.75])
    #expect(emittedRates == [1.75])
    _ = cancellable
  }

  @Test("Cancelling remote session load via pause() does not emit error and clears buffering")
  func loadCancellationViaPauseDoesNotEmitError() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks()
    let localSession = makeSession(baseURL: nil, tracks: tracks)
    let remoteSession = makeSession(tracks: tracks)

    var states: [AudioPlayer.PlaybackState] = []
    var sawError = false
    let cancellable = controller.events.sink { event in
      switch event {
      case .stateChanged(let state): states.append(state)
      case .error: sawError = true
      default: break
      }
    }

    controller.onRequireRemoteSession = {
      try? await Task.sleep(for: .milliseconds(60))
      return remoteSession
    }

    controller.load(session: localSession, tracks: tracks, trackIndex: 0, offset: 0, coverURL: nil, rate: 1.0, autoPlay: false)
    controller.play()
    #expect(controller.isBuffering == true)
    #expect(controller.isPlaybackActive == true)
    #expect(states.last == .buffering)

    controller.pause()
    #expect(controller.isBuffering == false)
    #expect(controller.isPlaybackActive == false)
    #expect(states.last == .paused)

    try? await Task.sleep(for: .milliseconds(100))
    #expect(!sawError)
    #expect(client.loadCalls.isEmpty)
    _ = cancellable
  }

  @Test("Superseding remote session load drops first task cleanly without error")
  func loadCancellationViaSubsequentLoadDoesNotEmitError() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks()
    let localSession = makeSession(baseURL: nil, tracks: tracks)
    let remoteSession = makeSession(tracks: tracks)

    var sawError = false
    let cancellable = controller.events.sink { event in
      if case .error = event { sawError = true }
    }

    var callIndex = 0
    controller.onRequireRemoteSession = {
      callIndex += 1
      if callIndex == 1 {
        try? await Task.sleep(for: .milliseconds(80))
      } else {
        try? await Task.sleep(for: .milliseconds(20))
      }
      return remoteSession
    }

    controller.load(session: localSession, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.0, autoPlay: true)
    controller.load(session: localSession, tracks: tracks, trackIndex: 1, offset: 30, coverURL: nil, rate: 1.0, autoPlay: true)

    try? await Task.sleep(for: .milliseconds(120))
    #expect(!sawError)
    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].streamURL == URL(string: "https://abs.example.com/session/1/track/1"))
    #expect(client.loadCalls[0].startTime == 30)
    _ = cancellable
  }

  @Test("Seek clamps negative and past-end targets within track bounds")
  func seekClampsOutOfRangeValues() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 200])
    let session = makeSession(tracks: tracks)

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 20, coverURL: nil, rate: 1.0, autoPlay: true)

    controller.seek(to: -25)
    #expect(controller.currentTrackIndex == 0)
    #expect(client.seekCalls.last == 0)

    controller.seek(to: 9999)
    #expect(controller.currentTrackIndex == 1)
    #expect(client.loadCalls.last?.startTime == 200)
  }

  @Test("isPositioned checks pendingSeekTarget and reportedTime within 1s tolerance")
  func isPositionedRespectsTolerance() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let session = makeSession(tracks: tracks)

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 40, coverURL: nil, rate: 1.0, autoPlay: true)
    #expect(controller.isPositioned(at: 40.5, fallback: 0) == true)
    #expect(controller.isPositioned(at: 42.0, fallback: 0) == false)

    controller.seek(to: 75)
    #expect(controller.isPositioned(at: 75.8, fallback: 0) == true)
    #expect(controller.isPositioned(at: 40.0, fallback: 0) == false)
  }

  @Test("Position updates clamp track bounds and add track startOffset")
  func positionUpdateClampsTrackBounds() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 50])
    let session = makeSession(tracks: tracks)

    var updates: [TimeInterval] = []
    let cancellable = controller.events.sink { event in
      if case .timeUpdate(let t) = event { updates.append(t) }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 1, offset: 0, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.positionUpdated(-10))
    client.events.send(.positionUpdated(999))

    #expect(updates == [100, 150])
    _ = cancellable
  }

  @Test("AudioPlayer sessionStarted captures wantsPlayback before pausing local player")
  func audioPlayerSessionStartedLoadsCastWithAutoPlay() {
    let client = MockCastClient()
    client.isConnected = false
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let session = makeSession(tracks: tracks, currentTime: 125)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 125, duration: 200)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session, cast: controller)

    player.setQueue(for: session)
    player.resume()

    client.isConnected = true
    client.events.send(.sessionStarted)

    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].streamURL == URL(string: "https://abs.example.com/session/1/track/1"))
    #expect(client.loadCalls[0].startTime == 25)
    #expect(client.loadCalls[0].autoplay == true)
  }

  @Test("AudioPlayer setQueue and rate changes delegate to Cast while volume stays local")
  func audioPlayerDelegatesQueueAndRateWithoutTouchingCastVolume() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let session = makeSession(tracks: tracks, currentTime: 110)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 110, duration: 200)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session, cast: controller)

    player.setQueue(for: session)
    player.volume = 1.0
    player.rate = 1.5

    #expect(player.isCasting == true)
    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].startTime == 10)
    #expect(client.rateCalls == [1.5])
    #expect(player.volume == 1.0)
  }

  @Test("AudioPlayer stop() while casting calls cast.stop() and clears controller state")
  func audioPlayerStopWhileCastingStopsController() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let session = makeSession(tracks: tracks, currentTime: 20)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 20, duration: 100)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session, cast: controller)

    var stoppedEvent = false
    let cancellable = player.events.sink { event in
      if case .stateChanged(.stopped) = event { stoppedEvent = true }
    }

    player.setQueue(for: session)
    client.events.send(.stateChanged(isPlaying: true))
    #expect(player.isPlaying == true)

    player.stop()

    #expect(stoppedEvent)
    #expect(client.pauseCallCount == 1)
    #expect(controller.isPlaying == false)
    #expect(controller.isPlaybackActive == false)
    _ = cancellable
  }

  @Test("Switching books mid-Cast stops old player without breaking new player subscription")
  func switchingBooksMidCastWorksCleanly() {
    let client = MockCastClient()
    let tracksA = makeTracks(durations: [100])
    let sessionA = makeSession(baseURL: URL(string: "https://abs.example.com/session/A"), tracks: tracksA, currentTime: 15)
    let progressA = MediaProgress(bookID: "book-A", currentTime: 15, duration: 100)
    var playerA: AudioPlayer? = AudioPlayer(
      mediaProgress: progressA,
      session: sessionA,
      cast: CastPlaybackController(client: client)
    )
    playerA?.setQueue(for: sessionA)
    playerA?.volume = 1.0
    client.events.send(.stateChanged(isPlaying: true))
    #expect(playerA?.isPlaying == true)
    playerA?.stop()
    playerA = nil

    let tracksB = makeTracks(durations: [120])
    let sessionB = makeSession(baseURL: URL(string: "https://abs.example.com/session/B"), tracks: tracksB, currentTime: 30)
    let progressB = MediaProgress(bookID: "book-B", currentTime: 30, duration: 120)
    let playerB = AudioPlayer(
      mediaProgress: progressB,
      session: sessionB,
      cast: CastPlaybackController(client: client)
    )
    playerB.setQueue(for: sessionB)
    playerB.volume = 1.0
    playerB.resume()
    client.events.send(.stateChanged(isPlaying: true))
    client.events.send(.positionUpdated(45))

    #expect(client.loadCalls.count == 2)
    #expect(client.loadCalls[1].streamURL == URL(string: "https://abs.example.com/session/B/track/0"))
    #expect(playerB.isPlaying == true)
    #expect(progressB.currentTime == 45)
    #expect(progressA.currentTime == 15)
  }

  @Test("AudioPlayer sessionEnded restores local playback queue when no external handler is set")
  func audioPlayerSessionEndedRestoresLocalQueue() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let session = makeSession(tracks: tracks, currentTime: 15)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 15, duration: 100)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session, cast: controller)

    var states: [AudioPlayer.PlaybackState] = []
    let cancellable = player.events.sink { event in
      if case .stateChanged(let state) = event { states.append(state) }
    }

    player.setQueue(for: session)
    client.isConnected = false
    client.events.send(.sessionEnded)

    #expect(player.isCasting == false)
    #expect(states.contains(.paused))
    _ = cancellable
  }

  @Test("Non-Cast AudioPlayer operations leave Cast client completely untouched")
  func audioPlayerNonCastDefault() {
    let client = MockCastClient()
    client.isConnected = false
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [60])
    let session = makeSession(tracks: tracks)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 0, duration: 60)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session, cast: controller)

    player.setQueue(for: session)
    player.volume = 0.8
    player.rate = 1.25
    player.seek(to: 15)
    player.pause()
    player.stop()

    #expect(player.isCasting == false)
    #expect(player.isPlaying == false)
    #expect(client.loadCalls.isEmpty)
    #expect(client.playCallCount == 0)
    #expect(client.pauseCallCount == 0)
    #expect(client.seekCalls.isEmpty)
    #expect(client.rateCalls.isEmpty)
    #expect(client.disconnectCallCount == 0)
  }

  @Test("Cross-track seek beyond book end clamps cleanly and never freezes position updates")
  func crossTrackSeekBeyondEndDoesNotFreezeUpdates() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let session = makeSession(tracks: tracks)

    var updates: [TimeInterval] = []
    let cancellable = controller.events.sink { event in
      if case .timeUpdate(let t) = event { updates.append(t) }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.0, autoPlay: true)
    controller.seek(to: 9999)

    #expect(controller.currentTrackIndex == 1)
    #expect(controller.currentTime(fallback: 0) == 200)

    // Receiver starts >2s earlier than 200; updates must still flow cleanly
    client.events.send(.positionUpdated(95))
    #expect(updates == [195])
    #expect(controller.currentTime(fallback: 0) == 195)
    _ = cancellable
  }

  @Test("Seeking while remote session load is in-flight supersedes loadTask without premature client.seek")
  func seekDuringInFlightLoadSupersedesWithoutClientSeek() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100, 100])
    let localSession = makeSession(baseURL: nil, tracks: tracks)
    let remoteSession = makeSession(tracks: tracks)

    var callCount = 0
    controller.onRequireRemoteSession = {
      callCount += 1
      let delay = callCount == 1 ? 80 : 20
      try? await Task.sleep(for: .milliseconds(delay))
      return remoteSession
    }

    controller.load(session: localSession, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.0, autoPlay: true)
    controller.seek(to: 45)

    #expect(client.seekCalls.isEmpty)
    try? await Task.sleep(for: .milliseconds(120))

    #expect(client.loadCalls.count == 1)
    #expect(client.loadCalls[0].startTime == 45)
  }

  @Test("Session ended during in-flight remote session load suppresses load and error")
  func sessionEndedDuringInFlightLoadSuppressesLoadAndError() async {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let localSession = makeSession(baseURL: nil, tracks: tracks)
    let remoteSession = makeSession(tracks: tracks)

    var sawError = false
    let cancellable = controller.events.sink { event in
      if case .error = event { sawError = true }
    }

    controller.onRequireRemoteSession = {
      try? await Task.sleep(for: .milliseconds(50))
      return remoteSession
    }

    controller.load(session: localSession, tracks: tracks, trackIndex: 0, offset: 10, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.sessionEnded)

    try? await Task.sleep(for: .milliseconds(90))
    #expect(!sawError)
    #expect(client.loadCalls.isEmpty)
    _ = cancellable
  }
}
