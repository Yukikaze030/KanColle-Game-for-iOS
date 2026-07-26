import XCTest
@testable import GameCore

final class ScriptPatcherTests: XCTestCase {
    private let patcher = ScriptPatcher()

    func testMutePatchZerosInitialVolumesAndInstallsHowlHook() {
        let volumes = """
        this[a(b)]=x[y(z)][q(r)](s,t(u),v),this[c(d)]=m[n(o)][p(q)](r,s(t),u),this[e(f)]=h[i(j)][k(l)](m,n(o),p),this[g(h)]=0x1===i[j(k)][l(m)](n,o(p),q),this[r(s)]=0x1===t[u(v)][w(x)](y,z(a),b);
        """
        let howl = "new A[(b(c))](d),this[x(y)][z(w)](a,b,c)):"

        let output = patcher.patchMainScript(
            volumes + howl,
            options: .init(muteOnStart: true)
        )

        XCTAssertTrue(output.contains("var global_mute=1"))
        XCTAssertTrue(output.contains("Howler.mute(true)"))
        XCTAssertTrue(output.contains("this[a(b)]=0"))
        XCTAssertTrue(output.contains("this[c(d)]=0"))
        XCTAssertTrue(output.contains("this[e(f)]=0"))
        XCTAssertTrue(output.contains("add_bgm(d),this[x(y)][z(w)](a,b,c)):"))
    }

    func testMissingObfuscatedAnchorsAreTolerated() {
        let output = patcher.patchMainScript(
            "var x=1;",
            options: .init(muteOnStart: true, cursorMode: .touch)
        )

        XCTAssertTrue(output.contains("var x=1;"))
        XCTAssertTrue(output.contains("var global_mute=1"))
        XCTAssertTrue(output.contains("patchInteractionManager"))
        XCTAssertTrue(output.contains("webkit.messageHandlers"))
    }

    func testMouseModeDoesNotInstallTouchPatch() {
        let output = patcher.patchMainScript(
            "var x=1;",
            options: .init(cursorMode: .mouse)
        )

        XCTAssertFalse(output.contains("__GOTO_IOS_TOUCH_PATCH_V1__"))
        XCTAssertFalse(output.contains("patchInteractionManager"))
    }

    func testTouchModeReplacesPointerEventTableAndAppendsInteractionPatch() {
        let source = """
        var events={'out':abcdefghijklmnopqrstuvwxyz,'over':bcdefghijklmnopqrstuvwxyza,'down':cdefghijklmnopqrstuvwxyzab,'move':defghijklmnopqrstuvwxyzabc,'up':efghijklmnopqrstuvwxyzabcd};
        """

        let output = patcher.patchMainScript(
            source,
            options: .init(cursorMode: .touch)
        )

        XCTAssertTrue(output.contains("down:void 0!==document.ontouchstart?'touchstart':'mousedown'"))
        XCTAssertTrue(output.contains("over:'touchover'"))
        XCTAssertTrue(output.contains("proto.processTouchOverOut"))
        XCTAssertFalse(output.contains("'out':abcdefghijklmnopqrstuvwxyz"))
    }

