import Foundation

/// Applies the platform-independent subset of GotoBrowser's `main.js` patches.
///
/// Every optional anchor replacement is best-effort. A game update that changes
/// an obfuscated anchor therefore leaves that section untouched while the
/// standalone listeners continue to be installed.
public struct ScriptPatcher: Sendable {
    public enum CursorMode: Sendable {
        case mouse
        case touch
    }

    public struct Options: Sendable {
        public var muteOnStart: Bool
        public var cursorMode: CursorMode
        public var adjustsGameLayout: Bool

        public init(
            muteOnStart: Bool = false,
            cursorMode: CursorMode = .mouse,
            adjustsGameLayout: Bool = true
        ) {
            self.muteOnStart = muteOnStart
            self.cursorMode = cursorMode
            self.adjustsGameLayout = adjustsGameLayout
        }
    }

    public init() {}

    /// Patches UTF-8 JavaScript and returns the original bytes unchanged when
    /// the response is not valid UTF-8. This is the entry point intended for
    /// `ResourceCache`.
    public func patchMainScript(_ data: Data, options: Options = .init()) -> Data {
        guard let script = String(data: data, encoding: .utf8) else {
            return data
        }
        return Data(patchMainScript(script, options: options).utf8)
    }

    public func patchMainScript(_ script: String, options: Options = .init()) -> String {
        var output = script
        output = patchAudio(in: output, muteOnStart: options.muteOnStart)

        if options.cursorMode == .touch {
            output = patchTouchEvents(in: output)
        }

        output = appendOnce(
            Self.bridgeScript,
            marker: Self.bridgeMarker,
            to: output
        )

        if options.adjustsGameLayout {
            output = appendOnce(
                Self.layoutScript,
                marker: Self.layoutMarker,
                to: output
            )
        }

        return output
    }

    // MARK: - Audio

    private func patchAudio(in script: String, muteOnStart: Bool) -> String {
        guard !script.contains(Self.audioMarker) else {
            return script
        }

        var body = script

        if muteOnStart {
            body = zeroInitialVolumes(in: body)
        }

        // GotoBrowser replaces the obfuscated Howl constructor helper with its
        // own BGM lifecycle hook. Missing anchors are deliberately ignored.
        let howlPattern =
            #"(new \w+\[\(\w+\(\w+\)\)\])(\(\w+\)),this(?:\[\w+\(\w+\)\]){2}\(\w+,\w+,\w+\)\):"#
        if let expression = firstCapture(in: body, pattern: howlPattern, group: 1) {
            body = body.replacingOccurrences(of: expression, with: "add_bgm")
        }

        let initialMute = muteOnStart ? "1" : "0"
        let howlerCall = muteOnStart ? "true" : "false"
        let prefix = """
        /*\(Self.audioMarker)*/
        var gb_h=null;
        function add_bgm(b){b.onend=function(){(global_mute||gb_h.volume()==0)&&(gb_h.unload(),console.log('unload'))};global_mute&&(b.autoplay=false);gb_h=new Howl(b);return gb_h;}
        var global_mute=\(initialMute);if(typeof Howler!=="undefined"){Howler.mute(\(howlerCall));}

        """
        return prefix + body
    }

    private func zeroInitialVolumes(in script: String) -> String {
        let fetchedVolume =
            #"this\[\w+\(\w+\)\]=(\w+\[\w+\(\w+\)\]\[\w+\(\w+\)\]\(\w+,\w+\(\w+\),\w+\))"#
        let defaultVolume =
            #"this\[\w+\(\w+\)\]=0x1===\w+\[\w+\(\w+\)\]\[\w+\(\w+\)\]\(\w+,\w+\(\w+\),\w+\)"#
        let pattern = Array(repeating: fetchedVolume, count: 3).joined(separator: ",")
            + ","
            + Array(repeating: defaultVolume, count: 2).joined(separator: ",")
            + ";"

        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: script,
                range: NSRange(script.startIndex..., in: script)
            ),
            let statementRange = Range(match.range(at: 0), in: script)
        else {
            return script
        }

        var replacement = String(script[statementRange])
        for group in 1...3 {
            guard
                match.range(at: group).location != NSNotFound,
                let range = Range(match.range(at: group), in: script)
            else {
                return script
            }
            replacement = replacement.replacingOccurrences(
                of: String(script[range]),
                with: "0"
            )
        }

