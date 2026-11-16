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
  private(set) var volumeCalls: [Float] = []
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

  func setVolume(_ volume: Float) {
    volumeCalls.append(volume)
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

  @Test("Final trackFinished emits finished and disconnects Cast")
  func finalTrackFinishedEmitsFinishedAndDisconnects() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)
    let tracks = makeTracks(durations: [100])
    let session = makeSession(tracks: tracks)

    var finishedCount = 0
    let cancellable = controller.events.sink { event in
      if case .finished = event { finishedCount += 1 }
    }

    controller.load(session: session, tracks: tracks, trackIndex: 0, offset: 99, coverURL: nil, rate: 1.0, autoPlay: true)
    client.events.send(.stateChanged(isPlaying: true))
    #expect(controller.isPlaying == true)

    client.events.send(.trackFinished)

    #expect(finishedCount == 1)
    #expect(controller.isPlaying == false)
    #expect(client.disconnectCallCount == 1)
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

  @Test("Rate and volume changes forward to Cast client")
  func rateAndVolumeForwardToClient() {
    let client = MockCastClient()
    let controller = CastPlaybackController(client: client)

    var emittedRates: [Float] = []
    let cancellable = controller.events.sink { event in
      if case .rateChanged(let r) = event { emittedRates.append(r) }
    }

    controller.setRate(1.75)
    controller.setVolume(0.6)

    #expect(client.rateCalls == [1.75])
    #expect(emittedRates == [1.75])
    #expect(client.volumeCalls == [0.6])
    _ = cancellable
  }

  @Test("AudioPlayer defaults to non-Cast when no Cast session is active")
  func audioPlayerNonCastDefault() {
    let tracks = makeTracks(durations: [60])
    let session = makeSession(tracks: tracks)
    let mediaProgress = MediaProgress(bookID: "book-1", currentTime: 0, duration: 60)
    let player = AudioPlayer(mediaProgress: mediaProgress, session: session)

    #expect(player.isCasting == false)
    #expect(player.isPlaying == false)
  }
}