    func testBridgeContainsIOSCaptureAxiosXHRAndFetchInterceptors() {
        let output = patcher.patchMainScript("var x=1;")

        XCTAssertTrue(output.contains("window.webkit"))
        XCTAssertTrue(output.contains("messageHandlers.gotoBrowser"))
        XCTAssertTrue(output.contains(#"{type:"capture",data:"#))
        XCTAssertTrue(output.contains(#"{type:"kcsapi",endpoint:"#))
        XCTAssertTrue(output.contains("axios.interceptors.response.use"))
        XCTAssertTrue(output.contains("XMLHttpRequest.prototype.open"))
        XCTAssertTrue(output.contains("window.fetch"))
        XCTAssertTrue(output.contains("response.clone()"))
        XCTAssertTrue(output.contains("copy.text()"))
        XCTAssertTrue(output.contains("messageHandlers.gotoGameLifecycle"))
        XCTAssertTrue(output.contains(#"response.indexOf("svdata=")"#))
        XCTAssertTrue(output.contains(#"host.endsWith(".kancolle-server.com")"#))
        XCTAssertTrue(output.contains(#"host==="ooi.moe""#))
        XCTAssertFalse(output.contains("GotoBrowser.kcs_xhr_intercept"))
        XCTAssertFalse(output.contains("GotoBrowser.kcs_process_canvas_dataurl"))
    }

    func testPublicBridgeScriptCanBeInjectedBeforeMainScriptAndPatchedFallbackRemainsGuarded() {
        let bridge = ScriptPatcher.bridgeScript

        XCTAssertTrue(bridge.contains("if(window.__gotoIOSBridgeInstalled)return"))
        XCTAssertTrue(bridge.contains("window.__gotoIOSBridgeInstalled=true"))
        XCTAssertTrue(bridge.contains("XMLHttpRequest.prototype.send"))
        XCTAssertTrue(bridge.contains("window.__gotoIOSFetchInstalled"))

        let mainScript = patcher.patchMainScript(bridge + "\nvar gameStarted=true;")
        XCTAssertTrue(mainScript.contains("__GOTO_IOS_BRIDGE_PATCH_V1__"))
        XCTAssertEqual(
            mainScript.components(separatedBy: "window.__gotoIOSBridgeInstalled=true").count,
            3,
            "main.js keeps its fallback copy; the runtime guard prevents double installation"
        )
    }

    func testGameLayoutHidesNonGameElementsAndFits1200By720() {
        let output = patcher.patchMainScript("var x=1;")

        XCTAssertTrue(output.contains(".gamesResetStyle>:not(main){display:none!important}"))
        XCTAssertTrue(output.contains("window.innerWidth/1200"))
        XCTAssertTrue(output.contains("window.innerHeight/720"))
        XCTAssertTrue(output.contains(#"document.getElementById("game_frame")"#))
        XCTAssertTrue(output.contains(#"document.getElementById("externalswf")"#))
    }

    func testEveryStandalonePatchIsIdempotent() {
        let options = ScriptPatcher.Options(
            muteOnStart: true,
            cursorMode: .touch,
            adjustsGameLayout: true
        )
        let once = patcher.patchMainScript("var x=1;", options: options)
        let twice = patcher.patchMainScript(once, options: options)

        XCTAssertEqual(twice, once)
        XCTAssertEqual(once.components(separatedBy: "__GOTO_IOS_AUDIO_PATCH_V1__").count, 2)
        XCTAssertEqual(once.components(separatedBy: "__GOTO_IOS_TOUCH_PATCH_V1__").count, 2)
        XCTAssertEqual(once.components(separatedBy: "__GOTO_IOS_BRIDGE_PATCH_V1__").count, 2)
        XCTAssertEqual(once.components(separatedBy: "__GOTO_IOS_LAYOUT_PATCH_V1__").count, 2)
    }

    func testDataAPIProducesUTF8AndPreservesInvalidUTF8() {
        let source = Data("var x=1;".utf8)
        let patched = patcher.patchMainScript(source)
        let patchedString = String(decoding: patched, as: UTF8.self)
        XCTAssertTrue(patchedString.contains("var x=1;"))
        XCTAssertTrue(patchedString.contains("__GOTO_IOS_BRIDGE_PATCH_V1__"))

        let invalid = Data([0xFF, 0xFE, 0xFD])
        XCTAssertEqual(patcher.patchMainScript(invalid), invalid)
    }

    func testLayoutPatchCanBeDisabledForNonGameScriptUse() {
        let output = patcher.patchMainScript(
            "var x=1;",
            options: .init(adjustsGameLayout: false)
        )

        XCTAssertFalse(output.contains("__GOTO_IOS_LAYOUT_PATCH_V1__"))
        XCTAssertTrue(output.contains("__GOTO_IOS_BRIDGE_PATCH_V1__"))
    }
}