        var result = script
        result.replaceSubrange(statementRange, with: replacement)
        return result
    }

    // MARK: - Touch

    private func patchTouchEvents(in script: String) -> String {
        guard !script.contains(Self.touchMarker) else {
            return script
        }

        var body = script
        let eventTablePattern = #"('(out|over|down|move|up)'?:[^,;=}]{20,150},?){5,}"#
        if let regex = try? NSRegularExpression(pattern: eventTablePattern) {
            let range = NSRange(body.startIndex..., in: body)
            body = regex.stringByReplacingMatches(
                in: body,
                options: [],
                range: range,
                withTemplate: Self.touchEventTable
            )
        }

        return appendOnce(
            Self.touchInteractionPatch,
            marker: Self.touchMarker,
            to: body
        )
    }

    // MARK: - Standalone scripts

    private func appendOnce(_ script: String, marker: String, to output: String) -> String {
        guard !output.contains(marker) else {
            return output
        }
        return output + "\n/*\(marker)*/\n" + script
    }

    private func firstCapture(in text: String, pattern: String, group: Int) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            match.numberOfRanges > group,
            match.range(at: group).location != NSNotFound,
            let range = Range(match.range(at: group), in: text)
        else {
            return nil
        }
        return String(text[range])
    }

    private static let audioMarker = "__GOTO_IOS_AUDIO_PATCH_V1__"
    private static let touchMarker = "__GOTO_IOS_TOUCH_PATCH_V1__"
    private static let bridgeMarker = "__GOTO_IOS_BRIDGE_PATCH_V1__"
    private static let layoutMarker = "__GOTO_IOS_LAYOUT_PATCH_V1__"

    private static let touchEventTable = """
    down:void 0!==document.ontouchstart?'touchstart':'mousedown',
    move:void 0!==document.ontouchstart?'touchmove':'mousemove',
    up:void 0!==document.ontouchstart?'touchend':'mouseup',
    over:'touchover',
    out:'touchout'
    """

    /// Verbatim behavior of GotoBrowser's `touch_event_patch.js`, guarded so a
    /// changed or delayed PIXI runtime cannot abort the rest of `main.js`.
    private static let touchInteractionPatch = #"""
    (function(){
    if(typeof PIXI==="undefined"||!PIXI.interaction||!PIXI.interaction.InteractionManager)return;
    function patchInteractionManager() {
        var proto = PIXI.interaction.InteractionManager.prototype;
        proto.update = mobileUpdate;
        function extendMethod(method, extFn) {
            var old = proto[method];
            if(typeof old!=="function")return;
            proto[method] = function() {
                old.call(this, ...arguments);
                extFn.call(this, ...arguments);
            };
        }
        extendMethod('onPointerDown', function() {
            if (this.eventData.data)
                this.processInteractive(this.eventData, this.renderer._lastObjectRendered, this.processTouchOverOut, true);
        });
        extendMethod('onPointerUp', function() {
            if (this.eventData.data)
                this.processInteractive(this.eventData, this.renderer._lastObjectRendered, this.processTouchOverOut, true);
        });
        function mobileUpdate(deltaTime) {
            this._deltaTime += deltaTime;
            if (this._deltaTime < 4) return;
            this._deltaTime = 0;
            if (!this.interactionDOMElement) return;
            if (!this.eventData || !this.eventData.data) return;
            if (this.eventData.data && (this.eventData.type == 'touchmove' || this.eventData.type == 'touchend' || this.eventData.type == 'tap'))
                this.processInteractive(this.eventData, this.renderer._lastObjectRendered, this.processTouchOverOut, true);
        }
        proto.processTouchOverOut = function(interactionEvent, displayObject, hit) {
            if (!interactionEvent.data) return;
            if (hit) {
                if (!displayObject.___over && displayObject._events.touchover) {
                    if (displayObject.parent._onClickAll2) return;
                    if (displayObject.parent._btns && displayObject.parent.parent._onPurchased) return;
                    this._hoverObject = displayObject;
                    displayObject.___over = true;
                    proto.dispatchEvent(displayObject, 'touchover', interactionEvent);
                }
            } else if (displayObject.___over && displayObject._events.touchover &&
                ((this._hoverObject && this._hoverObject != displayObject) || !interactionEvent.target)) {
                displayObject.___over = false;
                proto.dispatchEvent(displayObject, 'touchout', interactionEvent);
            }
        };
    }
    patchInteractionManager();
    })();
    """#

    /// Installs mute/capture listeners plus axios, raw XHR and fetch kcsapi
    /// interception. BrowserView also injects this at document start in every
    /// frame, so API collection does not depend on observing decrypted HTTPS
    /// responses in the local proxy. The main.js patch still appends the same
    /// script as a fallback; `__gotoIOSBridgeInstalled` makes both paths safe.
    ///
    /// Reports are restricted to known game hosts and `svdata=` responses
    /// before crossing the WKScriptMessage bridge.
    public static let bridgeScript = #"""
    (function(){
    if(window.__gotoIOSBridgeInstalled)return;
    window.__gotoIOSBridgeInstalled=true;
    function bridge(message){
        try {
            var handler=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.gotoBrowser;
            if(handler)handler.postMessage(message);
        } catch (_) {}
    }
    function stringify(value){
        if(value==null)return null;
        if(typeof value==="string")return value;
        try{return JSON.stringify(value);}catch(_){return String(value);}
    }
    var recent=[];
    function report(host,endpoint,request,response){
        host=String(host||"").toLowerCase();
        endpoint=String(endpoint||"");
        response=stringify(response);
        if(!(host==="ooi.moe"||host==="kancolle.moe"||host.endsWith(".kancolle-server.com")))return;
        if(endpoint.indexOf("kcsapi")<0||!response||response.indexOf("svdata=")<0)return;
        var signature=endpoint+"|"+response.length+"|"+response.slice(0,48)+"|"+response.slice(-48);
        if(recent.indexOf(signature)>=0)return;
        recent.push(signature);if(recent.length>32)recent.shift();
        try {
            var lifecycle=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.gotoGameLifecycle;
            if(lifecycle)lifecycle.postMessage({type:"gameReady"});
        } catch (_) {}
        bridge({type:"kcsapi",endpoint:endpoint,request:stringify(request),response:response});
    }
    window.addEventListener("message",function(event){
        if(event.data&&event.data.sound!=null){
            global_mute=event.data.sound;
            if(typeof Howler!=="undefined")Howler.mute(global_mute);
            if(!global_mute&&gb_h&&!gb_h.playing())gb_h.play();
        }
        if(event.data&&event.data.capture!=null){
            var canvas=document.querySelector("canvas");
            requestAnimationFrame(function(){
                try {
                    if(canvas)bridge({type:"capture",data:canvas.toDataURL("image/png")});
                } catch (_) {}
            });
        }
    });
    if(window.axios&&axios.interceptors&&axios.interceptors.response&&!window.__gotoIOSAxiosInstalled){
        window.__gotoIOSAxiosInstalled=true;
        axios.interceptors.response.use(function(response){
            var config=response.config||{};
            report(window.location.hostname,config.url,config.data,response.data);
            return response;
        },function(error){return Promise.reject(error);});
    }
    if(window.XMLHttpRequest&&!XMLHttpRequest.prototype.__gotoIOSXHRInstalled){
        var originalOpen=XMLHttpRequest.prototype.open;
        var originalSend=XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open=function(method,url){
            this.__gotoIOSEndpoint=url;
            return originalOpen.apply(this,arguments);
        };
        XMLHttpRequest.prototype.send=function(body){
            this.__gotoIOSRequest=body;
            this.addEventListener("loadend",function(){
                var response;
                try{response=typeof this.responseText==="string"?this.responseText:this.response;}catch(_){response=this.response;}
                report(window.location.hostname,this.__gotoIOSEndpoint,this.__gotoIOSRequest,response);
            });
            return originalSend.apply(this,arguments);
        };
        XMLHttpRequest.prototype.__gotoIOSXHRInstalled=true;
    }
    if(window.fetch&&!window.__gotoIOSFetchInstalled){
        var originalFetch=window.fetch;
        window.fetch=function(input,init){
            var endpoint=typeof input==="string"?input:(input&&input.url)||"";
            var request=init&&init.body;
            var result=originalFetch.apply(this,arguments);
            if(String(endpoint).indexOf("kcsapi")<0)return result;
            return result.then(function(response){
                try {
                    var copy=response.clone();
                    copy.text().then(function(text){
                        var host=window.location.hostname;
                        try{host=new URL(endpoint,window.location.href).hostname;}catch(_){}
                        report(host,endpoint,request,text);
                    }).catch(function(){});
                } catch (_) {}
                return response;
            });
        };
        window.__gotoIOSFetchInstalled=true;
    }
    })();
    """#

    /// Keeps the original DMM `.gamesResetStyle` adjustment and adds a generic
    /// 1200×720 game-stage fit for direct game/connector pages.
    private static let layoutScript = BrowserConstants.adjustScript + #"""
    ;(function(){
    if(window.__gotoIOSGameLayoutInstalled)return;
    window.__gotoIOSGameLayoutInstalled=true;
    var style=document.createElement("style");
    style.textContent="html,body{margin:0!important;padding:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}.gamesResetStyle>main{margin:0!important;padding:0!important}.gamesResetStyle>:not(main){display:none!important}#game_frame,#externalswf{border:0!important;transform-origin:top left!important}";
    (document.head||document.documentElement).appendChild(style);
    function fit(){
        var stage=document.getElementById("game_frame")||document.getElementById("externalswf")||document.querySelector("canvas");
        if(!stage)return false;
        var scale=Math.min(window.innerWidth/1200,window.innerHeight/720);
        var left=Math.max(0,(window.innerWidth-1200*scale)/2);
        var top=Math.max(0,(window.innerHeight-720*scale)/2);
        stage.style.position="fixed";
        stage.style.left=left+"px";
        stage.style.top=top+"px";
        stage.style.width="1200px";
        stage.style.height="720px";
        stage.style.transformOrigin="top left";
        stage.style.transform="scale("+scale+")";
        return true;
    }
    var queued=0;
    function schedule(){cancelAnimationFrame(queued);queued=requestAnimationFrame(fit);}
    window.addEventListener("resize",schedule,{passive:true});
    if(!fit()&&document.body){
        var observer=new MutationObserver(function(){if(fit())observer.disconnect();});
        observer.observe(document.body,{childList:true,subtree:true});
    }
    })();
    """#
}
