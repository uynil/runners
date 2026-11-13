import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RunnersPhoneCore

final class StravaTests: XCTestCase {
    private let config = StravaConfiguration(clientID:"123",brokerURL:URL(string:"https://broker.example")!,redirectURL:URL(string:"runners://oauth/strava")!)
    private let date = Date(timeIntervalSince1970:1700000000)
    private func archive(simulated: Bool = false) -> ActivityArchive {
        let summary = """
        {"id":"C0000000-0000-4000-8000-000000000038","startedAt":1700000000,"endedAt":1700000060,"activeSeconds":40,"distanceMeters":19.26,"gpsSampleCount":4,"heartSampleCount":2,"healthStatus":"test","activity":"trailRunning"}
        """
        let samples = """
        {"kind":"heartRate","timestamp":1700000000,"heartRate":122}
        {"kind":"gps","timestamp":1700000000,"acceptedForDistance":true,"fix":{"latitude":30,"longitude":120,"accuracy":5},"altitudeMeters":500,"verticalAccuracy":3}
        {"kind":"gps","timestamp":1700000005,"acceptedForDistance":true,"fix":{"latitude":30,"longitude":120.0001,"accuracy":5}}
        {"kind":"pause","timestamp":1700000010}
        {"kind":"gps","timestamp":1700000020,"acceptedForDistance":true,"fix":{"latitude":31,"longitude":121,"accuracy":5}}
        {"kind":"resume","timestamp":1700000030}
        {"kind":"gps","timestamp":1700000030,"acceptedForDistance":true,"fix":{"latitude":30.001,"longitude":120,"accuracy":5}}
        {"kind":"gps","timestamp":1700000035,"acceptedForDistance":true,"fix":{"latitude":30.001,"longitude":120.0001,"accuracy":5}}
        {"kind":"stop","timestamp":1700000060}
        """
        return ActivityArchive(simulated:simulated,summaryData:Data(summary.utf8),samplesData:Data(samples.utf8))
    }
    func testOAuthUsesMinimumScopeAndRejectsStateExpiryDeniedScopeAndDuplicateParameters() throws {
        let attempt=try StravaOAuthAttempt(configuration:config,now:date,state:"random-state")
        XCTAssertTrue(attempt.authorizationURL.absoluteString.contains("activity:write") || attempt.authorizationURL.absoluteString.contains("activity%3Awrite"))
        let callback="runners://oauth/strava?state=random-state&code=ok&scope=activity:write"
        XCTAssertEqual(try attempt.code(from:URL(string:callback)!,now:date),"ok")
        for bad in [callback.replacingOccurrences(of:"random-state",with:"wrong"), callback+"&state=random-state", callback.replacingOccurrences(of:"activity:write",with:"read"), "runners://oauth/strava?state=random-state&error=access_denied"] {
            XCTAssertThrowsError(try attempt.code(from:URL(string:bad)!,now:date))
        }
        XCTAssertThrowsError(try attempt.code(from:URL(string:callback)!,now:date.addingTimeInterval(601)))
    }
    func testTCXPreservesActualTimeHeartAltitudeAndPauseTracksWithoutFillingGap() throws {
        let xml=String(decoding:try ActivityTCX.data(archive()),as:UTF8.self)
        XCTAssertEqual(xml.components(separatedBy:"<Track>").count-1,2)
        XCTAssertFalse(xml.contains("31.000000"))
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>40.000000</TotalTimeSeconds>"))
        XCTAssertTrue(xml.contains("<LatitudeDegrees>30.001000</LatitudeDegrees>"))
        XCTAssertTrue(xml.contains("<AltitudeMeters>500.000000</AltitudeMeters>"))
        XCTAssertTrue(xml.contains("<Value>122</Value>"))
        let lastTrack=xml.components(separatedBy:"<Track>").last!
        XCTAssertFalse(lastTrack.contains("<HeartRateBpm>"),"Do not carry heart rate across pause or stale gap")
    }
    func testSimulatorDataCannotReachUploadTransport() async throws {
        let api=StravaAPI(fetch:{_ in XCTFail("Synthetic activity must never be sent"); throw StravaFailure.rejected})
        do { _=try await api.upload(archive(simulated:true),token:"test"); XCTFail() } catch is MapError {} catch { XCTFail("Wrong error") }
    }
    func testTCXUsesRecordedDistanceAndRejectsDistanceRegression() throws {
        let base = archive()
        let text = String(decoding:base.samplesData,as:UTF8.self)
        func withDistances(_ first: Double, _ second: Double) -> ActivityArchive {
            let samples = text.replacingOccurrences(of:"\"altitudeMeters\":500",with:"\"cumulativeDistanceMeters\":\(first),\"altitudeMeters\":500")
                .replacingOccurrences(of:"\"longitude\":120.0001,\"accuracy\":5}}",with:"\"longitude\":120.0001,\"accuracy\":5},\"cumulativeDistanceMeters\":\(second)}")
            return ActivityArchive(simulated:false,summaryData:base.summaryData,samplesData:Data(samples.utf8))
        }
        let xml = String(decoding:try ActivityTCX.data(withDistances(0,9)),as:UTF8.self)
        XCTAssertTrue(xml.contains("<DistanceMeters>9.000000</DistanceMeters>"))
        XCTAssertThrowsError(try ActivityTCX.data(withDistances(9,4)))
        XCTAssertThrowsError(try ActivityTCX.data(withDistances(0,1000)))
    }
    func testUploadUsesStableExternalIDAndOnlyActualArchiveFile() async throws {
        let api=StravaAPI(fetch:{request in
            XCTAssertEqual(request.url?.absoluteString,"https://www.strava.com/api/v3/uploads")
            XCTAssertEqual(request.httpMethod,"POST")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer test-token")
            let body=String(decoding:request.httpBody!,as:UTF8.self)
            XCTAssertTrue(body.contains("runners-C0000000-0000-4000-8000-000000000038.tcx"))
            XCTAssertTrue(body.contains("TrainingCenterDatabase"))
            return (Data("{\"id\":777}".utf8),HTTPURLResponse(url:request.url!,statusCode:201,httpVersion:nil,headerFields:nil)!)
        })
        let upload = try await api.upload(archive(),token:"test-token")
        XCTAssertEqual(upload.id,777)
    }
    func testBrokerRefreshAndUploadPollingUseDifferentEndpointsAndRotationIsDecoded() async throws {
        let api=StravaAPI(fetch:{request in
            XCTAssertEqual(request.url?.absoluteString,"https://broker.example/oauth/refresh")
            let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:String]
            XCTAssertEqual(body["refresh_token"],"old-refresh"); XCTAssertNil(body["client_secret"])
            return (Data("{\"access_token\":\"new\",\"refresh_token\":\"rotated\",\"expires_at\":2000000000}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        let tokens = try await api.tokens(configuration:config,refresh:"old-refresh")
        XCTAssertEqual(tokens.refresh_token,"rotated")
    }
    func testRateLimitAndUnauthorizedAreExplicitFailures() async throws {
        for status in [401,429] {
            let api=StravaAPI(fetch:{request in (Data(),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Retry-After":"120"])!)})
            do { _=try await api.poll(id:777,token:"test"); XCTFail() }
            catch StravaFailure.unauthorized { XCTAssertEqual(status,401) }
            catch StravaFailure.rateLimited(let seconds) { XCTAssertEqual(status,429); XCTAssertEqual(seconds,120) }
        }
    }
    func testCrashDuringSubmissionNeverAutomaticallyPostsAgainAndKnownUploadResumesPolling() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let storage=StravaQueueStorage(url:root.appendingPathComponent("queue.json"))
        var job=StravaUploadJob(workoutID:UUID(),accountID:7)
        XCTAssertTrue(job.maySubmitNewFile)
        job.phase = .submitting
        try storage.save([job])
        let restored=try XCTUnwrap(storage.load().first)
        XCTAssertEqual(restored.phase,.unknown)
        XCTAssertFalse(restored.resumesAutomatically); XCTAssertFalse(restored.maySubmitNewFile)
        job.phase = .processing; job.uploadID = 777
        try storage.save([job])
        let known=try XCTUnwrap(storage.load().first)
        XCTAssertTrue(known.resumesAutomatically); XCTAssertFalse(known.maySubmitNewFile)
        XCTAssertEqual(known.uploadID,777)
    }
}
